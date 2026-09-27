#!/usr/bin/env python3
"""Add or remove the Last Call hook in a Claude Code settings.json.

usage: settings.py install|uninstall <settings.json> <hook command>
Leaves every other setting and hook exactly as it was. Idempotent.
"""
import json, os, sys, tempfile

EVENTS = ["PreToolUse", "PostToolUse", "UserPromptSubmit"]
MARK = "lastcall-hook.sh"

def main():
    mode, path, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
    data = {}
    if os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path) as f:
            data = json.load(f)
    if not isinstance(data, dict):
        sys.exit("settings.json is not a JSON object; not touching it")
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        sys.exit("settings.json 'hooks' is not an object; not touching it")
    for ev in EVENTS:
        groups = []
        for g in hooks.get(ev, []) or []:
            if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                kept = [h for h in g["hooks"] if MARK not in str((h or {}).get("command", ""))]
                if not kept:
                    continue
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
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    if os.path.exists(path):
        os.chmod(tmp, os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)

if __name__ == "__main__":
    main()
