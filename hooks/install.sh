#!/bin/sh
# Installs cachewatch-hook into ~/.local/bin and registers it (idempotently) in
#   ~/.claude/settings.json   (Claude Code)   UserPromptSubmit, Stop, SessionEnd
#   ~/.codex/hooks.json       (Codex CLI)     UserPromptSubmit, Stop, SessionEnd
# and installs the opencode plugin into ~/.config/opencode/plugin/cachewatch.js.
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
        timeout = 3 if agent == "codex" and ev == "SessionEnd" else 5
        existing = [h for g in groups for h in g.get("hooks", [])
                    if shlex.split(h.get("command", "")) == [home + "/.local/bin/cachewatch-hook", agent]]
        if existing:
            for h in existing:
                if agent == "codex" and ev == "SessionEnd" and h.get("timeout") != timeout:
                    h["timeout"] = timeout; changed = True
            continue
        groups.append({"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}); changed = True
    if changed:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        json.dump(cfg, open(path, "w"), indent=2); open(path, "a").write("\n")
    print(f"{'updated' if changed else 'already registered'} {path}")
register(os.path.join(home, ".claude", "settings.json"), "claude", create=True)
register(os.path.join(os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"), "hooks.json"), "codex", create=True)
PY
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugin"
mkdir -p "$plugin_dir"
cp "$here/cachewatch-opencode.js" "$plugin_dir/cachewatch.js"
echo "installed $plugin_dir/cachewatch.js"

python3 "$here/configure-codex.py"
echo "installed $HOME/.local/bin/cachewatch-hook; state dir: ~/.local/state/cachewatch"
