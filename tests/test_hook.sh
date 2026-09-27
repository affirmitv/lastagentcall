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
expect_allow   "git switch -c lastcall/wip allowed at 3%" "3" "$(pre Bash '{"command":"git switch -c lastcall/wip-20260926-101010"}')"
expect_allow   "git checkout -b lastcall/wip allowed" "3" "$(pre Bash '{"command":"git checkout -b lastcall/wip-1"}')"
expect_allow   "git add -A allowed at 3%"            "3"  "$(pre Bash '{"command":"git add -A"}')"
expect_allow   "git commit -m allowed at 5%"         "5"  "$(pre Bash '{"command":"git commit -m \"Last Call WIP\""}')"
expect_allow   "git commit -am allowed at 5%"        "5"  "$(pre Bash '{"command":"git commit -am wip"}')"
expect_allow   "git commit --allow-empty -m allowed" "5"  "$(pre Bash '{"command":"git commit --allow-empty -m wip"}')"
expect_allow   "git status allowed at 5%"            "5"  "$(pre Bash '{"command":"git status --short"}')"
expect_allow   "git diff allowed at 5%"              "5"  "$(pre Bash '{"command":"git diff --stat"}')"
expect_allow   "git log allowed at 5%"               "5"  "$(pre Bash '{"command":"git log --oneline -5"}')"
expect_allow   "git rev-parse allowed at 5%"         "5"  "$(pre Bash '{"command":"git rev-parse HEAD"}')"
expect_allow   "git branch list allowed at 5%"       "5"  "$(pre Bash '{"command":"git branch --show-current"}')"
expect_allow   "git stash push -m allowed at 5%"     "5"  "$(pre Bash '{"command":"git stash push -m wip"}')"
expect_allow   "Edit HANDOFF.md allowed at 5%"       "5"  "$(pre Edit '{"file_path":"/tmp/p/.lastcall/HANDOFF.md","old_string":"a","new_string":"b"}')"
expect_allow   "relative .lastcall/HANDOFF.md allowed" "5" "$(pre Write '{"file_path":".lastcall/HANDOFF.md","content":"x"}')"
expect_deny    "relative HANDOFF.md without cwd denied" "5" '{"session_id":"t","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":".lastcall/HANDOFF.md"}}' 
expect_allow   "HANDOFF.md at a parent of cwd allowed" "5" '{"session_id":"t","cwd":"/tmp/p/sub","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/p/.lastcall/HANDOFF.md"}}'

echo "== 5%: bypass attempts are denied"
expect_deny    "newline after git denied"            "5"  "$(pre Bash '{"command":"git status\nrm -rf ./work"}')"
expect_deny    "carriage return after git denied"    "5"  "$(pre Bash '{"command":"git status\rrm -rf ./work"}')"
expect_deny    "chained git && git denied"           "5"  "$(pre Bash '{"command":"git add -A && git commit -m wip"}')"
expect_deny    "git ; rm denied"                     "5"  "$(pre Bash '{"command":"git status; rm -rf x"}')"
expect_deny    "git || rm denied"                    "5"  "$(pre Bash '{"command":"git status || rm -rf x"}')"
expect_deny    "background & denied"                 "5"  "$(pre Bash '{"command":"git status & rm -rf x"}')"
expect_deny    "backticks denied"                    "5"  "$(pre Bash '{"command":"git commit -m `rm -rf x`"}')"
expect_deny    "redirect > denied"                   "5"  "$(pre Bash '{"command":"git log > ~/.bashrc"}')"
expect_deny    "redirect < denied"                   "5"  "$(pre Bash '{"command":"git commit -F - < /etc/passwd"}')"
expect_deny    "subshell ( ) denied"                 "5"  "$(pre Bash '{"command":"(git status)"}')"
expect_deny    "variable expansion denied"           "5"  "$(pre Bash '{"command":"git $X"}')"
expect_deny    "git push denied at 5%"               "5"  "$(pre Bash '{"command":"git push origin main"}')"
expect_deny    "git push --force denied at 5%"       "5"  "$(pre Bash '{"command":"git push --force"}')"
expect_deny    "git reset --hard denied"             "5"  "$(pre Bash '{"command":"git reset --hard HEAD~3"}')"
expect_deny    "git clean -fdx denied"               "5"  "$(pre Bash '{"command":"git clean -fdx"}')"
expect_deny    "git rebase denied"                   "5"  "$(pre Bash '{"command":"git rebase main"}')"
expect_deny    "git merge denied"                    "5"  "$(pre Bash '{"command":"git merge x"}')"
expect_deny    "git pull denied"                     "5"  "$(pre Bash '{"command":"git pull"}')"
expect_deny    "git fetch denied"                    "5"  "$(pre Bash '{"command":"git fetch"}')"
expect_deny    "git remote denied"                   "5"  "$(pre Bash '{"command":"git remote add x y"}')"
expect_deny    "git filter-branch denied"            "5"  "$(pre Bash '{"command":"git filter-branch --all"}')"
expect_deny    "git gc denied"                       "5"  "$(pre Bash '{"command":"git gc --prune=now"}')"
expect_deny    "git config denied"                   "5"  "$(pre Bash '{"command":"git config core.hooksPath /tmp/x"}')"
expect_deny    "git -c override denied"              "5"  "$(pre Bash '{"command":"git -c alias.x=!rm x"}')"
expect_deny    "git -c before status denied"         "5"  "$(pre Bash '{"command":"git -c core.pager=sh status"}')"
expect_deny    "git -C elsewhere denied"             "5"  "$(pre Bash '{"command":"git -C /tmp status"}')"
expect_deny    "git diff --output denied"            "5"  "$(pre Bash '{"command":"git diff --output=/tmp/x"}')"
expect_deny    "quoted --output denied"              "5"  "$(pre Bash '{"command":"git log \"--output=/tmp/x\""}')"
expect_deny    "git diff --no-index denied"          "5"  "$(pre Bash '{"command":"git diff --no-index /etc/hosts /dev/null"}')"
expect_deny    "git diff --ext-diff denied"          "5"  "$(pre Bash '{"command":"git diff --ext-diff"}')"
expect_deny    "git commit -F file denied"           "5"  "$(pre Bash '{"command":"git commit -F /etc/hosts"}')"
expect_deny    "git commit --amend denied"           "5"  "$(pre Bash '{"command":"git commit --amend -m wip"}')"
expect_deny    "git commit without -m denied"        "5"  "$(pre Bash '{"command":"git commit"}')"
expect_deny    "git commit --allow-empty alone denied" "5" "$(pre Bash '{"command":"git commit --allow-empty"}')"
expect_deny    "git branch -D denied"                "5"  "$(pre Bash '{"command":"git branch -D main"}')"
expect_deny    "git stash drop denied"               "5"  "$(pre Bash '{"command":"git stash drop"}')"
expect_deny    "git stash clear denied"              "5"  "$(pre Bash '{"command":"git stash clear"}')"
expect_deny    "git switch other branch denied"      "5"  "$(pre Bash '{"command":"git switch main"}')"
expect_deny    "git switch -c other name denied"     "5"  "$(pre Bash '{"command":"git switch -c feature"}')"
expect_deny    "git checkout file denied"            "5"  "$(pre Bash '{"command":"git checkout -- src/a.ts"}')"
expect_deny    "env prefix before git denied"        "5"  "$(pre Bash '{"command":"GIT_DIR=/x git status"}')"
expect_deny    "bare git denied"                     "5"  "$(pre Bash '{"command":"git"}')"
expect_allow   "mkdir -p .lastcall allowed at 5%"    "5"  "$(pre Bash '{"command":"mkdir -p .lastcall"}')"
expect_deny    "mkdir elsewhere denied at 5%"        "5"  "$(pre Bash '{"command":"mkdir -p /tmp/x"}')"
expect_deny    "mkdir .lastcall plus more denied"    "5"  "$(pre Bash '{"command":"mkdir -p .lastcall x"}')"
expect_deny    "HANDOFF.md with .. denied"           "5"  "$(pre Write '{"file_path":"/tmp/p/../etc/.lastcall/HANDOFF.md","content":"x"}')"
expect_deny    "relative ../.lastcall denied"        "5"  "$(pre Write '{"file_path":"../.lastcall/HANDOFF.md","content":"x"}')"
expect_deny    "HANDOFF.md outside the project denied" "5" "$(pre Write '{"file_path":"/etc/.lastcall/HANDOFF.md","content":"x"}')"
expect_deny    "other name in .lastcall denied"      "5"  "$(pre Write '{"file_path":"/tmp/p/.lastcall/run.sh","content":"x"}')"
expect_deny    "Bash write of HANDOFF.md denied"     "5"  "$(pre Bash '{"command":"cat > .lastcall/HANDOFF.md"}')"
mkdir -p "$TMP/proj" "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$TMP/proj/.lastcall"
expect_deny    "symlinked .lastcall denied"          "5"  "{\"session_id\":\"t\",\"cwd\":\"$TMP/proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/proj/.lastcall/HANDOFF.md\"}}"

echo "== 10%: long commands, matched by name"
for c in "npm install" "npm ci" "npm run lint" "pnpm install" "pnpm build" "yarn" "yarn install" "yarn test" "bun install" "bun run build" "bun test" \
         "bundle install" "pod install" "swift build" "swift test" "cargo build --release" "cargo test" "go test ./..." "go build ./..." \
         "make" "make -j8 all" "gradle build" "./gradlew assembleDebug" "mvn package" "docker build ." "docker compose up" "podman build ." \
         "docker-compose build" "xcodebuild -scheme App" "pytest -q" "python3 -m pytest" "sleep 3600" "sleep 2m" "sleep 61" \
         "env CI=1 npm test" "CI=1 npm test" "time npm test" "nice -n 10 make" "sh -c 'npm test'" "bash -c \\\"cargo build\\\"" \
         "cd web && npm install" "ls; npm install" "npx vitest run" "npx jest" "/usr/local/bin/make" \
         "npx --yes jest" "npx -y vitest run" "npx -p jest jest" "npx jest@29" "pnpm dlx vitest" "bunx --bun vitest" \
         "npm --silent test" "npm --workspace api test" "npm -w api run build" "pnpm --filter api test" "pnpm -C web build" "yarn --cwd web build" \
         "env -u CI npm test" "env -i PATH=/usr/bin make" "env -C web npm install" "nice -n 5 cargo build" "npm --prefix web install" "pip install -r requirements.txt" "brew install ffmpeg" "gem install rails" "uv sync"; do
  expect_deny  "long command blocked at 8%: $c"      "8"  "$(pre Bash "{\"command\":\"$c\"}")"
done
for c in "npm --version" "pnpm --filter api lint" "pip --version" "ls -la" "sleep 5" "sleep 60" "echo then run pytest" "npm --version" "git status" "cat Makefile" "go vet ./..." "swift --version" "docker ps"; do
  expect_allow "short command allowed at 8%: $c"     "8"  "$(pre Bash "{\"command\":\"$c\"}")"
done

echo "== manual override"
touch "$LASTCALL_HOME/override"
expect_deny    "override blocks subagents at 90%"    "90" "$(pre Agent '{"prompt":"x"}')"
expect_context "override explains itself"            "90" "$prompt" "asked all agents to wrap up"
expect_deny    "override applies even when plugged in" "90:charging" "$(pre Agent '{"prompt":"x"}')"
expect_deny    "override works on a desktop with no battery" "none" "$(pre Agent '{"prompt":"x"}')"
expect_context "desktop override explains itself"   "none" "$prompt" "asked all agents to wrap up"
run none "$prompt"
if context | grep -q 'battery at'; then bad "desktop override does not invent a battery level" "$OUT"; else ok "desktop override does not invent a battery level"; fi
expect_deny    "desktop override blocks npm install" "none" "$(pre Bash '{"command":"npm install"}')"
rm -f "$LASTCALL_HOME/override"
expect_silent  "desktop without override stays silent" "none" "$(pre Agent '{"prompt":"x"}')"
expect_silent  "resume normal clears it"             "90" "$(pre Agent '{"prompt":"x"}')"

echo "== config"
printf 'WARN_AT=50\nWRAP_AT=40\nSTOP_AT=30\n' > "$LASTCALL_HOME/config"
expect_deny    "custom WRAP_AT=40 blocks at 35%"     "35" "$(pre Agent '{"prompt":"x"}')"
printf 'ENABLED=0\n' > "$LASTCALL_HOME/config"
expect_silent  "ENABLED=0 turns it off"              "2"  "$(pre Agent '{"prompt":"x"}')"
printf 'WARN_AT=$(touch %s/pwned)\n' "$TMP" > "$LASTCALL_HOME/config"
run 15 "$prompt"
if [ ! -e "$TMP/pwned" ] && [ "$RC" = 0 ]; then ok "config is parsed, never executed"; else bad "config exec" "$OUT"; fi
printf 'WARN_AT=50\nWRAP_AT=40' > "$LASTCALL_HOME/config"
expect_deny    "last config line without a newline is read" "35" "$(pre Agent '{"prompt":"x"}')"
printf 'ENABLED=0' > "$LASTCALL_HOME/config"
expect_silent  "ENABLED=0 without a newline turns it off" "2" "$(pre Agent '{"prompt":"x"}')"
rm -f "$LASTCALL_HOME/config"

echo "== session id is safe as a file name"
mkdir -p "$TMP/outside"
: > "$TMP/outside/victim.1"; echo keep > "$TMP/outside/victim.1"
run 15 "$(post "../../outside/victim" Read '{"file_path":"/tmp/p/a"}')"
if [ "$(cat "$TMP/outside/victim.1")" = keep ] && [ -z "$(find "$TMP" -name 'victim.1' -not -path "$TMP/outside/*")" ]; then ok "path traversal session id stays inside seen/"; else bad "traversal sid" "$(ls -R "$TMP")"; fi
n=$(ls "$LASTCALL_HOME/seen" | grep -c '^[0-9a-f]\{64\}\.1$')
[ "$n" -ge 1 ] && ok "unsafe session id is hashed" || bad "hashed sid" "$(ls "$LASTCALL_HOME/seen")"
long=$(printf 'a%.0s' $(seq 1 300))
run 15 "$(post "$long" Read '{"file_path":"/tmp/p/a"}')"
[ ! -e "$LASTCALL_HOME/seen/$long.1" ] && ok "session id over 128 chars is hashed" || bad "long sid" "kept"
ln -s "$TMP/outside/victim.1" "$LASTCALL_HOME/seen/linked.1"
run 15 "$(post linked Read '{"file_path":"/tmp/p/a"}')"
[ "$(cat "$TMP/outside/victim.1")" = keep ] && ok "symlinked seen file is never written through" || bad "symlink seen" "truncated"

echo "== handoff log"
run 8 "$(post s8 Write '{"file_path":"/tmp/p/.lastcall/HANDOFF.md","content":"x"}')"
if grep -q '/tmp/p/.lastcall/HANDOFF.md' "$LASTCALL_HOME/handoffs.log" 2>/dev/null; then ok "handoff write is logged"; else bad "handoff log" "missing"; fi
run 8 "$(post s8 Write '{"file_path":".lastcall/HANDOFF.md","content":"x"}')"
if tail -n 1 "$LASTCALL_HOME/handoffs.log" | awk -F'\t' '$2==".lastcall/HANDOFF.md" && $3=="/tmp/p" {f=1} END {exit !f}'; then ok "relative handoff is logged with its cwd"; else bad "relative handoff log" "$(tail -n 1 "$LASTCALL_HOME/handoffs.log")"; fi
run 8 "$(post s8 Write '{"file_path":"/etc/.lastcall/HANDOFF.md","content":"x"}')"
if grep -q '^.*/etc/.lastcall' "$LASTCALL_HOME/handoffs.log"; then bad "handoff outside the project is not logged" "logged"; else ok "handoff outside the project is not logged"; fi

echo "== the site replay shows the hook's real text"
run 9 "$(pre Agent '{"prompt":"x"}')"
reason="$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.permissionDecisionReason | sed -E 's/lastcall\/wip-[0-9]{8}-[0-9]{6}/lastcall\/wip-TS/g')"
site="$(python3 - "$PWD/site/index.html" <<'PY'
import re, sys, html
s = open(sys.argv[1]).read()
m = re.search(r"var HANDOFF = '(.*?)';\n", s)
t = m.group(1).replace("' + TS + '", "TS")
print(html.unescape(t))
PY
)"
expected="Last Call: Battery at 9%. Wrap up now. Subagents and long commands are blocked. ${site//wip-TS/wip-TS}"
[ "$reason" = "$expected" ] && ok "site HANDOFF text matches the hook" || bad "site text drifted" "hook: $reason | site: $expected"

echo "== without jq (plutil parses the event)"
for v in 1; do
  export LASTCALL_NO_JQ=1
  expect_deny    "no jq: Agent blocked at 8%"        "8" "$(pre Agent '{"prompt":"x"}')"
  expect_deny    "no jq: npm install blocked at 8%"  "8" "$(pre Bash '{"command":"npm install"}')"
  expect_allow   "no jq: git commit -m allowed at 5%" "5" "$(pre Bash '{"command":"git commit -m \"Last Call WIP\""}')"
  expect_deny    "no jq: newline bypass denied at 5%" "5" "$(pre Bash '{"command":"git status\nrm -rf x"}')"
  expect_deny    "no jq: injected event name does not skip the check" "5" '{"session_id":"t","cwd":"/tmp/p","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf x \"hook_event_name\":\"UserPromptSubmit\""}}'
  expect_deny    "no jq: injected event name later in the line" "5" '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"x":"\"hook_event_name\":\"UserPromptSubmit\""}'
  expect_allow   "no jq: HANDOFF.md write allowed at 5%" "5" "$(pre Write '{"file_path":"/tmp/p/.lastcall/HANDOFF.md","content":"x"}')"
  expect_context "no jq: prompt context"             "15" "$prompt" "Battery at 15%"
  expect_silent  "no jq: garbage input fails open"   "8" "not json {{{"
  unset LASTCALL_NO_JQ
done
expect_deny    "injected event name with jq"         "5" '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"x":"\"hook_event_name\":\"UserPromptSubmit\""}'

echo "== fails open"
expect_silent "empty stdin"                          "8" ""
expect_silent "garbage stdin"                        "8" "this is not json {{{"
expect_silent "truncated json"                       "8" '{"hook_event_name":"PreToolUse","tool_name":"Age'
expect_silent "unknown event"                        "8" '{"hook_event_name":"Stop"}'
expect_silent "garbage battery value"                "abc" "$(pre Agent '{"prompt":"x"}')"
LASTCALL_HOME=/dev/null/nope run 8 "$prompt"
if [ "$RC" = 0 ]; then ok "unwritable home still exits 0"; else bad "unwritable home" "rc=$RC"; fi
rm -f "$LASTCALL_HOME/lastcall.log"; mkdir "$LASTCALL_HOME/lastcall.log"
expect_deny    "log path that is a directory does not stop the hook" "8" "$(pre Agent '{"prompt":"x"}')"
rmdir "$LASTCALL_HOME/lastcall.log"; : > "$LASTCALL_HOME/lastcall.log"; chmod 000 "$LASTCALL_HOME/lastcall.log"
expect_deny    "unwritable log does not stop the hook" "8" "$(pre Agent '{"prompt":"x"}')"
rm -f "$LASTCALL_HOME/lastcall.log"
run 8 "this is not json {{{"
if [ -z "$OUT" ] && grep -q 'could not parse hook input' "$LASTCALL_HOME/lastcall.log" 2>/dev/null; then ok "bad input fails open and is logged"; else bad "input failure log" "$(cat "$LASTCALL_HOME/lastcall.log" 2>/dev/null)"; fi
if grep -q 'this is not json' "$LASTCALL_HOME/lastcall.log"; then bad "log does not copy the input" "copied"; else ok "log does not copy the input"; fi

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
