#!/usr/bin/env python3
"""
Telegram 30-Digit Ack Daemon
============================
User feature (2026-08-08): "as soon as I send a message, send a quick 30 digit
randomized number sequence, and make sure its different everytime I send a
message, so whenever I do I can see that its alive and ur actually gonna
respond". Every NEW user message in claude_inbox.json gets an instant
"📥 #<30 random digits>" ack written to claude_outbox.json; the orchestrator's
background outbox-relay delivers it to Telegram within ~2s.

Replaces the old legacy-telebot ack that died when the orchestrator became
SEND-ONLY (bun plugin owns getUpdates now). ts-tracked like the responder
(ring-buffer rewrite safe — see telegram-outbox-relay-works memory).

Usage:
  nohup python3 scripts/telegram_ack_daemon.py > /tmp/ack_daemon.log 2>&1 &
"""
import json, os, random, sys, time, logging
from datetime import datetime

INBOX_PATH = os.getenv("AUDITS_PLANS_DIR",
                       os.path.join(os.path.expanduser("~"), ".claude", "channels", "telegram"))
INBOX_FILE = os.path.join(INBOX_PATH, "claude_inbox.json")
OUTBOX_FILE = os.path.join(INBOX_PATH, "claude_outbox.json")
STATE_FILE = os.path.join(INBOX_PATH, ".ack_daemon_state.json")
LOG_FILE = os.path.join(INBOX_PATH, "ack_daemon.log")
POLL_INTERVAL = 1

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s',
                    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)])
log = logging.getLogger("ack_daemon")


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return []


def save_json(path, data):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    except Exception as e:
        log.error(f"Failed to write {path}: {e}")


def main():
    log.info("=== Telegram 30-Digit Ack Daemon starting ===")
    log.info(f"Inbox: {INBOX_FILE} | Outbox: {OUTBOX_FILE}")
    state = load_json(STATE_FILE)
    last_ts = state.get("last_seen_ts", "") if isinstance(state, dict) else ""
    if not last_ts:
        # Fresh start: baseline to the newest entry already in the inbox so we
        # never ack the existing ring-buffer backlog (500 entries = spam).
        last_ts = max(((m.get("ts") or "") for m in load_json(INBOX_FILE)), default="")
        log.info(f"Fresh start, baseline last_ts={last_ts}")

    while True:
        try:
            inbox = load_json(INBOX_FILE)
            if not inbox:
                time.sleep(POLL_INTERVAL)
                continue
            new_msgs = [m for m in inbox if (m.get("ts") or "") > last_ts]
            for msg in new_msgs:
                # Ack ONLY real user messages: relayed entries carry
                # from=="telegram"; skip our own direct:true forwards and
                # monitor-script notes.
                if msg.get("from") != "telegram":
                    continue
                if msg.get("direct"):
                    continue
                text = (msg.get("text") or "").strip()
                if not text:
                    continue
                rid = ''.join(str(random.randint(0, 9)) for _ in range(30))
                outbox = load_json(OUTBOX_FILE)
                outbox.append({"ts": datetime.now().isoformat(), "from": "claude",
                               "text": f"📥 #{rid}"})
                outbox = outbox[-200:]  # 2026-08-20 (audit 7.7): ring-buffer cap — prune old delivered turns
                save_json(OUTBOX_FILE, outbox)
                log.info(f"ACK {rid[:10]}... -> {text[:60]}")
            if new_msgs:
                last_ts = max((m.get("ts") or "") for m in new_msgs)
                save_json(STATE_FILE, {"last_seen_ts": last_ts})
        except Exception as e:
            log.error(f"Loop error: {e}")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
