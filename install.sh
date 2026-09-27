#!/bin/bash
# Last Call installer. https://lastagentcall.com
#   curl -fsSL https://lastagentcall.com/install.sh | bash
# Safe to run again. Undo with uninstall.sh.
#
# Options (env):
#   LASTCALL_NO_APP=1        skip the menu bar app
#   LASTCALL_NO_OPEN=1       build the app but do not open it
#   CLAUDE_SETTINGS=path     settings file to edit (default ~/.claude/settings.json)
#   LASTCALL_BASE_URL=url    where to download files from when piped through curl
#
# Downloaded files are checked against SHA256SUMS before anything is installed.
# That catches truncated or mismatched downloads. SHA256SUMS comes from the same
# site, so to check provenance compare it with the copy in the GitHub repo.
set -euo pipefail

BASE_URL="${LASTCALL_BASE_URL:-https://lastagentcall.com}"
LC="$HOME/.lastcall"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
APP="$HOME/Applications/Last Call.app"
HOOK_CMD="\"$LC/bin/lastcall-hook.sh\""
say() { printf '  %s\n' "$*"; }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Last Call is for macOS (it reads the battery with pmset)." >&2
  exit 1
fi

# python3 edits settings.json. On a Mac without the Command Line Tools, /usr/bin/python3
# is only a stub that opens an install dialog, so check for the tools first.
have_python() {
  local py; py="$(command -v python3 2>/dev/null)" || return 1
  if [ "$py" = /usr/bin/python3 ]; then xcode-select -p >/dev/null 2>&1 || return 1; fi
  python3 -c 'import json' >/dev/null 2>&1
}
if ! have_python; then
  echo "Last Call needs python3 to edit $SETTINGS safely. Install the Command Line Tools with: xcode-select --install" >&2
  echo "Nothing was changed." >&2
  exit 1
fi

FILES="bin/lastcall-hook.sh app/LastCall.swift scripts/settings.py"

# Find source files: next to this script when run from a checkout, else download and verify.
SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/bin/lastcall-hook.sh" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SRC="$(mktemp -d)"
  trap 'rm -rf "$SRC"' EXIT
  mkdir -p "$SRC/bin" "$SRC/app" "$SRC/scripts"
  if ! curl -fsSL "$BASE_URL/SHA256SUMS" -o "$SRC/SHA256SUMS"; then
    echo "Could not download $BASE_URL/SHA256SUMS. Nothing was installed." >&2; exit 1
  fi
  for f in $FILES; do
    if ! curl -fsSL "$BASE_URL/$f" -o "$SRC/$f"; then
      echo "Could not download $BASE_URL/$f. Nothing was installed." >&2; exit 1
    fi
    want="$(awk -v f="$f" '$2==f {print $1}' "$SRC/SHA256SUMS")"
    got="$(shasum -a 256 "$SRC/$f" | awk '{print $1}')"
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
      echo "Checksum mismatch for $f (expected ${want:-nothing}, got $got). Nothing was installed." >&2; exit 1
    fi
  done
fi

# Stop before touching anything if settings.json cannot be edited safely.
if ! python3 "$SRC/scripts/settings.py" check "$SETTINGS"; then
  echo "Fix $SETTINGS (or move it aside) and run the installer again." >&2
  exit 1
fi

echo "Installing Last Call"

# 1. Hook script
mkdir -p "$LC/bin"
cp "$SRC/bin/lastcall-hook.sh" "$LC/bin/lastcall-hook.sh"
cp "$SRC/scripts/settings.py" "$LC/bin/lastcall-settings.py"
chmod 755 "$LC/bin/lastcall-hook.sh" "$LC/bin/lastcall-settings.py"
say "hook        $LC/bin/lastcall-hook.sh"
if [ ! -f "$LC/config" ]; then
  cat > "$LC/config" <<'EOF'
# Last Call levels (battery percent, only while on battery)
WARN_AT=20
WRAP_AT=10
STOP_AT=5
# Set ENABLED=0 to turn the hook off without uninstalling
ENABLED=1
EOF
  say "config      $LC/config"
else
  say "config      $LC/config (kept yours)"
fi

# 2. Claude Code settings: back up, then merge (never replace other hooks)
mkdir -p "$(dirname "$SETTINGS")"
if [ -f "$SETTINGS" ]; then
  BACKUP="$SETTINGS.lastcall-backup-$(date +%Y%m%d-%H%M%S)"
  cp -p "$SETTINGS" "$BACKUP"
  say "backup      $BACKUP"
fi
if ! python3 "$LC/bin/lastcall-settings.py" install "$SETTINGS" "$HOOK_CMD"; then
  echo "Could not add the hook to $SETTINGS; it was left as it was. The rest of Last Call is in $LC." >&2
  exit 1
fi
say "hooked      PreToolUse, PostToolUse, UserPromptSubmit in $SETTINGS"

# 3. Menu bar app (optional, built from source so it needs no notarization)
if [ "${LASTCALL_NO_APP:-0}" = "1" ]; then
  say "app         skipped (LASTCALL_NO_APP=1)"
elif command -v swiftc >/dev/null 2>&1; then
  BUILD="$(mktemp -d)"
  if swiftc -O -o "$BUILD/LastCall" "$SRC/app/LastCall.swift" -framework AppKit -framework IOKit >"$BUILD/log" 2>&1; then
    # Assemble the new bundle next to the old one, then swap, so a failed copy
    # never leaves the user without the app.
    NEW="$APP.new"
    rm -rf "$NEW"
    mkdir -p "$NEW/Contents/MacOS"
    cp "$BUILD/LastCall" "$NEW/Contents/MacOS/LastCall"
    cat > "$NEW/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Last Call</string>
  <key>CFBundleIdentifier</key><string>com.lastagentcall.menubar</string>
  <key>CFBundleExecutable</key><string>LastCall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
    codesign --force -s - "$NEW" >/dev/null 2>&1 || say "            ad-hoc signing failed; the app may need a right-click Open the first time"
    pkill -f "$APP/Contents/MacOS/LastCall" >/dev/null 2>&1 || true
    rm -rf "$APP.old"
    if [ -d "$APP" ]; then mv "$APP" "$APP.old"; fi
    if ! mv "$NEW" "$APP"; then
      # Put the previous app back so the user is never left without one.
      if [ -d "$APP.old" ]; then mv "$APP.old" "$APP"; fi
      say "app         could not replace $APP; kept the previous version. The hook is installed."
      exit 1
    fi
    rm -rf "$APP.old" "$BUILD"
    say "app         $APP"
    if [ "${LASTCALL_NO_OPEN:-0}" != "1" ]; then if open "$APP"; then say "            opened (look for LC in the menu bar)"; else say "            could not open it; open $APP by hand"; fi; fi
  else
    say "app         build failed, hook still works. Log: $BUILD/log"
  fi
else
  say "app         skipped (no swiftc; install Xcode Command Line Tools to get it). The hook works without it."
fi

echo
echo "Done. Claude Code sessions started from now on get a last call when the battery runs low."
echo "Running sessions pick it up on their next settings reload or restart."
echo "Try it:  LASTCALL_FAKE_BATTERY=8 claude"
echo "Remove:  curl -fsSL $BASE_URL/uninstall.sh | bash"
