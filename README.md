# CacheMenuBar

A small native macOS menu-bar app that watches the prompt caches of your Claude Code and Codex CLI sessions, on this
Mac and on remote hosts, and reminds you before they expire with a soft chime and a notification. Continue the session
while the cache is still warm and the next turn costs a cache read instead of a fresh write.

## How it gets its data

`hooks/cachewatch-hook` is a Claude Code / Codex hook (UserPromptSubmit, Stop, SessionEnd). On every Stop it records,
per session, when the turn ended and what the prompt cache looked like, read from the transcript's last assistant
message: the TTL (1h if the last write was a 1h write, else 5m) and the cached prefix size. The record lands in
`~/.local/state/cachewatch/<agent>-<session>.json`, alongside the working directory, the model, the last prompt and the
herdr pane id when the session runs inside herdr. SessionEnd removes it, and records older than six hours are pruned.

The app reads that directory locally every ten seconds and, for each configured remote host, runs `ssh <host>` to read
the same directory there. Your `~/.ssh/config` applies, so ControlMaster keeps it cheap.

The local chat app is a third source. Its `GET /api/sessions` list carries each session's cache state and keep-warm
state, so chat sessions show up next to the CLI ones. Their submenu opens the session in the browser, toggles the
server's keep-warm pings, or fires one ping now. Sessions the server is keeping warm are not reminded about. Clear the
chat URL in Settings to drop that source.

## Install the hook

Locally:

```sh
sh hooks/install.sh
```

On a remote host, from this directory:

```sh
ssh ampere 'mkdir -p ~/tmp/cw && cat > ~/tmp/cw/cachewatch-hook' < hooks/cachewatch-hook
ssh ampere 'cat > ~/tmp/cw/install.sh' < hooks/install.sh
ssh ampere 'sh ~/tmp/cw/install.sh'
```

The installer copies the hook to `~/.local/bin/cachewatch-hook` and registers it, idempotently, in
`~/.claude/settings.json` and `~/.codex/hooks.json` next to whatever hooks are already there. It needs only `sh` and
`python3`. Hooks take effect for new agent sessions.

## What the app shows

- **Menu bar**: a countdown for the soonest-expiring live cache, orange under three minutes and red under one, with a
  `+N` for other live sessions. When nothing is live but sessions are mid-turn, it shows how many are working.
- **Menu**: live caches, sessions working right now, then recently expired ones, each with time left, cached tokens and
  where it runs. A session's submenu shows agent, model and TTL, the working directory, the last prompt, when the turn
  ended, and the cost of the next turn: a cache read while live, a fresh write once expired. Local sessions can be
  focused in herdr; remote ones tell you which host to attach to.

## Reminder schedule

Reminders fire at fixed minute offsets counted from the end of the last turn, and reset whenever the session runs
another turn:

| Cache | Reminders at minute |
|---|---|
| Claude Code, 1h TTL | 13, 28, 43, 58 |
| Claude Code, 5m TTL | 1, 3 |
| Codex or chat app on OpenAI (automatic cache, assumed 30 minutes) | 8, 18, 28 |

A final notice fires when the cache has expired, with the estimated cost of resuming. Sessions that are mid-turn are not
reminded about. Marks that came due while the app or a host was unreachable are skipped, not backfilled.

Two chimes: a rising C5 to G5 for a reminder, a falling G5, C5, G4 for an expiry. Both are quiet sine tones synthesised
in memory. "Test chimes" in the menu plays them in order.

## Build and run

```sh
./build.sh          # needs the Xcode Command Line Tools
open CacheMenuBar.app
```

Allow notifications when macOS asks. **Settings…** holds the chat app URL (default `http://localhost:8787`), the remote host list (default `ampere`), the chime,
notification and launch-at-login switches, and the assumed OpenAI cache lifetime. `build.sh` also writes
`CacheMenuBar.zip` with a universal binary for another Mac; unzip, right-click the app and choose **Open** once, because
this personal build is not notarized.
