#!/bin/sh
# Installs cachewatch-hook into ~/.local/bin and registers it (idempotently) in
#   ~/.claude/settings.json   (Claude Code)   UserPromptSubmit, Stop, SessionEnd
#   ~/.codex/hooks.json       (Codex CLI)     UserPromptSubmit, Stop, SessionEnd
# Run on any host where agents run: locally, or piped over ssh (see README).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.local/bin"
cp "$here/cachewatch-hook" "$HOME/.local/bin/cachewatch-hook"
chmod +x "$HOME/.local/bin/cachewatch-hook"
python3 - "$HOME" <<'PY'
import json, os, sys, shlex
home = sys.argv[1]
def register(path, agent, create):
    if os.path.exists(path):
        cfg = json.load(open(path))
    elif create:
        cfg = {}
    else:
        print(f"skip {path} (not present)"); return
    hooks = cfg.setdefault("hooks", {})
    cmd = f"{shlex.quote(home + '/.local/bin/cachewatch-hook')} {agent}"
    changed = False
    for ev in ("UserPromptSubmit", "Stop", "SessionEnd"):
        groups = hooks.setdefault(ev, [])
        if any("cachewatch-hook" in h.get("command", "") for g in groups for h in g.get("hooks", [])):
            continue
        groups.append({"hooks": [{"type": "command", "command": cmd, "timeout": 5}]}); changed = True
    if changed:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        json.dump(cfg, open(path, "w"), indent=2); open(path, "a").write("\n")
    print(f"{'updated' if changed else 'already registered'} {path}")
register(os.path.join(home, ".claude", "settings.json"), "claude", create=True)
register(os.path.join(os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"), "hooks.json"), "codex", create=True)
PY
python3 "$here/configure-codex.py"
echo "installed $HOME/.local/bin/cachewatch-hook; state dir: ~/.local/state/cachewatch"
