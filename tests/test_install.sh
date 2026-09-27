#!/bin/bash
# Installs into a throwaway HOME, twice, then uninstalls, and checks that
# other hooks and settings survive untouched. Runs with python3 and with jq.
set -u
cd "$(dirname "$0")/.."
REPO="$PWD"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n' "$1"; }

for engine in python3 jq; do
  T="$(mktemp -d)"
  export HOME="$T"
  S="$T/.claude/settings.json"
  mkdir -p "$T/.claude"
  cat > "$S" <<'JSON'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/my-guard"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
  }
}
JSON
  ORIG="$(jq -S . "$S")"
  use_jq=0; [ "$engine" = jq ] && use_jq=1
  LASTCALL_USE_JQ=$use_jq LASTCALL_NO_APP=1 bash "$REPO/install.sh" >/dev/null 2>&1 || bad "$engine: install exits 0"
  LASTCALL_USE_JQ=$use_jq LASTCALL_NO_APP=1 bash "$REPO/install.sh" >/dev/null 2>&1 || bad "$engine: second install exits 0"
  n=$(grep -o 'lastcall-hook.sh' "$S" | wc -l | tr -d ' ')
  [ "$n" = 3 ] && ok "$engine: installed once per event after two runs ($n)" || bad "$engine: expected 3 hook entries, got $n"
  jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].command=="/usr/local/bin/my-guard"' "$S" >/dev/null && ok "$engine: existing PreToolUse hook kept" || bad "$engine: existing hook lost"
  jq -e '.hooks.Stop[0].hooks[0].command=="say done" and .model=="opus"' "$S" >/dev/null && ok "$engine: other settings kept" || bad "$engine: other settings lost"
  ls "$T/.claude/"settings.json.lastcall-backup-* >/dev/null 2>&1 && ok "$engine: backup written" || bad "$engine: no backup"
  [ -x "$T/.lastcall/bin/lastcall-hook.sh" ] && ok "$engine: hook installed and executable" || bad "$engine: hook missing"
  cmd="$(jq -r '.hooks.UserPromptSubmit[-1].hooks[0].command' "$S")"
  out="$(echo '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' | LASTCALL_FAKE_BATTERY=9 sh -c "$cmd")"
  echo "$out" | grep -q 'Battery at 9%' && ok "$engine: installed command runs" || bad "$engine: installed command output: $out"
  LASTCALL_USE_JQ=$use_jq bash "$REPO/uninstall.sh" >/dev/null 2>&1 || bad "$engine: uninstall exits 0"
  [ "$(jq -S . "$S")" = "$ORIG" ] && ok "$engine: uninstall restores settings exactly" || bad "$engine: settings differ after uninstall"
  [ ! -e "$T/.lastcall" ] && ok "$engine: ~/.lastcall removed" || bad "$engine: ~/.lastcall left behind"
  rm -rf "$T"
done

# Broken settings.json must be left alone.
T="$(mktemp -d)"; export HOME="$T"; mkdir -p "$T/.claude"
printf '{ not json' > "$T/.claude/settings.json"
if LASTCALL_NO_APP=1 bash "$REPO/install.sh" >/dev/null 2>&1; then bad "invalid settings.json should stop the install"; else
  [ "$(cat "$T/.claude/settings.json")" = "{ not json" ] && ok "invalid settings.json left untouched" || bad "invalid settings.json was changed"; fi
rm -rf "$T"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
