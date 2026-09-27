# Last Call

Your Claude Code agents get a last call before the battery dies.

Last Call is a free, open source Claude Code hook for macOS. When your laptop runs low, every agent session is told to finish its step, write a handoff note, commit its work to a local branch, and stop. Blocking is enforced by the hook; the wrap-up is guidance the agent follows. When the screen goes black, the record of what each agent was doing is already saved.

Site: https://lastagentcall.com

## Install

```bash
curl -fsSL https://lastagentcall.com/install.sh | bash
```

Or from a checkout:

```bash
git clone https://github.com/affirmitv/lastagentcall && cd lastagentcall && ./install.sh
```

The installer:

1. Copies the hook to `~/.lastcall/bin/lastcall-hook.sh` and writes a default `~/.lastcall/config` (kept if you already have one).
2. Backs up `~/.claude/settings.json` to `settings.json.lastcall-backup-<timestamp>`, then merges three hook entries (PreToolUse, PostToolUse, UserPromptSubmit) next to your existing hooks. It never replaces them. Running it twice leaves one copy.
3. If `swiftc` is available (Xcode Command Line Tools), builds the menu bar app from source into `~/Applications/Last Call.app` and opens it. Building locally means no notarization is needed. The hook works without the app.

New Claude Code sessions pick it up right away. Try it without draining anything:

```bash
LASTCALL_FAKE_BATTERY=8 claude
```

## Levels

Only while on battery. Plugged in, or a Mac with no battery: silent.

| Battery | What the agent sees and can do |
|---|---|
| 20% or less | Context on every prompt: finish the current step, do not start long jobs (builds, full test suites, subagent fan-outs). |
| 10% or less | Subagents (`Agent`, `Task`, `Workflow`) and long commands (`xcodebuild`, `gradle`, `docker build`, `npm test`, `pytest`, `cargo build` and friends) are blocked. The agent is told to write `.lastcall/HANDOFF.md` (what was done, what is in flight, exact next steps, files touched), commit work in progress with `git switch -c lastcall/wip-<timestamp> && git add -A && git commit`, not push, and stop. |
| 5% or less | Every tool is blocked except writing `.lastcall/HANDOFF.md` and plain `git` commands. |

Change the thresholds in `~/.lastcall/config`:

```
WARN_AT=20
WRAP_AT=10
STOP_AT=5
ENABLED=1
```

The file is parsed as `KEY=number` lines, never executed. `ENABLED=0` turns the hook off without uninstalling.

## Menu bar app

Shows `LC` with the battery percent and level. The menu has:

- battery, number of running `claude` processes, current level
- **Wrap up all agents now**: creates `~/.lastcall/override`, which every session treats as the 10% level, plugged in or not
- **Resume normal**: removes the override
- **Open handoff notes**: recent `.lastcall/HANDOFF.md` files (the hook logs each one to `~/.lastcall/handoffs.log`)
- **Settings**: opens `~/.lastcall/config`
- **Launch at login**: adds or removes a LaunchAgent
- **Quit**

It sends a macOS notification each time the level goes up, and an all clear when it drops back to normal.

## Picking up after

Last Call does not move sessions to another machine. It makes resuming cheap:

- Same Mac: `claude --resume` and pick the session.
- Anywhere: check out the `lastcall/wip-*` branch and start a fresh session with "read .lastcall/HANDOFF.md and continue".

## How it works

`bin/lastcall-hook.sh` is a plain bash script. On each hook event it:

1. Reads `~/.lastcall/config` and the battery from `pmset -g batt` (about 10 ms).
2. Exits silently if plugged in, if there is no battery, or if above the warning level.
3. Otherwise reads the hook JSON from stdin and answers with `hookSpecificOutput`: `additionalContext` for UserPromptSubmit and PostToolUse, and `permissionDecision: "deny"` with a reason for blocked PreToolUse calls.

It always exits 0, makes no network calls, and fails open: malformed input, a missing battery, or any error means no output, so the tool runs as normal.

Test hooks: `LASTCALL_FAKE_BATTERY=8` (on battery at 8%), `LASTCALL_FAKE_BATTERY=8:charging`, `LASTCALL_FAKE_BATTERY=none` (desktop), and `LASTCALL_HOME=/some/dir` instead of `~/.lastcall`.

## Tests

```bash
bash tests/test_hook.sh      # every level, plugged in, desktop, override, config, fail open, speed
bash tests/test_install.sh   # install twice, uninstall, other hooks untouched (python3 and jq paths)
```

## Uninstall

```bash
curl -fsSL https://lastagentcall.com/uninstall.sh | bash
```

Removes the three hook entries (after another backup), the app, its LaunchAgent, and `~/.lastcall`. Your other settings and any `HANDOFF.md` files in your projects stay.

## License

MIT. Made by Affirmi.
