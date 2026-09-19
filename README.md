# CacheMenuBar

A macOS menu-bar app that counts down the prompt cache of every Claude Code, Codex and opencode session you have
running, here and on remote hosts, and chimes before one expires. Reply while the cache is warm and the next turn is a
cache read instead of a fresh write.

```
  ⏱ 12:47 +3
```

## Install

```sh
sh hooks/install.sh     # hooks for Claude Code, Codex and opencode
./build.sh              # needs the Xcode Command Line Tools
cp -R CacheMenuBar.app /Applications/
open /Applications/CacheMenuBar.app
```

The installer needs `sh`, `python3` and Codex on PATH. It registers the hook in `~/.claude/settings.json` and
`$CODEX_HOME/hooks.json`, drops the plugin in `~/.config/opencode/plugin/`, and asks Codex's app-server to trust the
three cachewatch hooks, which registering `hooks.json` alone does not do. Your other hooks are left alone.

Copy the app into `/Applications` before you turn on launch at login, because macOS remembers the path it registered.
Allow notifications when asked. New sessions are picked up automatically; restart opencode and resume any open Codex
session so they load the hook.

For a remote host, copy the hooks over and run the same installer there:

```sh
fleet exec ampere 'mkdir -p ~/tmp/cw'
fleet cp hooks/cachewatch-hook hooks/cachewatch-opencode.js hooks/install.sh hooks/configure-codex.py ampere:~/tmp/cw/
fleet exec ampere 'sh ~/tmp/cw/install.sh'
```

Then add the host in **Settings…**, along with the chat app URL, the chimes and the assumed OpenAI cache lifetime.

## What you see

**Menu bar**: a countdown for the cache that expires first, orange under three minutes, red under one, with `+N` for
the other live sessions. When nothing is live, it shows how many sessions are working.

**Menu**: live caches, then sessions working right now, then recently expired ones, each with time left, cached tokens
and where it runs. Open a session for its model, TTL, working directory, last prompt and the cost of its next turn.
Local sessions can be focused in herdr; remote ones name the host to attach to.

## Reminders

Reminders count from the end of the last turn and reset on the next one. Sessions that are mid-turn stay quiet, and a
final notice fires when the cache lapses.

| Session | Reminders at minute |
|---|---|
| Claude Code on a subscription (1h cache) | 13, 28, 43, 58 |
| Claude Code on an API key, opencode on Anthropic (5m cache) | 1, 3 |
| Codex, opencode elsewhere, chat app (OpenAI, assumed 30m) | 8, 18, 28 |

## How it works

The hooks write one small JSON file per session into `~/.local/state/cachewatch/`, with the cache size, the TTL, the
model, the working directory and the last prompt. The app reads that directory every ten seconds, and every thirty
seconds reads the same directory on each remote host over `ssh`. A third source is the local chat app, whose
`GET /api/sessions` reports cache and keep-warm state; clear its URL in Settings to drop it.

Where the numbers come from:

- **Claude Code** writes 5-minute cache entries on an API key and 1-hour entries on a subscription, so the TTL doubles
  as the auth mode and the menu says `5m ttl, api` or `1h ttl, subscription`.
- **Codex** usage comes from the last `token_count.info.last_token_usage` event in the rollout, not the session total.
  OpenAI's cache lifetime is an estimate, so its reminders are too.
- **opencode** reports `tokens.cache.read` and `tokens.cache.write` per message, and `session.idle` ends the turn.
  Anthropic models get the 5-minute TTL and everything else the OpenAI estimate. Override with
  `CACHEWATCH_OPENCODE_TTL=1h|5m|openai`.

Records are removed when the session ends and pruned after six hours. A host that goes unreachable keeps its last
snapshot on screen but stops producing reminders, and reminders it missed are dropped rather than fired late.

## Files

| Path | What it is |
|---|---|
| `main.swift`, `Runtime.swift` | the app |
| `hooks/cachewatch-hook` | Claude Code and Codex hook (POSIX sh + python3) |
| `hooks/cachewatch-opencode.js` | opencode plugin |
| `hooks/install.sh` | installs and registers all three, idempotently |
| `tests/` | `python3 -m unittest discover -s tests -v` |

`build.sh` also writes `CacheMenuBar.zip` with a universal binary. This build is not notarized, so on another Mac
right-click the app and choose **Open** the first time.
