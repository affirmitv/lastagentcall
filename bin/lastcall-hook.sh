#!/bin/bash
# Last Call: a Claude Code hook that wraps up agent sessions before the battery dies.
# https://lastagentcall.com  (MIT)
#
# Reads the hook event JSON on stdin, checks the battery with `pmset -g batt`,
# and answers with hook JSON on stdout. It always exits 0. Reading the battery
# or the input fails open (no output, the tool runs as normal) and the failure
# is written to ~/.lastcall/lastcall.log.
#
# Levels (override in ~/.lastcall/config):
#   WARN_AT=20  finish the current step, do not start long jobs
#   WRAP_AT=10  block subagents and long commands (matched by name), write a handoff, commit WIP, stop
#   STOP_AT=5   block everything except writing .lastcall/HANDOFF.md and a short list of local git commands
# Plugged in or no battery (desktop): silent, unless "Wrap up all agents now" is on.
#
# Test hooks:
#   LASTCALL_FAKE_BATTERY=8           on battery at 8%
#   LASTCALL_FAKE_BATTERY=8:charging  plugged in at 8%
#   LASTCALL_FAKE_BATTERY=none        no battery (desktop)
#   LASTCALL_HOME=/some/dir           instead of ~/.lastcall
#   LASTCALL_NO_JQ=1                  parse with plutil even when jq is installed

LC_HOME="${LASTCALL_HOME:-$HOME/.lastcall}"

# Append one line to ~/.lastcall/lastcall.log. Never fails, never follows a symlink.
lclog() {
  local f="$LC_HOME/lastcall.log"
  [ -d "$LC_HOME" ] && [ -w "$LC_HOME" ] && [ ! -L "$f" ] || return 0
  if [ -f "$f" ] && [ "$(/usr/bin/wc -c < "$f" 2>/dev/null || echo 0)" -gt 262144 ] 2>/dev/null; then
    /bin/mv -f "$f" "$f.1" 2>/dev/null
  fi
  printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*" >> "$f" 2>/dev/null
  return 0
}

main() {
  local home_dir="$LC_HOME"
  local warn_at=20 wrap_at=10 stop_at=5 enabled=1

  # Config: plain KEY=VALUE lines. Parsed, never sourced. The last line may lack a newline.
  if [ -f "$home_dir/config" ]; then
    local key val
    while IFS='=' read -r key val || [ -n "$key" ]; do
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

  # Battery: percent + whether we are on battery. Empty pct = no battery or unreadable.
  local pct="" on_battery=0 raw
  if [ -n "${LASTCALL_FAKE_BATTERY:-}" ]; then
    raw="$LASTCALL_FAKE_BATTERY"
    case "$raw" in
      none) pct="" ;;
      *:charging|*:ac) pct="${raw%%:*}"; on_battery=0 ;;
      *) pct="$raw"; on_battery=1 ;;
    esac
  else
    if raw="$(/usr/bin/pmset -g batt 2>&1)"; then
      case "$raw" in
        *InternalBattery*)
          case "$raw" in *"'Battery Power'"*) on_battery=1 ;; esac
          pct="$(printf '%s' "$raw" | /usr/bin/sed -n 's/.*[[:space:]]\([0-9][0-9]*\)%.*/\1/p' | head -n 1)"
          case "$pct" in ''|*[!0-9]*) lclog "could not read the battery percent from pmset: ${raw:0:200}"; pct="" ;; esac
          ;;
      esac
    else
      lclog "pmset -g batt failed: ${raw:0:200}"
      raw=""
    fi
  fi
  case "$pct" in *[!0-9]*) pct="" ;; esac

  local level=0
  if [ -n "$pct" ] && [ "$on_battery" = "1" ]; then
    if [ "$pct" -le "$stop_at" ]; then level=3
    elif [ "$pct" -le "$wrap_at" ]; then level=2
    elif [ "$pct" -le "$warn_at" ]; then level=1
    fi
  fi
  # Manual "Wrap up all agents now" from the menu bar app counts as the wrap level,
  # plugged in, on battery, or on a Mac with no battery at all.
  local manual=0
  if [ -f "$home_dir/override" ] && [ "$level" -lt 2 ]; then level=2; manual=1; fi
  [ "$level" -eq 0 ] && return 0

  # Read the event. Only the fields we need.
  local input event tool cmd fpath sid cwd
  input="$(cat)"
  [ -n "$input" ] || return 0
  # A real JSON parser: jq when installed, else plutil (part of macOS).
  local PARSER=plutil
  [ -z "${LASTCALL_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1 && PARSER=jq
  if ! event="$(jqf hook_event_name)" || [ -z "$event" ]; then
    lclog "could not parse hook input as JSON with $PARSER (${#input} bytes)"
    return 0
  fi
  tool="$(jqf tool_name)"
  event="${event//[!A-Za-z0-9_]/}"; tool="${tool//[!A-Za-z0-9_]/}"
  # The rest only when this event needs it (keeps the hook fast).
  case "$event:$tool" in PreToolUse:Bash) cmd="$(jqf tool_input.command)" ;; esac
  case "$event:$tool" in PreToolUse:Write|PreToolUse:Edit|PreToolUse:MultiEdit|PostToolUse:*)
    fpath="$(jqf tool_input.file_path)"
    case "$fpath" in */.lastcall/HANDOFF.md|.lastcall/HANDOFF.md) cwd="$(jqf cwd)" ;; esac ;;
  esac
  [ "$event" = PostToolUse ] && [ "$level" -eq 1 ] && sid="$(jqf session_id)"
  case "$event" in PreToolUse|PostToolUse|UserPromptSubmit) ;; *) return 0 ;; esac

  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local what="Battery at ${pct}%"
  if [ "$manual" = "1" ]; then
    if [ -n "$pct" ]; then what="The user asked all agents to wrap up (battery at ${pct}%)"
    else what="The user asked all agents to wrap up"; fi
  fi
  local handoff="Write .lastcall/HANDOFF.md at the project root with four sections: what was done, what is in flight, exact next steps, files touched. Then commit work in progress on a new branch without pushing, one git command per call (no && or ;): git switch -c lastcall/wip-${ts}, then git add -A, then git commit -m \"Last Call WIP\". Then stop and tell the user where the handoff is."
  local msg
  case "$level" in
    1) msg="Last Call: ${what}. Finish the current step. Do not start long jobs (builds, full test suites, subagent fan-outs)." ;;
    2) msg="Last Call: ${what}. Wrap up now. Subagents and long commands are blocked. ${handoff}" ;;
    3) msg="Last Call: ${what}. Critical. Every tool is blocked except writing .lastcall/HANDOFF.md and plain local git (status, diff, add, commit -m, stash, log, branch, switch -c lastcall/wip-*), plus mkdir -p .lastcall. ${handoff}" ;;
  esac

  # Remember handoff files (with the session cwd) so the menu bar app can list them.
  if [ "$event" = "PostToolUse" ] && [ -n "$fpath" ] && is_handoff_path "$fpath" "$cwd"; then
    if [ -d "$home_dir" ] || mkdir -p "$home_dir" 2>/dev/null; then
      if [ -L "$home_dir/handoffs.log" ]; then lclog "handoffs.log is a symlink; not writing it"
      else printf '%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$fpath" "$cwd" >> "$home_dir/handoffs.log" 2>/dev/null || lclog "could not append to handoffs.log"
      fi
    fi
  fi

  local deny=0
  if [ "$event" = "PreToolUse" ]; then
    if [ "$level" -ge 3 ]; then
      deny=1
      case "$tool" in
        Write|Edit|MultiEdit) is_handoff_path "$fpath" "$cwd" && deny=0 ;;
        Bash) { is_safe_git "$cmd" || is_mkdir_lastcall "$cmd"; } && deny=0 ;;
      esac
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
    if true; then
      local sdir="$home_dir/seen" seen
      seen="$sdir/$(safe_id "$sid").${level}"
      [ -f "$seen" ] && return 0
      if [ -L "$sdir" ] || [ -L "$seen" ]; then
        lclog "seen marker path is a symlink; not writing it"
      elif mkdir -p "$sdir" 2>/dev/null && : > "$seen" 2>/dev/null; then
        # Markers are only needed for a few hours; keep the directory small.
        /usr/bin/find "$sdir" -type f -mtime +14 -delete 2>/dev/null
      else
        lclog "could not write seen marker in $sdir"
      fi
    fi
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$event" "$esc"
  return 0
}

# One string field (dotted key path) from the event JSON in $input.
# Empty when missing; non-zero exit when the input is not valid JSON.
jqf() {
  if [ "$PARSER" = jq ]; then
    printf '%s' "$input" | jq -r ".$1 // \"\" | tostring" 2>/dev/null
  else
    local out
    out="$(printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>&1)" && { printf '%s' "$out"; return 0; }
    case "$out" in *"No value at that key path"*) return 0 ;; esac
    return 1
  fi
}

# A session id that is safe as a file name: [A-Za-z0-9._-], at most 128 chars,
# not starting with a dot. Anything else is replaced by its SHA-256.
safe_id() {
  local s="$1"
  if [ -n "$s" ] && [ "${#s}" -le 128 ]; then
    case "$s" in .*|*[!A-Za-z0-9._-]*) ;; *) printf '%s' "$s"; return 0 ;; esac
  fi
  local h; h="$(printf '%s' "$s" | /usr/bin/shasum -a 256 2>/dev/null)"
  h="${h%% *}"
  [ -n "$h" ] || h="unknown"
  printf '%s' "$h"
}

# True when $1 is <project>/.lastcall/HANDOFF.md, where <project> is the session
# cwd or one of its parents (or the exact relative path .lastcall/HANDOFF.md).
# No "..", no "." segments, no control characters, and .lastcall must not be a symlink.
is_handoff_path() {
  local p="$1" cwd="$2" root
  [ -n "$p" ] || return 1
  case "$p$cwd" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  case "$p" in */../*|../*|*/..|*/./*|./*|*//*) return 1 ;; esac
  if [ "$p" = ".lastcall/HANDOFF.md" ]; then
    [ -n "$cwd" ] || return 1
    root="$cwd"
  else
    case "$p" in /*/.lastcall/HANDOFF.md) ;; *) return 1 ;; esac
    root="${p%/.lastcall/HANDOFF.md}"
    [ -n "$cwd" ] || return 1
    case "$cwd" in *$'\n'*|*/../*|*/..) return 1 ;; esac
    cwd="${cwd%/}"
    [ "$cwd" = "$root" ] || case "$cwd/" in "$root"/*) ;; *) return 1 ;; esac
  fi
  [ -L "$root/.lastcall" ] && return 1
  [ -L "$root/.lastcall/HANDOFF.md" ] && return 1
  return 0
}

# True only for exactly "mkdir .lastcall" or "mkdir -p .lastcall", so the
# handoff can be written in a project that has no .lastcall directory yet.
is_mkdir_lastcall() {
  case "$1" in "mkdir .lastcall"|"mkdir -p .lastcall") return 0 ;; esac
  return 1
}

# The 5% allowlist. True only for one plain local git command:
#   git status | diff | log | rev-parse | add | commit (-m) | stash [push|save|list|show]
#   | branch (list or create) | switch -c lastcall/wip-* | checkout -b lastcall/wip-*
# No shell syntax at all, no global git options (so no -c overrides), no network
# or history-rewriting subcommands.
is_safe_git() {
  local c="$1"
  [ -n "$c" ] || return 1
  case "$c" in
    *$'\n'*|*$'\r'*|*'`'*|*'$'*|*';'*|*'&'*|*'|'*|*'>'*|*'<'*|*'('*|*')'*|*'{'*|*'}'*|*\\*) return 1 ;;
  esac
  c="${c//\"/}"; c="${c//\'/}"
  local -a w
  set -f; w=($c); set +f
  [ "${w[0]:-}" = "git" ] || return 1
  local sub="${w[1]:-}" n=${#w[@]} i t
  # Options that run programs, write files, or point git somewhere else.
  for ((i=2; i<n; i++)); do
    t="${w[$i]}"
    case "$t" in
      --output|--output=*|--exec*|--upload-pack*|--receive-pack*|--ext-diff|--textconv|--config*|--git-dir*|--work-tree*|--namespace*|--template*|--no-index) return 1 ;;
    esac
  done
  case "$sub" in
    status|diff|log|rev-parse) return 0 ;;
    add)
      for ((i=2; i<n; i++)); do
        case "${w[$i]}" in -i|--interactive|-p|--patch|-e|--edit) return 1 ;; esac
      done
      return 0 ;;
    commit)
      local has_msg=0
      for ((i=2; i<n; i++)); do
        case "${w[$i]}" in
          -e|--edit|-i|--interactive|-p|--patch|--fixup*|--squash*|--amend|-F|--file*) return 1 ;;
          -m|-am|-m?*|-am?*|--message|--message=*) has_msg=1 ;;
        esac
      done
      [ "$has_msg" = 1 ]; return $? ;;
    branch)
      # List, or create a branch. Options must come from this short list.
      for ((i=2; i<n; i++)); do
        case "${w[$i]}" in
          -*) case "${w[$i]}" in -a|--all|-v|-vv|--verbose|-l|--list|--show-current|-r|--remotes|--no-color) ;; *) return 1 ;; esac ;;
        esac
      done
      return 0 ;;
    stash)
      case "${w[2]:-}" in ''|push|save|list|show|-m|--message|-u|--include-untracked|-q|--quiet) ;; *) return 1 ;; esac
      for ((i=2; i<n; i++)); do
        case "${w[$i]}" in -p|--patch) return 1 ;; esac
      done
      return 0 ;;
    switch|checkout)
      [ "$n" -eq 4 ] || return 1
      case "$sub:${w[2]}" in switch:-c|switch:--create|checkout:-b) ;; *) return 1 ;; esac
      case "${w[3]}" in lastcall/wip-*) ;; *) return 1 ;; esac
      case "${w[3]#lastcall/wip-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
      return 0 ;;
  esac
  return 1
}

# True for commands that usually run for minutes. Name based: each part of the
# command (split on ; && || | &) is checked after stripping env VAR=..., time,
# nice, nohup, command, exec, and sh/bash/zsh -c wrappers.
is_long_command() {
  local c="$1"
  [ -n "$c" ] || return 1
  c="${c//\"/ }"; c="${c//\'/ }"; c="${c//(/ }"; c="${c//)/ }"; c="${c//\`/ }"
  c="${c//$'\n'/;}"; c="${c//$'\r'/;}"; c="${c//&&/;}"; c="${c//||/;}"; c="${c//|/;}"; c="${c//&/;}"
  local seg IFS=';'
  local -a segs
  set -f; segs=($c); set +f
  IFS=$' \t'
  for seg in "${segs[@]}"; do
    long_segment "$seg" && return 0
  done
  return 1
}

long_segment() {
  local -a w
  set -f; w=($1); set +f
  local n=${#w[@]} i=0 t
  # Strip wrappers.
  while [ "$i" -lt "$n" ]; do
    t="${w[$i]}"
    case "$t" in
      env|time|nohup|command|exec|builtin|caffeinate|/usr/bin/env|/usr/bin/time) i=$((i+1)) ;;
      -u|-C|-S|-P|-n|-w|-o|-t) # wrapper options that take a value (env -u VAR, env -C dir, nice -n 10)
        if [ "$i" -gt 0 ]; then i=$((i+2)); else break; fi ;;
      -*) # any other option of a wrapper we already skipped
        if [ "$i" -gt 0 ]; then i=$((i+1)); else break; fi ;;
      nice|/usr/bin/nice) i=$((i+1)); [ "${w[$i]:-}" = "-n" ] && i=$((i+2)) ;;
      [A-Za-z_]*=*) i=$((i+1)) ;;
      sh|bash|zsh|/bin/sh|/bin/bash|/bin/zsh)
        if [ "${w[$((i+1))]:-}" = "-c" ] || [ "${w[$((i+1))]:-}" = "-lc" ]; then i=$((i+2)); else break; fi ;;
      *) break ;;
    esac
  done
  local cmd="${w[$i]:-}" a1="${w[$((i+1))]:-}" a2="${w[$((i+2))]:-}"
  cmd="${cmd##*/}"
  # Package runners: look at the tool they run, skipping the runner's own options.
  local j=-1
  case "$cmd:$a1" in
    npx:*|bunx:*|pnpx:*) j=$((i+1)) ;;
    pnpm:dlx|pnpm:exec|yarn:dlx|yarn:exec|bun:x) j=$((i+2)) ;;
  esac
  if [ "$j" -ge 0 ]; then
    while [ "$j" -lt "$n" ]; do
      case "${w[$j]}" in
        -p|--package|-c|--call) j=$((j+2)) ;;
        -*) j=$((j+1)) ;;
        *) break ;;
      esac
    done
    cmd="${w[$j]:-}"; a1="${w[$((j+1))]:-}"; a2="${w[$((j+2))]:-}"
    cmd="${cmd##*/}"
    cmd="${cmd%%@*}"
  fi
  case "$cmd" in
    npm|pnpm|yarn|bun)
      # Skip global options (npm --silent test, pnpm --filter api test) to find the subcommand.
      local k=$((i+1)) sub=""
      while [ "$k" -lt "$n" ]; do
        case "${w[$k]}" in
          --*=*) k=$((k+1)) ;;
          -w|--workspace|--filter|-F|--prefix|-C|--dir|--cwd|--loglevel) k=$((k+2)) ;;
          -*) k=$((k+1)) ;;
          *) sub="${w[$k]}"; break ;;
        esac
      done
      [ -z "$sub" ] && [ "$cmd" = yarn ] && return 0
      case "$sub" in install|i|ci|add|test|t|build|run|run-script|start|workspace|workspaces) return 0 ;; esac ;;
    pip|pip3|gem|brew|uv|poetry|pipenv|conda) case "$a1" in install|sync|upgrade|update|create) return 0 ;; esac ;;
    bundle) case "$a1" in install|exec) return 0 ;; esac ;;
    pod) case "$a1" in install|update) return 0 ;; esac ;;
    swift) case "$a1" in build|test) return 0 ;; esac ;;
    cargo) case "$a1" in build|test|b|t|bench|install) return 0 ;; esac ;;
    go) case "$a1" in test|build|install) return 0 ;; esac ;;
    docker|podman) case "$a1" in build|buildx|compose) return 0 ;; esac ;;
    docker-compose|podman-compose) return 0 ;;
    make|gmake|gradle|gradlew|mvn|mvnw|xcodebuild|pytest|py.test|tox|bazel|bazelisk|fastlane|jest|vitest|ctest|cmake|ninja) return 0 ;;
    python|python3) [ "$a1" = "-m" ] && case "$a2" in pytest|unittest|tox) return 0 ;; esac ;;
    next) [ "$a1" = build ] && return 0 ;;
    playwright) [ "$a1" = test ] && return 0 ;;
    sleep)
      local s="$a1" mult=1
      case "$s" in *s) s="${s%s}" ;; *m) s="${s%m}"; mult=60 ;; *h) s="${s%h}"; mult=3600 ;; *d) s="${s%d}"; mult=86400 ;; esac
      s="${s%%.*}"
      case "$s" in ''|*[!0-9]*) return 1 ;; esac
      [ "${#s}" -gt 6 ] && return 0
      [ $((10#$s * mult)) -gt 60 ] && return 0 ;;
  esac
  return 1
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"
  printf '%s' "$s"
}

# Send stray errors to the log when it can be opened; otherwise discard them.
# Opening is tried first, so an unwritable log never stops the hook from running.
if [ ! -L "$LC_HOME/lastcall.log" ] && { exec 3>>"$LC_HOME/lastcall.log"; } 2>/dev/null; then
  main 2>&3
else
  main 2>/dev/null
fi
exit 0
