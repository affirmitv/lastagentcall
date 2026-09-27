#!/bin/bash
# Last Call: a Claude Code hook that wraps up agent sessions before the battery dies.
# https://lastagentcall.com  (MIT)
#
# Reads the hook event JSON on stdin, checks the battery with `pmset -g batt`,
# and answers with hook JSON on stdout. It always exits 0 and fails open:
# any error means "say nothing", which lets the tool run as normal.
#
# Levels (override in ~/.lastcall/config):
#   WARN_AT=20  finish the current step, do not start long jobs
#   WRAP_AT=10  block subagents and long commands, write a handoff, commit WIP, stop
#   STOP_AT=5   block everything except writing the handoff and git
# Plugged in or no battery (desktop): silent.
#
# Test hooks:
#   LASTCALL_FAKE_BATTERY=8           on battery at 8%
#   LASTCALL_FAKE_BATTERY=8:charging  plugged in at 8%
#   LASTCALL_FAKE_BATTERY=none        no battery (desktop)
#   LASTCALL_HOME=/some/dir           instead of ~/.lastcall

main() {
  local home_dir="${LASTCALL_HOME:-$HOME/.lastcall}"
  local warn_at=20 wrap_at=10 stop_at=5 enabled=1

  # Config: plain KEY=VALUE lines. Parsed, never sourced.
  if [ -f "$home_dir/config" ]; then
    local key val
    while IFS='=' read -r key val; do
      key="${key//[[:space:]]/}"; val="${val//[[:space:]]/}"
      case "$val" in ''|*[!0-9]*) continue ;; esac
      case "$key" in
        WARN_AT) warn_at=$val ;;
        WRAP_AT) wrap_at=$val ;;
        STOP_AT) stop_at=$val ;;
        ENABLED) enabled=$val ;;
      esac
    done < "$home_dir/config"
  fi
  [ "$enabled" = "0" ] && return 0

  # Battery: percent + whether we are on battery.
  local pct="" on_battery=0 raw
  if [ -n "${LASTCALL_FAKE_BATTERY:-}" ]; then
    raw="$LASTCALL_FAKE_BATTERY"
    case "$raw" in
      none) pct="" ;;
      *:charging|*:ac) pct="${raw%%:*}"; on_battery=0 ;;
      *) pct="$raw"; on_battery=1 ;;
    esac
  else
    raw="$(/usr/bin/pmset -g batt 2>/dev/null)" || return 0
    case "$raw" in *InternalBattery*) ;; *) return 0 ;; esac
    case "$raw" in *"'Battery Power'"*) on_battery=1 ;; esac
    pct="$(printf '%s' "$raw" | /usr/bin/sed -n 's/.*[[:space:]]\([0-9][0-9]*\)%.*/\1/p' | head -n 1)"
  fi
  case "$pct" in ''|*[!0-9]*) return 0 ;; esac

  local level=0
  if [ "$on_battery" = "1" ]; then
    if [ "$pct" -le "$stop_at" ]; then level=3
    elif [ "$pct" -le "$wrap_at" ]; then level=2
    elif [ "$pct" -le "$warn_at" ]; then level=1
    fi
  fi
  # Manual "Wrap up all agents now" from the menu bar app counts as the wrap level.
  local manual=0
  if [ -f "$home_dir/override" ] && [ "$level" -lt 2 ]; then level=2; manual=1; fi
  [ "$level" -eq 0 ] && return 0

  # Read the event. Only the fields we need.
  local input event tool cmd fpath sid
  input="$(cat)"
  [ -n "$input" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" || return 0
    tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    fpath="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
  else
    event="$(printf '%s' "$input" | /usr/bin/sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | head -n 1)"
    tool="$(printf '%s' "$input" | /usr/bin/sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([A-Za-z_0-9]*\)".*/\1/p' | head -n 1)"
    cmd="$(printf '%s' "$input" | /usr/bin/sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | head -n 1)"
    fpath="$(printf '%s' "$input" | /usr/bin/sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    sid="$(printf '%s' "$input" | /usr/bin/sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' | head -n 1)"
  fi
  case "$event" in PreToolUse|PostToolUse|UserPromptSubmit) ;; *) return 0 ;; esac

  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local what="Battery at ${pct}%"
  [ "$manual" = "1" ] && what="The user asked all agents to wrap up (battery at ${pct}%)"
  local handoff="Write .lastcall/HANDOFF.md at the project root with four sections: what was done, what is in flight, exact next steps, files touched. Then commit work in progress on a new branch without pushing: git switch -c lastcall/wip-${ts} && git add -A && git commit -m \"Last Call WIP\". Then stop and tell the user where the handoff is."
  local msg
  case "$level" in
    1) msg="Last Call: ${what}. Finish the current step. Do not start long jobs (builds, full test suites, subagent fan-outs)." ;;
    2) msg="Last Call: ${what}. Wrap up now. Subagents and long commands are blocked. ${handoff}" ;;
    3) msg="Last Call: ${what}. Critical. Every tool is blocked except writing .lastcall/HANDOFF.md and git. ${handoff}" ;;
  esac

  # Remember handoff files so the menu bar app can list them.
  if [ "$event" = "PostToolUse" ] && [ -n "$fpath" ]; then
    case "$fpath" in */.lastcall/HANDOFF.md|.lastcall/HANDOFF.md)
      mkdir -p "$home_dir" 2>/dev/null && printf '%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$fpath" >> "$home_dir/handoffs.log" 2>/dev/null ;;
    esac
  fi

  local deny=0
  if [ "$event" = "PreToolUse" ]; then
    local is_handoff=0 is_git=0
    case "$fpath" in */.lastcall/HANDOFF.md|.lastcall/HANDOFF.md) is_handoff=1 ;; esac
    if [ "$tool" = "Bash" ] && is_git_only "$cmd"; then is_git=1; fi
    if [ "$level" -ge 3 ]; then
      if [ "$is_handoff" = "1" ] && { [ "$tool" = "Write" ] || [ "$tool" = "Edit" ] || [ "$tool" = "MultiEdit" ]; }; then deny=0
      elif [ "$is_git" = "1" ]; then deny=0
      else deny=1
      fi
    elif [ "$level" -ge 2 ]; then
      case "$tool" in
        Agent|Task|Workflow|Teammate|TeamCreate) deny=1 ;;
        Bash) is_long_command "$cmd" && deny=1 ;;
      esac
    fi
  fi

  local esc; esc="$(json_escape "$msg")"
  if [ "$event" = "PreToolUse" ]; then
    if [ "$deny" = "1" ]; then
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
    fi
    return 0
  fi

  if [ "$event" = "PostToolUse" ] && [ "$level" -eq 1 ]; then
    # At the warning level, say it once per session per level instead of after every tool.
    if [ -n "$sid" ]; then
      local seen="$home_dir/seen/${sid}.${level}"
      [ -f "$seen" ] && return 0
      mkdir -p "$home_dir/seen" 2>/dev/null && : > "$seen" 2>/dev/null
    fi
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$event" "$esc"
  return 0
}

# True when every part of the command is git, cd, or mkdir of .lastcall.
is_git_only() {
  local c="$1" part
  [ -n "$c" ] || return 1
  case "$c" in *'$('*|*'`'*|*'>'*|*'<'*) return 1 ;; esac
  c="${c//&&/;}"; c="${c//||/;}"; c="${c//|/;}"; c="${c//&/;}"
  local IFS=';'
  for part in $c; do
    part="${part#"${part%%[![:space:]]*}"}"
    [ -z "$part" ] && continue
    case "$part" in
      git|git\ *|cd\ *|"mkdir -p .lastcall"|"mkdir -p .lastcall "*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# True for commands that usually run for minutes.
is_long_command() {
  local c=" $1 "
  local p
  for p in xcodebuild gradle gradlew "docker build" "docker compose build" "docker-compose build" \
           "npm test" "npm run test" "npm run build" "yarn test" "yarn build" "pnpm test" "pnpm build" \
           "npx vitest" vitest jest pytest "cargo build" "cargo test" "go test" "swift build" "swift test" \
           "mvn " "bazel " "next build" "playwright test" "make " "fastlane "; do
    case "$c" in *[[:space:]/\;\&\|]"$p"*) return 0 ;; esac
  done
  return 1
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"
  printf '%s' "$s"
}

main 2>/dev/null
exit 0
