#!/usr/bin/env bun
// oc_send.js — inject/trigger a message into the main opencode session via the serve API.
// usage: oc_send.js <text> [--session <id>] [--no-reply] [--async] [--steer]
//   without --session: openbot's owned session wins; see the resolution order below.
//   --no-reply: adds the message without triggering an assistant run.
//   --async:    adds the message AND starts a run, returning immediately.
import { createOpencodeClient } from "@opencode-ai/sdk";

const args = process.argv.slice(2);
const text = args.filter(a => !a.startsWith("--")).join(" ");
let id = null, noReply = false, asyncMode = false, steerMode = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--session" && args[i + 1]) id = args[i + 1];
  if (args[i] === "--no-reply") noReply = true;
  if (args[i] === "--async") asyncMode = true;
  if (args[i] === "--steer") steerMode = true;
}
if (!text) { console.error("usage: oc_send.js <text> [--session <id>] [--no-reply] [--async] [--steer]"); process.exit(1); }

const client = createOpencodeClient({ baseUrl: "http://127.0.0.1:4096" });

if (!id) {
  // Session resolution, in order of confidence. Each step was added because the
  // one before it failed in the field; the comments say how.
  //
  //  0. openbot's owned session — openbot (~/.local/bin/openbot) records the id
  //     it created in $XDG_STATE_HOME/opencode/openbot_session. It is the
  //     launcher, so this is the system's own answer to "which session is
  //     current". Added 2026-09-10: after `openbot new`, a wake arriving with no
  //     TUI attached fell through to "newest by time_updated" and could land on
  //     the old session openbot had just walked away from — resurrecting
  //     exactly the context it fled.
  //  1. if openbot's owned session is live, it wins outright — attached or not.
  //     openbot (~/.local/bin/openbot) is the launcher, so the session it last
  //     adopted IS "the current session"; the marker outranks what happens to be
  //     attached. Added 2026-09-10: before this, a live attach on ANY other
  //     session outranked the owned one, and because stale TUIs outlive their
  //     windows (four were parked on an abandoned session when this was fixed)
  //     a wake could still land on a session openbot had already walked away
  //     from. Observed in the field: with the marker on a fresh session, this
  //     still resolved to the old attached one.
  //  2. otherwise a live `opencode attach` client (parsed from the process
  //     table), newest first. Added 2026-09-09 because "newest by time_updated"
  //     let an idle session bumped by unrelated activity steal the wake, so
  //     Bob's message landed somewhere nobody was looking.
  //  3. otherwise newest non-archived by time_updated.
  //
  // Plain live-attach used to be resolved with Array.find over an unordered API
  // list, so with several attachments it picked whichever row came back first —
  // which is how the wake kept landing on a poisoned session after `openbot
  // new`. Every branch below is now explicitly ordered, never list-dependent.
  let owned = "";
  try {
    const { readFileSync } = await import("node:fs");
    const { homedir } = await import("node:os");
    const { join } = await import("node:path");
    const stateDir = process.env.XDG_STATE_HOME || join(homedir(), ".local", "state");
    owned = readFileSync(join(stateDir, "opencode", "openbot_session"), "utf8").trim();
  } catch (_) { /* no marker yet -> steps 1 and 2 still apply */ }

  let attachIds = [];
  try {
    const { execSync } = await import("node:child_process");
    const out = execSync("pgrep -af 'opencode attach'", { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    attachIds = [...new Set(out.split("\n").map(l => l.match(/\-s ([A-Za-z0-9_]+)/)?.[1]).filter(Boolean))];
  } catch (_) { /* no attach procs -> steps 0 and 2 still apply */ }

  try {
    const res = await client.session.list();
    const list = Array.isArray(res) ? res : (res?.data ?? []);
    const live = list.filter(s => !s?.time_archived);
    const attached = live.filter(s => attachIds.includes(s.id));
    const newest = arr => arr.slice().sort((a, b) => (b?.time_updated || 0) - (a?.time_updated || 0));

    const ownedLive = owned && live.some(s => s.id === owned);
    if (ownedLive) {
      id = owned;
      console.error(attached.some(s => s.id === owned)
        ? "resolved openbot-owned session (attached)" : "resolved openbot-owned session", id);
    } else if (attached.length) {
      id = newest(attached)[0]?.id ?? null;
      if (id) console.error("resolved live-attach session", id);
    } else {
      id = newest(live)[0]?.id ?? list[0]?.id ?? null;
    }
  } catch (e) { console.error("session.list failed:", e?.message ?? e); process.exit(2); }
  if (!id) { console.error("no opencode session found (serve running?)"); process.exit(3); }
}

// --dry-run: resolve the session and print it WITHOUT sending (used for test).
if (process.argv.includes("--dry-run")) {
  console.log("dry-run target session:", id);
  process.exit(0);
}

// Three delivery modes, and the difference between them is the whole reason this
// file has a history:
//
//   --no-reply  `{ noReply: true }` — appends the message and starts NO run. It
//               returns instantly, which is why the wake watcher was switched to it
//               on 2026-09-18 (a blocking prompt parked the watcher for the whole
//               assistant run). But an appended message on an IDLE session is inert:
//               nothing processes it until something else starts a turn. Measured
//               2026-09-23 — wakes at 17:00:21 and 18:33:20 both appeared in the
//               session as user messages with NO assistant reply after either; the
//               next reply came only when the owner typed. That is the bug this flag
//               combination caused.
//
//   --async     `promptAsync` → POST /session/{id}/prompt_async, documented as
//               "Create and send a new message to a session, start if needed and
//               return immediately". Starts the run AND returns at once, so it is
//               the mode a wake actually needs: it does not park the caller and it
//               does not leave the message inert.
//
//   default     synchronous `prompt` — starts the run and waits for it to finish.
//               Correct for a caller that wants the answer; wrong for a watcher.
const body = noReply ? { noReply: true, parts: [{ type: "text", text }] } : { parts: [{ type: "text", text }] };

// --steer: deliver INTO the running turn instead of waiting for it to end.
//
// The v1 routes have no way to do this. The v2 prompt endpoint carries an explicit
// `delivery` field: "steer" injects immediately, "queue" waits for the next turn
// boundary. Discovered by reading the SDK's generated types, not by guessing:
//   url: "/api/session/{sessionID}/prompt"  body: { prompt, delivery?: "steer"|"queue" }
//
// Measured 2026-09-29: a steer POST returned 200 with an admittedSeq WHILE a turn
// was in flight, and the injected text was readable inside that same turn. A wake
// that lands mid-turn is the difference between an owner waiting an hour for a
// reply and hearing back in seconds.
if (steerMode) {
  const res = await fetch(`http://127.0.0.1:4096/api/session/${id}/prompt`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ prompt: { text }, delivery: "steer" }),
  });
  const txt = await res.text();
  if (!res.ok) {
    console.error("steer failed:", res.status, txt.slice(0, 200));
    process.exit(5);
  }
  console.log("steered into session", id, "(delivery=steer)");
} else try {
  if (asyncMode) {
    await client.session.promptAsync({ path: { id }, body });
    console.log("started run in session", id, "(async)");
  } else {
    const result = await client.session.prompt({ path: { id }, body });
    console.log("delivered to session", id, noReply ? "(no-reply)" : "");
  }
} catch (e) {
  console.error(`${asyncMode ? "session.promptAsync" : "session.prompt"} failed:`, e?.message ?? e);
  process.exit(4);
}
