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

BASE_URL="${LASTCALL_BASE_URL:-https://lastagentcall.com}"
UNHOOK_FAILED=0
if [ -f "$SETTINGS" ]; then
  BACKUP="$SETTINGS.lastcall-backup-$(date +%Y%m%d-%H%M%S)"
  cp -p "$SETTINGS" "$BACKUP"
  say "backup      $BACKUP"
  HELPER="$LC/bin/lastcall-settings.py"
  if [ ! -f "$HELPER" ]; then
    # Installed copy is gone: fetch the helper and check it against SHA256SUMS.
    DL="$(mktemp -d)"; trap 'rm -rf "$DL"' EXIT
    HELPER="$DL/settings.py"
    if curl -fsSL "$BASE_URL/SHA256SUMS" -o "$DL/SHA256SUMS" && curl -fsSL "$BASE_URL/scripts/settings.py" -o "$HELPER"; then
      want="$(awk '$2=="scripts/settings.py" {print $1}' "$DL/SHA256SUMS")"
      got="$(shasum -a 256 "$HELPER" | awk '{print $1}')"
      if [ -z "$want" ] || [ "$want" != "$got" ]; then echo "Checksum mismatch for scripts/settings.py." >&2; HELPER=""; fi
    else
      echo "Could not download the settings helper." >&2; HELPER=""
    fi
  fi
  if [ -n "$HELPER" ] && command -v python3 >/dev/null 2>&1 && python3 "$HELPER" uninstall "$SETTINGS"; then
    say "unhooked    $SETTINGS"
  else
    UNHOOK_FAILED=1
    echo "Could not remove the hook from $SETTINGS; it was left as it was." >&2
    echo "Remove the entries that run lastcall-hook.sh by hand, then run this again." >&2
  fi
fi

pkill -f "$APP/Contents/MacOS/LastCall" >/dev/null 2>&1 || true
if [ -f "$AGENT" ]; then rm -f "$AGENT"; say "removed     $AGENT"; fi
if [ -d "$APP" ]; then rm -rf "$APP"; say "removed     $APP"; rmdir "$HOME/Applications" 2>/dev/null || true; fi
if [ "$UNHOOK_FAILED" = 1 ]; then
  # Keep the hook so settings.json does not point at a missing file.
  say "kept        $LC (settings.json still runs its hook)"
  exit 1
fi
if [ -d "$LC" ]; then rm -rf "$LC"; say "removed     $LC"; fi

echo
echo "Done. HANDOFF.md files in your projects were left alone."
