#!/usr/bin/env python3
"""Add or remove the Last Call hook in a Claude Code settings.json.

usage: settings.py install|uninstall|check <settings.json> [hook command]

"check" validates the file and changes nothing.
Leaves every other setting and hook exactly as it was. Idempotent.
A symlinked settings.json (dotfiles) is edited at its target.
Atomic and fail safe: the new file is written next to the old one, read back
and checked, then moved into place. On any error the original is untouched,
a message goes to stderr, and the exit code is non-zero.
"""
import json, os, sys, tempfile

EVENTS = ["PreToolUse", "PostToolUse", "UserPromptSubmit"]
# The command install.sh adds for this user: the quoted path to the hook.
def our_command():
    return '"%s"' % os.path.join(os.path.expanduser("~"), ".lastcall", "bin", "lastcall-hook.sh")


class Refuse(Exception):
    pass


def is_ours(hook):
    """True only for the exact command install.sh adds for this user
    ("$HOME/.lastcall/bin/lastcall-hook.sh", quoted or not)."""
    if not isinstance(hook, dict):
        return False
    cmd = str(hook.get("command", "")).strip()
    ours = our_command()
    return cmd == ours or cmd == ours[1:-1]


def update(data, mode, cmd):
    if not isinstance(data, dict):
        raise Refuse("settings.json is not a JSON object")
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        raise Refuse("settings.json 'hooks' is not an object")
    for ev in EVENTS:
        current = hooks.get(ev, [])
        if current is None:
            current = []
        if not isinstance(current, list):
            raise Refuse("settings.json 'hooks.%s' is not a list" % ev)
        groups = []
        for g in current:
            if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                kept = [h for h in g["hooks"] if not is_ours(h)]
                if not kept:
                    continue
                if len(kept) != len(g["hooks"]):
                    g = dict(g, hooks=kept)
            groups.append(g)
        if mode == "install":
            group = {"hooks": [{"type": "command", "command": cmd, "timeout": 5}]}
            if ev != "UserPromptSubmit":
                group = {"matcher": "*", **group}
            groups.append(group)
        if groups:
            hooks[ev] = groups
        else:
            hooks.pop(ev, None)
    if hooks:
        data["hooks"] = hooks
    else:
        data.pop("hooks", None)
    return data


def main(argv):
    if len(argv) < 3 or argv[1] not in ("install", "uninstall", "check"):
        raise Refuse("usage: settings.py install|uninstall|check <settings.json> [hook command]")
    mode, path = argv[1], argv[2]
    cmd = argv[3] if len(argv) > 3 else ""
    if mode == "install" and not cmd:
        raise Refuse("install needs the hook command")
    path = os.path.realpath(path)

    data = {}
    if os.path.exists(path) and os.path.getsize(path) > 0:
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (ValueError, UnicodeDecodeError) as e:
            raise Refuse("%s is not valid JSON (%s)" % (path, e))
    data = update(data, "uninstall" if mode == "check" else mode, cmd)
    d = os.path.dirname(os.path.abspath(path))
    if mode == "check":
        # The real write needs a new file in this directory, then a rename.
        probe = d
        while not os.path.isdir(probe):
            probe = os.path.dirname(probe)
        if not os.access(probe, os.W_OK | os.X_OK):
            raise Refuse("cannot write in %s" % probe)
        return

    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        with open(tmp, encoding="utf-8") as f:
            if json.load(f) != data:
                raise Refuse("the new settings did not read back the same")
        if os.path.exists(path):
            os.chmod(tmp, os.stat(path).st_mode & 0o777)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Refuse as e:
        sys.stderr.write("Last Call: %s. Nothing was changed.\n" % e)
        sys.exit(2)
    except OSError as e:
        sys.stderr.write("Last Call: could not write settings (%s). Nothing was changed.\n" % e)
        sys.exit(2)
