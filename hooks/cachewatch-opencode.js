// cachewatch plugin for opencode.
//
// Records, per session, when the last turn ended and what the prompt cache looked like, into
// ~/.local/state/cachewatch/opencode-<session>.json, the same records the Claude Code / Codex
// hook writes and CacheMenuBar reads. Installed by hooks/install.sh into ~/.config/opencode/plugin/.
//
// opencode has no SessionEnd equivalent, so a record disappears when the session is deleted or when
// the six-hour prune in cachewatch-hook removes it. Records are written with an atomic rename; they
// are single-writer per session, so the plugin does not take the shared lock the shell hook uses.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const AGENT = "opencode";
const STATE_DIR =
  process.env.CACHEWATCH_DIR || path.join(os.homedir(), ".local", "state", "cachewatch");
const ID_CHARS = /^[A-Za-z0-9_-]+$/;

const records = new Map(); // sessionID -> record
const usage = new Map(); // sessionID -> { tokens, model, ttl }

function recordPath(sessionID) {
  return path.join(STATE_DIR, `${AGENT}-${sessionID}.json`);
}

function ttlFor(providerID, modelID) {
  const override = process.env.CACHEWATCH_OPENCODE_TTL;
  if (override === "1h" || override === "5m" || override === "openai") return override;
  const provider = String(providerID || "").toLowerCase();
  const model = String(modelID || "").toLowerCase();
  // opencode writes Anthropic cache entries with the provider's default five-minute TTL.
  if (provider.includes("anthropic") || provider.includes("bedrock") || model.includes("claude")) {
    return "5m";
  }
  return "openai";
}

function tokenCount(value) {
  return Number.isInteger(value) && value >= 0 ? value : 0;
}

function write(sessionID, patch) {
  if (typeof sessionID !== "string" || !sessionID || !ID_CHARS.test(sessionID)) return;
  const state = { ...(records.get(sessionID) || {}), ...patch };
  state.agent = AGENT;
  state.session_id = sessionID;
  state.host = os.hostname().split(".")[0];
  state.cwd = state.cwd || "";
  if (!state.title) state.title = path.basename(state.cwd.replace(/\/+$/, "")) || state.cwd;
  if (process.env.HERDR_PANE_ID) state.pane_id = process.env.HERDR_PANE_ID;
  records.set(sessionID, state);
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    const tmp = path.join(STATE_DIR, `.record-${process.pid}-${Date.now()}`);
    fs.writeFileSync(tmp, JSON.stringify(state));
    fs.renameSync(tmp, recordPath(sessionID));
  } catch {
    // A menu-bar reminder is never worth failing a turn over.
  }
}

function remove(sessionID) {
  records.delete(sessionID);
  usage.delete(sessionID);
  try {
    fs.rmSync(recordPath(sessionID), { force: true });
  } catch {}
}

function noteUsage(info) {
  const sessionID = info?.sessionID;
  if (!sessionID || info.role !== "assistant" || !info.tokens) return;
  const cache = info.tokens.cache || {};
  const tokens = tokenCount(cache.read) + tokenCount(cache.write);
  const model = info.model || {};
  const modelID = model.modelID || model.id || "";
  usage.set(sessionID, {
    tokens,
    model: modelID,
    ttl: ttlFor(model.providerID, modelID),
  });
}

function finish(sessionID) {
  if (!sessionID) return;
  const last = usage.get(sessionID);
  if (!last) return; // a session that never ran a turn has no cache to watch
  write(sessionID, {
    active: false,
    at: Math.floor(Date.now() / 1000),
    tokens: last.tokens,
    model: last.model,
    ttl: last.ttl,
  });
}

export const CachewatchPlugin = async ({ directory }) => {
  const cwd = directory || process.cwd();
  return {
    "chat.message": async ({ sessionID }, { parts } = {}) => {
      const text = (parts || [])
        .filter((p) => p?.type === "text" && typeof p.text === "string")
        .map((p) => p.text)
        .join(" ")
        .trim()
        .replace(/\s+/g, " ");
      write(sessionID, {
        cwd,
        active: true,
        prompt_at: Math.floor(Date.now() / 1000),
        ...(text ? { last_prompt: text.slice(0, 80) } : {}),
      });
    },
    event: async ({ event }) => {
      // The event bus emits "message.updated"; the persisted event store versions the same name
      // as "message.updated.1". Accept either spelling.
      const type = String(event?.type || "").replace(/\.\d+$/, "");
      const props = event?.properties || {};
      const sessionID = props.sessionID || props.info?.sessionID || props.info?.id;
      switch (type) {
        case "message.updated":
          noteUsage(props.info);
          break;
        case "session.updated":
          // Only refresh a session already being watched; an idle session list must not
          // create records for sessions that have never run a turn.
          if (props.info?.directory && records.has(sessionID)) {
            write(sessionID, { cwd: props.info.directory });
          }
          break;
        case "session.idle":
          finish(sessionID);
          break;
        case "session.deleted":
          remove(sessionID);
          break;
        default:
          break;
      }
    },
  };
};

// V1 (1.18.29+) calls server(); V2 calls setup(). Both run in the process that sees session events.
export default {
  id: "cachewatch.opencode",
  server: CachewatchPlugin,
  setup() {},
};
