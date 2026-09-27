# Changelog

## 0.2

Tighter 5% mode, desktop override, safer install.

- 5% mode: Bash runs only a single plain local git command (status, diff, log, rev-parse, add, commit -m, stash, branch, switch -c lastcall/wip-*). Newlines, chaining, pipes, redirects, substitution, `-c` overrides, push, reset, clean, rebase, merge, pull, fetch, remote, config and gc are refused. Write and Edit are allowed only for `.lastcall/HANDOFF.md` in the project.
- 10% mode: long commands are matched in more forms (installs, package scripts, pod, bundle, swift, cargo, go, make, gradle, mvn, docker and podman, xcodebuild, pytest, long sleeps), including behind `env`, `time`, `nice` and `sh -c`. Still name based.
- Wrap up all agents now works on Macs with no battery.
- Session ids are sanitized before use in a file name; marker files are never written through a symlink.
- The config file's last line is read even without a trailing newline.
- Battery and input read failures are logged to `~/.lastcall/lastcall.log`.
- Menu bar app: failed actions show in the menu and the log; relative handoff paths open from the session's directory.
- Installer: settings edits are atomic and checked; a broken `settings.json` stops the install before anything changes. One settings helper for install and uninstall. Downloads are verified against `SHA256SUMS`.
- Uninstall keeps `~/.lastcall` if it cannot remove the hook entries, so settings never point at a missing file.

## 0.1

First release: Claude Code hook, menu bar app, installer.
