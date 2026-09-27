#!/bin/bash
# Installs into a throwaway HOME, twice, then uninstalls, and checks that
# other hooks and settings survive untouched. Also checks the failure paths:
# broken settings.json, checksum mismatch, and a failed unhook.
set -u
cd "$(dirname "$0")/.."
REPO="$PWD"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n' "$1"; }
REAL_HOME="$HOME"

fresh() { T="$(mktemp -d)"; export HOME="$T"; S="$T/.claude/settings.json"; mkdir -p "$T/.claude"; }

# 1. Install twice, uninstall, everything else intact.
fresh
cat > "$S" <<'JSON'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/my-guard"}]},
                   {"matcher": "Edit", "hooks": [{"type": "command", "command": "echo see lastcall-hook.sh docs"}]},
                   {"matcher": "Write", "hooks": [{"type": "command", "command": "/opt/other/lastcall-hook.sh"}]},
                   {"matcher": "Read", "hooks": [{"type": "command", "command": "\"/Users/someone-else/.lastcall/bin/lastcall-hook.sh\""}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
  }
}
JSON
ORIG="$(jq -S . "$S")"
LASTCALL_NO_APP=1 bash "$REPO/install.sh" >/dev/null 2>&1 || bad "install exits 0"
LASTCALL_NO_APP=1 bash "$REPO/install.sh" >/dev/null 2>&1 || bad "second install exits 0"
n=$(jq --arg c "\"$T/.lastcall/bin/lastcall-hook.sh\"" '[.hooks[][]?.hooks[]?.command | select(. == $c)] | length' "$S")
[ "$n" = 3 ] && ok "installed once per event after two runs ($n)" || bad "expected 3 hook entries, got $n"
jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].command=="/usr/local/bin/my-guard"' "$S" >/dev/null && ok "existing PreToolUse hook kept" || bad "existing hook lost"
jq -e '.hooks.PreToolUse[] | select(.matcher=="Edit") | .hooks[0].command=="echo see lastcall-hook.sh docs"' "$S" >/dev/null && ok "hook that only mentions the name is kept" || bad "unrelated hook mentioning the name was removed"
jq -e '.hooks.PreToolUse[] | select(.matcher=="Write") | .hooks[0].command=="/opt/other/lastcall-hook.sh"' "$S" >/dev/null && ok "another tool's lastcall-hook.sh is kept" || bad "another tool's lastcall-hook.sh was removed"
jq -e '.hooks.PreToolUse[] | select(.matcher=="Read") | .hooks[0].command | contains("someone-else")' "$S" >/dev/null && ok "a hook installed under another home is kept" || bad "another home's hook was removed"
jq -e '.hooks.Stop[0].hooks[0].command=="say done" and .model=="opus"' "$S" >/dev/null && ok "other settings kept" || bad "other settings lost"
ls "$T/.claude/"settings.json.lastcall-backup-* >/dev/null 2>&1 && ok "backup written" || bad "no backup"
[ -x "$T/.lastcall/bin/lastcall-hook.sh" ] && ok "hook installed and executable" || bad "hook missing"
[ -z "$(ls -A "$T/.claude" | grep '^\.settings\.')" ] && ok "no temp files left in ~/.claude" || bad "temp file left behind"
cmd="$(jq -r '.hooks.UserPromptSubmit[-1].hooks[0].command' "$S")"
out="$(echo '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' | LASTCALL_FAKE_BATTERY=9 sh -c "$cmd")"
echo "$out" | grep -q 'Battery at 9%' && ok "installed command runs" || bad "installed command output: $out"
bash "$REPO/uninstall.sh" >/dev/null 2>&1 || bad "uninstall exits 0"
[ "$(jq -S . "$S")" = "$ORIG" ] && ok "uninstall restores settings exactly" || bad "settings differ after uninstall"
[ ! -e "$T/.lastcall" ] && ok "~/.lastcall removed" || bad "~/.lastcall left behind"
rm -rf "$T"

# 2. Broken settings.json: install stops before copying anything and leaves the file alone.
fresh
printf '{ not json' > "$S"
if LASTCALL_NO_APP=1 bash "$REPO/install.sh" >"$T/out" 2>&1; then bad "invalid settings.json should stop the install"; else
  [ "$(cat "$S")" = "{ not json" ] && ok "install: invalid settings.json left untouched" || bad "install: invalid settings.json was changed"
  grep -q 'not valid JSON' "$T/out" && ok "install: prints why it stopped" || bad "install: no error message"
  [ ! -e "$T/.lastcall" ] && ok "install: nothing installed when settings are broken" || bad "install: ~/.lastcall created anyway"
fi
[ -z "$(ls -A "$T/.claude" | grep '^\.settings\.')" ] && ok "install: no temp file left on failure" || bad "install: temp file left on failure"
rm -rf "$T"

# 2b. Read-only settings directory: install stops before copying anything.
fresh
printf '{}\n' > "$S"; chmod 555 "$T/.claude"
if LASTCALL_NO_APP=1 bash "$REPO/install.sh" >"$T/out" 2>&1; then bad "read-only settings dir should stop the install"; else
  [ ! -e "$T/.lastcall" ] && grep -q 'cannot write' "$T/out" && ok "install: read-only settings dir stops before installing" || bad "install: read-only dir: $(cat "$T/out")"
fi
chmod 755 "$T/.claude"; rm -rf "$T"

# 3. hooks that are not an object: refused, untouched.
fresh
printf '{"hooks": ["weird"]}\n' > "$S"; before="$(cat "$S")"
if LASTCALL_NO_APP=1 bash "$REPO/install.sh" >/dev/null 2>&1; then bad "non-object hooks should stop the install"; else
  [ "$(cat "$S")" = "$before" ] && ok "install: non-object hooks left untouched" || bad "install: non-object hooks changed"; fi
rm -rf "$T"

# 4. Uninstall with settings broken after install: settings untouched, hook kept, non-zero exit.
fresh
printf '{}\n' > "$S"
LASTCALL_NO_APP=1 bash "$REPO/install.sh" >/dev/null 2>&1 || bad "install into empty settings"
printf '{ broken later' > "$S"
if bash "$REPO/uninstall.sh" >"$T/out" 2>&1; then bad "uninstall should fail on broken settings"; else
  [ "$(cat "$S")" = "{ broken later" ] && ok "uninstall: broken settings.json left untouched" || bad "uninstall: broken settings changed"
  [ -x "$T/.lastcall/bin/lastcall-hook.sh" ] && ok "uninstall: hook kept so settings never point at a missing file" || bad "uninstall: hook deleted"
  grep -q 'left as it was' "$T/out" && ok "uninstall: prints why it stopped" || bad "uninstall: no error message"
fi
rm -rf "$T"

# 5. Symlinked settings.json is edited at its target, link kept.
fresh
mkdir -p "$T/dotfiles"; printf '{"model":"opus"}\n' > "$T/dotfiles/settings.json"; ln -s "$T/dotfiles/settings.json" "$S"
LASTCALL_NO_APP=1 bash "$REPO/install.sh" >/dev/null 2>&1 || bad "install with symlinked settings"
[ -L "$S" ] && jq -e '.hooks.PreToolUse | length == 1' "$T/dotfiles/settings.json" >/dev/null && ok "symlinked settings edited at target, link kept" || bad "symlinked settings"
rm -rf "$T"

# 5b. Menu bar app: built, then replaced on reinstall with no leftovers.
if command -v swiftc >/dev/null 2>&1 && [ -z "${LASTCALL_SKIP_APP_TEST:-}" ]; then
  fresh; printf '{}\n' > "$S"
  LASTCALL_NO_OPEN=1 bash "$REPO/install.sh" >/dev/null 2>&1 && LASTCALL_NO_OPEN=1 bash "$REPO/install.sh" >/dev/null 2>&1 \
    && [ -x "$T/Applications/Last Call.app/Contents/MacOS/LastCall" ] && [ ! -e "$T/Applications/Last Call.app.old" ] && [ ! -e "$T/Applications/Last Call.app.new" ] \
    && ok "app built and replaced in place on reinstall" || bad "app build/replace"
  bash "$REPO/uninstall.sh" >/dev/null 2>&1; [ ! -e "$T/Applications" ] && ok "uninstall removes the app" || bad "app left after uninstall"
  rm -rf "$T"
fi

# 6. Piped install (curl | bash) verifies downloads against SHA256SUMS.
export HOME="$REAL_HOME"
[ "$(cd "$REPO" && shasum -a 256 bin/lastcall-hook.sh app/LastCall.swift scripts/settings.py)" = "$(cat "$REPO/SHA256SUMS")" ] \
  && ok "SHA256SUMS matches the repo (run scripts/update-sums.sh after edits)" || bad "SHA256SUMS is stale: run scripts/update-sums.sh"
SITE="$(mktemp -d)"
mkdir -p "$SITE/bin" "$SITE/app" "$SITE/scripts"
cp "$REPO/bin/lastcall-hook.sh" "$SITE/bin/"; cp "$REPO/app/LastCall.swift" "$SITE/app/"; cp "$REPO/scripts/settings.py" "$SITE/scripts/"; cp "$REPO/SHA256SUMS" "$SITE/"
fresh
if LASTCALL_BASE_URL="file://$SITE" LASTCALL_NO_APP=1 bash < "$REPO/install.sh" >/dev/null 2>&1 && [ -x "$T/.lastcall/bin/lastcall-hook.sh" ]; then ok "piped install with matching checksums works"; else bad "piped install with matching checksums"; fi
rm -rf "$T"
printf '\n# tampered\n' >> "$SITE/bin/lastcall-hook.sh"
fresh; printf '{"model":"opus"}\n' > "$S"
if LASTCALL_BASE_URL="file://$SITE" LASTCALL_NO_APP=1 bash < "$REPO/install.sh" >"$T/out" 2>&1; then bad "tampered download should stop the install"; else
  grep -q 'Checksum mismatch' "$T/out" && [ ! -e "$T/.lastcall" ] && [ "$(cat "$S")" = '{"model":"opus"}' ] \
    && ok "tampered download refused, nothing installed" || bad "tampered download: $(cat "$T/out")"
fi
rm -rf "$T" "$SITE"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
