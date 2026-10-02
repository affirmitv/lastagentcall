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

The installer needs `python3` (it comes with the Xcode Command Line Tools: `xcode-select --install`). When piped through curl, it checks every downloaded file against [`SHA256SUMS`](SHA256SUMS) before installing anything. That catches truncated or mismatched downloads; since the list is served from the same site, compare it with the copy in this repo if you want to check provenance. It:

1. Copies the hook to `~/.lastcall/bin/lastcall-hook.sh` and writes a default `~/.lastcall/config` (kept if you already have one).
2. Backs up `~/.claude/settings.json` to `settings.json.lastcall-backup-<timestamp>`, then merges three hook entries (PreToolUse, PostToolUse, UserPromptSubmit) next to your existing hooks. It never replaces them. Running it twice leaves one copy. The edit is atomic: the new file is written next to the old one, read back, then moved into place. If `settings.json` is not valid JSON, the installer stops before changing anything and says why.
3. If `swiftc` is available (Xcode Command Line Tools), builds the menu bar app from source into `~/Applications/Last Call.app` and opens it. Building locally means no notarization is needed. The hook works without the app.

New Claude Code sessions pick it up right away. Try it without draining anything:

```bash
LASTCALL_FAKE_BATTERY=8 claude
```

## Levels

Only while on battery. Plugged in, or a Mac with no battery: silent, unless you pick **Wrap up all agents now** in the menu bar app.

| Battery | What the agent sees and can do |
|---|---|
| 20% or less | Context on every prompt: finish the current step, do not start long jobs (builds, full test suites, subagent fan-outs). |
| 10% or less | Subagents (`Agent`, `Task`, `Workflow`) and long commands are blocked. The agent is told to write `.lastcall/HANDOFF.md` (what was done, what is in flight, exact next steps, files touched), commit work in progress with `git switch -c lastcall/wip-<timestamp>`, `git add -A`, `git commit -m`, not push, and stop. |
| 5% or less | Every tool is blocked except writing `.lastcall/HANDOFF.md` in the project, `mkdir -p .lastcall`, and a short list of local git commands. Blocking happens in PreToolUse; if the hook cannot parse an event at all, it steps aside rather than guess. |

**Long commands at 10% are matched by name**, so an unusual command can slip through: `npm`/`pnpm`/`yarn`/`bun` install, ci, test, build and run; `bundle install`; `pod install`; `swift build`/`test`; `cargo build`/`test`; `go test`/`build`; `make`; `gradle`/`gradlew`; `mvn`; `docker`/`podman` build and compose; `xcodebuild`; `pytest`; `sleep` over 60 seconds, and a few more. Each part of a chained command is checked, after stripping `env VAR=...`, `VAR=...`, `time`, `nice`, `nohup` and `sh -c`/`bash -c`.

**At 5% the allowlist is exact.** A Bash command runs only if it is one git command with no shell syntax at all (no newline, `;`, `&&`, `||`, `|`, `&`, `>`, `<`, backticks, `$`, parentheses or braces) and no global git options such as `-c` or `-C`. Allowed: `git status`, `diff`, `log`, `rev-parse`, `add`, `commit` with `-m`/`-am`, `stash` (push, save, list, show), `branch` (list or create), and `git switch -c lastcall/wip-*` or `git checkout -b lastcall/wip-*`. Everything else, including `push`, `reset`, `clean`, `rebase`, `merge`, `pull`, `fetch`, `remote`, `config` and `gc`, is refused. Write and Edit are allowed only for `.lastcall/HANDOFF.md` under the session's project directory (no `..`, no symlinked `.lastcall`). Git still runs whatever the repository itself configures, such as commit hooks and filters.

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
- **Wrap up all agents now**: creates `~/.lastcall/override`, which every session treats as the 10% level, plugged in or not, and on Macs with no battery
- **Resume normal**: removes the override
- **Open handoff notes**: recent `.lastcall/HANDOFF.md` files (the hook logs each one to `~/.lastcall/handoffs.log`)
- **Settings**: opens `~/.lastcall/config`
- **Launch at login**: adds or removes a LaunchAgent
- **Quit**

It sends a macOS notification each time the level goes up, and an all clear when it drops back to normal. If a menu action fails, the menu shows what failed and the details go to `~/.lastcall/lastcall.log`. Handoff notes written with a relative path open from the directory the session was in.

## Picking up after

Last Call does not move sessions to another machine. It makes resuming cheap:

- Same Mac: `claude --resume` and pick the session.
- Anywhere: check out the `lastcall/wip-*` branch and start a fresh session with "read .lastcall/HANDOFF.md and continue".

## How it works

`bin/lastcall-hook.sh` is a plain bash script. On each hook event it:

1. Reads `~/.lastcall/config`, the manual override, and the battery from `pmset -g batt` (usually well under 50 ms per event, tested).
2. Exits silently if plugged in, if there is no battery, or if above the warning level, unless the override is on.
3. Otherwise reads the hook JSON from stdin and answers with `hookSpecificOutput`: `additionalContext` for UserPromptSubmit and PostToolUse, and `permissionDecision: "deny"` with a reason for blocked PreToolUse calls.

It always exits 0 and makes no network calls. Reading the battery or the hook input fails open: an unreadable battery or malformed input means no output, so the tool runs as normal, and the failure is written to `~/.lastcall/lastcall.log`. The session id is only used in a file name after it is reduced to `[A-Za-z0-9._-]` (anything else is hashed), and marker files are never written through a symlink.

Test hooks: `LASTCALL_FAKE_BATTERY=8` (on battery at 8%), `LASTCALL_FAKE_BATTERY=8:charging`, `LASTCALL_FAKE_BATTERY=none` (desktop), and `LASTCALL_HOME=/some/dir` instead of `~/.lastcall`.

## Install count

The site shows how many times the installer has run. It is counted on the server, not on your Mac: `install.sh` downloads `bin/lastcall-hook.sh` from lastagentcall.com, and nothing else does, so the site function in `api/hook.js` counts those downloads from curl, at most one per network per UTC day. It stores only a salted hash of the day and the network address, never the address. Installs from a checkout are not counted, and the hook and the app still make no network calls. Counting started on 2026-10-02.

## Tests

```bash
bash tests/test_hook.sh      # every level, the 5% allowlist and bypass attempts, long commands, desktop override, config, session ids, fail open, speed
bash tests/test_install.sh   # install twice, uninstall, other hooks untouched, broken settings, checksums
```

## Uninstall

```bash
curl -fsSL https://lastagentcall.com/uninstall.sh | bash
```

Removes the three hook entries (after another backup), the app, its LaunchAgent, and `~/.lastcall`. Your other settings and any `HANDOFF.md` files in your projects stay. If `settings.json` cannot be edited, it is left as it was, `~/.lastcall` is kept so the hook entries still point at a real file, and the uninstaller says what to remove by hand.

## Changes

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT. Made by Affirmi.
