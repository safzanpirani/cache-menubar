# CacheMenuBar

A small native macOS menu-bar app that watches the prompt caches of your Claude Code and Codex CLI sessions, on this
Mac and on remote hosts, and reminds you before they expire with a soft chime and a notification. Continue the session
while the cache is still warm and the next turn costs a cache read instead of a fresh write.

## How it gets its data

`hooks/cachewatch-hook` is a Claude Code / Codex hook (UserPromptSubmit, Stop, SessionEnd). On every Stop it records,
per session, when the turn ended and what the prompt cache looked like, read from the transcript: the cached prefix
size from the last usage block, and the TTL from the last turn that wrote to the cache. Claude Code writes 5-minute
entries when it runs on an API key and 1-hour entries on a subscription, so the TTL also tells the app which auth mode
the session is using, and it shows `5m ttl, api` or `1h ttl, subscription`. A session resumed under the other login
switches on its next turn. No configuration is needed. The record lands in
`~/.local/state/cachewatch/<agent>-<session>.json`, alongside the working directory, the model, the last prompt and the
herdr pane id when the session runs inside herdr. SessionEnd removes it, and records older than six hours are pruned.

The app reads that directory locally every ten seconds and, every thirty seconds, runs `ssh <host>` for each
configured remote host to read the same directory there. Your `~/.ssh/config` applies; with ControlMaster on, each poll
is one channel on the existing connection, about 20 ms and a few kilobytes.

Remote polls drain stdout and stderr while SSH runs, with a ten-second deadline
and an 8 MiB limit per stream. A failed source keeps its last displayed snapshot
but does not emit cache reminders. Changing source settings invalidates pending
responses, and Refresh includes remote hosts immediately.

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
fleet exec ampere 'mkdir -p ~/tmp/cw'
fleet cp hooks/cachewatch-hook hooks/install.sh hooks/configure-codex.py ampere:~/tmp/cw/
fleet exec ampere 'sh ~/tmp/cw/install.sh'
```

The installer copies the hook to `~/.local/bin/cachewatch-hook` and registers it, idempotently, in
`~/.claude/settings.json` and `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`) next to existing hooks.
It needs `sh`, `python3`, and Codex on PATH. The installer uses Codex's app-server API to enable the hooks feature
and enable and trust only the three cachewatch hooks. Existing unrelated hooks and their settings are preserved.
Registering `hooks.json` alone is insufficient when Codex has disabled a hook or has not trusted its definition.

Hooks take effect for new agent sessions. Exit and resume existing Codex sessions after installation, including
sessions inside herdr on each host. Restarting CacheMenuBar is unnecessary. A session appears on its next prompt;
its cache countdown begins when the turn finishes. SessionEnd removes its record.

Codex cache usage comes from the latest `token_count.info.last_token_usage` event in its rollout, not cumulative
session usage. The model comes from the hook payload or rollout. OpenAI cache lifetime remains an estimate.

Run the regression checks with `python3 -m unittest discover -s tests -v`.
On macOS with Swift tools, this also exercises process deadlines, large pipe
output, literal arguments, and poll ownership. Hook tests use temporary state
and transcripts; they do not configure live agents. Hook updates use a shared
lock and atomic private record files so concurrent events cannot collide.

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
cp -R CacheMenuBar.app /Applications/
open /Applications/CacheMenuBar.app
```

Install it into `/Applications` before enabling the login item: macOS remembers the path it registered, and a rebuild
in place breaks it. Launch at login is a checkbox in Settings, or from the shell:

```sh
/Applications/CacheMenuBar.app/Contents/MacOS/CacheMenuBar --register-login    # --unregister-login to undo
```

Allow notifications when macOS asks. **Settings…** holds the chat app URL (default `http://localhost:8787`), the remote host list (default `ampere`), the chime,
notification and launch-at-login switches, and the assumed OpenAI cache lifetime. `build.sh` also writes
`CacheMenuBar.zip` with a universal binary for another Mac; unzip, right-click the app and choose **Open** once, because
this personal build is not notarized.
