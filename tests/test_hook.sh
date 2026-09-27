#!/bin/bash
# Tests for bin/lastcall-hook.sh. Fakes battery levels; needs jq.
# Run: bash tests/test_hook.sh
set -u
cd "$(dirname "$0")/.."
HOOK="$PWD/bin/lastcall-hook.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LASTCALL_HOME="$TMP/home"
mkdir -p "$LASTCALL_HOME"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL  %s\n      got: %s\n' "$1" "$2"; }

# run <battery> <json>  -> sets OUT and RC
run() {
  OUT="$(printf '%s' "$2" | LASTCALL_FAKE_BATTERY="$1" "$HOOK")"; RC=$?
}
decision() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null; }
context()  { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }

pre()  { printf '{"session_id":"t","cwd":"/tmp/p","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$1" "$2"; }
post() { printf '{"session_id":"%s","cwd":"/tmp/p","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":%s}' "$1" "$2" "$3"; }
prompt='{"session_id":"t","cwd":"/tmp/p","hook_event_name":"UserPromptSubmit","prompt":"keep going"}'

expect_silent() { # name battery json
  run "$2" "$3"
  if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "$1"; else bad "$1" "rc=$RC out=$OUT"; fi
}
expect_deny() {
  run "$2" "$3"
  if [ "$RC" = 0 ] && [ "$(decision)" = deny ] && printf '%s' "$OUT" | jq -e . >/dev/null; then ok "$1"; else bad "$1" "rc=$RC out=$OUT"; fi
}
expect_allow() { # allowed = exit 0 and no deny
  run "$2" "$3"
  if [ "$RC" = 0 ] && [ "$(decision)" != deny ]; then ok "$1"; else bad "$1" "rc=$RC out=$OUT"; fi
}
expect_context() { # name battery json substring
  run "$2" "$3"
  if [ "$RC" = 0 ] && context | grep -q -- "$4"; then ok "$1"; else bad "$1" "rc=$RC out=$OUT"; fi
}

echo "== plugged in and desktop: silent"
expect_silent "plugged in at 3% says nothing"        "3:charging" "$prompt"
expect_silent "plugged in at 3% allows subagents"    "3:charging" "$(pre Agent '{"prompt":"x"}')"
expect_silent "desktop (no battery) says nothing"    "none"       "$(pre Agent '{"prompt":"x"}')"
expect_silent "above 20% says nothing"               "55"         "$prompt"
expect_silent "above 20% allows xcodebuild"          "55"         "$(pre Bash '{"command":"xcodebuild -scheme App"}')"

echo "== 20%: warn"
expect_context "prompt gets battery context at 20%"  "20" "$prompt" "Battery at 20%"
expect_context "warning names long jobs"             "15" "$prompt" "Do not start long jobs"
expect_allow   "subagent still allowed at 15%"       "15" "$(pre Agent '{"prompt":"x"}')"
expect_allow   "build still allowed at 15%"          "15" "$(pre Bash '{"command":"npm run build"}')"
expect_context "first tool result at 15% gets context" "15" "$(post s15 Read '{"file_path":"/tmp/p/a"}')" "Battery at 15%"
expect_silent  "second tool result at 15% is quiet"  "15" "$(post s15 Read '{"file_path":"/tmp/p/a"}')"

echo "== 10%: wrap up"
expect_deny    "Agent tool blocked at 10%"           "10" "$(pre Agent '{"prompt":"x"}')"
expect_deny    "Task tool blocked at 8%"             "8"  "$(pre Task '{"prompt":"x"}')"
expect_deny    "Workflow blocked at 8%"              "8"  "$(pre Workflow '{"script":"x"}')"
expect_deny    "xcodebuild blocked at 8%"            "8"  "$(pre Bash '{"command":"cd ios && xcodebuild -scheme App"}')"
expect_deny    "gradle blocked at 8%"                "8"  "$(pre Bash '{"command":"./gradlew assembleDebug"}')"
expect_deny    "docker build blocked at 8%"          "8"  "$(pre Bash '{"command":"docker build -t x ."}')"
expect_deny    "full test run blocked at 8%"         "8"  "$(pre Bash '{"command":"npm test"}')"
expect_allow   "ls allowed at 8%"                    "8"  "$(pre Bash '{"command":"ls -la"}')"
expect_allow   "Edit allowed at 8%"                  "8"  "$(pre Edit '{"file_path":"/tmp/p/a.ts"}')"
expect_allow   "git commit allowed at 8%"            "8"  "$(pre Bash '{"command":"git add -A && git commit -m wip"}')"
run 8 "$(pre Agent '{"prompt":"x"}')"
if printf '%s' "$OUT" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -q 'lastcall/wip-[0-9]\{8\}-[0-9]\{6\}' \
   && printf '%s' "$OUT" | grep -q 'HANDOFF.md'; then ok "deny reason names HANDOFF.md and a wip branch"; else bad "deny reason" "$OUT"; fi
expect_context "prompt at 8% says wrap up"           "8"  "$prompt" "Wrap up now"
expect_context "every tool result at 8% says wrap up" "8" "$(post s8 Read '{"file_path":"/tmp/p/a"}')" "Wrap up now"

echo "== 5%: only handoff and git"
expect_deny    "Read blocked at 5%"                  "5"  "$(pre Read '{"file_path":"/tmp/p/a"}')"
expect_deny    "Edit of other file blocked at 5%"    "5"  "$(pre Edit '{"file_path":"/tmp/p/src/a.ts"}')"
expect_deny    "ls blocked at 5%"                    "5"  "$(pre Bash '{"command":"ls"}')"
expect_deny    "git piped into sh blocked at 5%"     "5"  "$(pre Bash '{"command":"git log | sh"}')"
expect_deny    "git with subshell blocked at 5%"     "5"  "$(pre Bash '{"command":"git commit -m $(rm -rf x)"}')"
expect_allow   "Write HANDOFF.md allowed at 5%"      "5"  "$(pre Write '{"file_path":"/tmp/p/.lastcall/HANDOFF.md","content":"x"}')"
expect_allow   "git switch/add/commit allowed at 3%" "3"  "$(pre Bash '{"command":"git switch -c lastcall/wip-1 && git add -A && git commit -m \"Last Call WIP\""}')"
expect_allow   "mkdir .lastcall allowed at 3%"       "3"  "$(pre Bash '{"command":"mkdir -p .lastcall"}')"

echo "== manual override"
touch "$LASTCALL_HOME/override"
expect_deny    "override blocks subagents at 90%"    "90" "$(pre Agent '{"prompt":"x"}')"
expect_context "override explains itself"            "90" "$prompt" "asked all agents to wrap up"
expect_deny    "override applies even when plugged in" "90:charging" "$(pre Agent '{"prompt":"x"}')"
rm -f "$LASTCALL_HOME/override"
expect_silent  "resume normal clears it"             "90" "$(pre Agent '{"prompt":"x"}')"

echo "== config"
printf 'WARN_AT=50\nWRAP_AT=40\nSTOP_AT=30\n' > "$LASTCALL_HOME/config"
expect_deny    "custom WRAP_AT=40 blocks at 35%"     "35" "$(pre Agent '{"prompt":"x"}')"
printf 'ENABLED=0\n' > "$LASTCALL_HOME/config"
expect_silent  "ENABLED=0 turns it off"              "2"  "$(pre Agent '{"prompt":"x"}')"
printf 'WARN_AT=$(touch %s/pwned)\n' "$TMP" > "$LASTCALL_HOME/config"
run 15 "$prompt"
if [ ! -e "$TMP/pwned" ] && [ "$RC" = 0 ]; then ok "config is parsed, never executed"; else bad "config exec" "$OUT"; fi
rm -f "$LASTCALL_HOME/config"

echo "== handoff log"
run 8 "$(post s8 Write '{"file_path":"/tmp/p/.lastcall/HANDOFF.md","content":"x"}')"
if grep -q '/tmp/p/.lastcall/HANDOFF.md' "$LASTCALL_HOME/handoffs.log" 2>/dev/null; then ok "handoff write is logged"; else bad "handoff log" "missing"; fi

echo "== fails open"
expect_silent "empty stdin"                          "8" ""
expect_silent "garbage stdin"                        "8" "this is not json {{{"
expect_silent "truncated json"                       "8" '{"hook_event_name":"PreToolUse","tool_name":"Age'
expect_silent "unknown event"                        "8" '{"hook_event_name":"Stop"}'
expect_silent "garbage battery value"                "abc" "$(pre Agent '{"prompt":"x"}')"
LASTCALL_HOME=/dev/null/nope run 8 "$prompt"
if [ "$RC" = 0 ]; then ok "unwritable home still exits 0"; else bad "unwritable home" "rc=$RC"; fi

echo "== speed"
start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
for i in 1 2 3 4 5 6 7 8 9 10; do printf '%s' "$(pre Bash '{"command":"ls"}')" | LASTCALL_FAKE_BATTERY=8 "$HOOK" >/dev/null; done
end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
avg=$(( (end-start)/10 ))
if [ "$avg" -lt 50 ]; then ok "average run ${avg}ms (< 50ms)"; else bad "speed" "${avg}ms"; fi
if [ -z "${LASTCALL_FAKE_BATTERY:-}" ]; then
  start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  for i in 1 2 3 4 5; do printf '%s' "$prompt" | "$HOOK" >/dev/null; done
  end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  avg=$(( (end-start)/5 ))
  if [ "$avg" -lt 50 ]; then ok "average run with real pmset ${avg}ms (< 50ms)"; else bad "speed real pmset" "${avg}ms"; fi
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
