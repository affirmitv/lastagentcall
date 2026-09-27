#!/bin/bash
# Last Call uninstaller. https://lastagentcall.com
#   curl -fsSL https://lastagentcall.com/uninstall.sh | bash
# Removes only what install.sh added. Other hooks and settings stay as they are.
set -euo pipefail

LC="$HOME/.lastcall"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
APP="$HOME/Applications/Last Call.app"
AGENT="$HOME/Library/LaunchAgents/com.lastagentcall.menubar.plist"
say() { printf '  %s\n' "$*"; }

echo "Removing Last Call"

if [ -f "$SETTINGS" ]; then
  BACKUP="$SETTINGS.lastcall-backup-$(date +%Y%m%d-%H%M%S)"
  cp -p "$SETTINGS" "$BACKUP"
  say "backup      $BACKUP"
  if [ "${LASTCALL_USE_JQ:-0}" != "1" ] && command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
    HELPER="$LC/bin/lastcall-settings.py"
    if [ ! -f "$HELPER" ]; then
      HELPER="$(mktemp)"; curl -fsSL "${LASTCALL_BASE_URL:-https://lastagentcall.com}/scripts/settings.py" -o "$HELPER"
    fi
    python3 "$HELPER" uninstall "$SETTINGS" ""
  elif command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp "$(dirname "$SETTINGS")/.settings.XXXXXX")"
    jq '
      def strip: map(if (.hooks|type)=="array" then .hooks |= map(select(((.command // "")|tostring|contains("lastcall-hook.sh"))|not)) else . end)
                 | map(select((.hooks|type)!="array" or (.hooks|length)>0));
      if (.hooks|type)=="object" then
        .hooks |= (with_entries(if (.key=="PreToolUse" or .key=="PostToolUse" or .key=="UserPromptSubmit") then .value |= strip else . end)
                   | with_entries(select((.value|type)!="array" or (.value|length)>0)))
        | if (.hooks|length)==0 then del(.hooks) else . end
      else . end
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  else
    echo "Need python3 or jq to edit $SETTINGS. Remove the lastcall-hook.sh entries by hand." >&2
  fi
  say "unhooked    $SETTINGS"
fi

pkill -x LastCall >/dev/null 2>&1 || true
if [ -f "$AGENT" ]; then rm -f "$AGENT"; say "removed     $AGENT"; fi
if [ -d "$APP" ]; then rm -rf "$APP"; say "removed     $APP"; rmdir "$HOME/Applications" 2>/dev/null || true; fi
if [ -d "$LC" ]; then rm -rf "$LC"; say "removed     $LC"; fi

echo
echo "Done. HANDOFF.md files in your projects were left alone."
