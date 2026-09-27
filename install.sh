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

# Find source files: next to this script when run from a checkout, else download.
SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/bin/lastcall-hook.sh" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SRC="$(mktemp -d)"
  trap 'rm -rf "$SRC"' EXIT
  mkdir -p "$SRC/bin" "$SRC/app" "$SRC/scripts"
  for f in bin/lastcall-hook.sh app/LastCall.swift scripts/settings.py; do
    curl -fsSL "$BASE_URL/$f" -o "$SRC/$f"
  done
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
if [ "${LASTCALL_USE_JQ:-0}" != "1" ] && command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
  python3 "$LC/bin/lastcall-settings.py" install "$SETTINGS" "$HOOK_CMD"
elif command -v jq >/dev/null 2>&1; then
  [ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  tmp="$(mktemp "$(dirname "$SETTINGS")/.settings.XXXXXX")"
  jq --arg cmd "$HOOK_CMD" '
    def strip: map(if (.hooks|type)=="array" then .hooks |= map(select(((.command // "")|tostring|contains("lastcall-hook.sh"))|not)) else . end)
               | map(select((.hooks|type)!="array" or (.hooks|length)>0));
    .hooks = (.hooks // {})
    | .hooks.PreToolUse = ((.hooks.PreToolUse // [])|strip) + [{"matcher":"*","hooks":[{"type":"command","command":$cmd,"timeout":5}]}]
    | .hooks.PostToolUse = ((.hooks.PostToolUse // [])|strip) + [{"matcher":"*","hooks":[{"type":"command","command":$cmd,"timeout":5}]}]
    | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [])|strip) + [{"hooks":[{"type":"command","command":$cmd,"timeout":5}]}]
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
else
  echo "Need python3 or jq to edit $SETTINGS safely. Nothing was changed there." >&2
  exit 1
fi
say "hooked      PreToolUse, PostToolUse, UserPromptSubmit in $SETTINGS"

# 3. Menu bar app (optional, built from source so it needs no notarization)
if [ "${LASTCALL_NO_APP:-0}" = "1" ]; then
  say "app         skipped (LASTCALL_NO_APP=1)"
elif command -v swiftc >/dev/null 2>&1; then
  BUILD="$(mktemp -d)"
  if swiftc -O -o "$BUILD/LastCall" "$SRC/app/LastCall.swift" -framework AppKit -framework IOKit >"$BUILD/log" 2>&1; then
    pkill -x LastCall >/dev/null 2>&1 || true
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    cp "$BUILD/LastCall" "$APP/Contents/MacOS/LastCall"
    cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Last Call</string>
  <key>CFBundleIdentifier</key><string>com.lastagentcall.menubar</string>
  <key>CFBundleExecutable</key><string>LastCall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
    codesign --force -s - "$APP" >/dev/null 2>&1 || true
    say "app         $APP"
    if [ "${LASTCALL_NO_OPEN:-0}" != "1" ]; then open "$APP" && say "            opened (look for LC in the menu bar)"; fi
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
