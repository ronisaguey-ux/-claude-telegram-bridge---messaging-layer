#!/usr/bin/env python3
"""Inbox monitor — makes sure every Telegram message to the Claude bot gets
handled.

User rule (2026-08-03): "1 monitor checking the inbox so u always respond to me."

What it does:
  - Polls claude_inbox.json every 3s for NEW messages (by ts+text signature).
  - On a new message:
      * Logs it to /tmp/inbox_monitor.log
      * Writes /tmp/claude_inbox_new.flag with the message so the Claude
        session can pick it up and reply (Claude clears the flag after replying).
      * Sends a rate-limited Telegram ack so the user knows it was received.
  - Verifies the orchestrator (which runs the outbox relay) is alive. If it's
    down, alerts — because a dead relay means replies never reach Telegram.

Run: python3 scripts/inbox_monitor.py &   (or via start_orchestrator.sh)
"""

import json
import os
import subprocess
import time
import urllib.request

AUDITS_DIR = os.getenv("AUDITS_PLANS_DIR",
                       os.path.join(os.path.expanduser("~"), ".claude", "channels", "telegram"))
INBOX = os.path.join(AUDITS_DIR, "claude_inbox.json")
ENV_FILE = os.getenv("ORCHESTRATOR_ENV",
                     os.path.join(os.path.expanduser("~"), ".config", "claude", "orchestrator.env"))
CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")
LOG_FILE = "/tmp/inbox_monitor.log"
FLAG_FILE = "/tmp/claude_inbox_new.flag"
POLL_SECONDS = 3
ACK_INTERVAL = 60   # don't ack more than once per minute
SEEN_FILE = "/tmp/inbox_monitor.seen"   # persisted last-seen signature


def log(msg: str):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} - {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def get_token() -> str:
    """Read TELEGRAM_BOT_TOKEN from the orchestrator .env without printing it."""
    try:
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if line.startswith("TELEGRAM_BOT_TOKEN="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return ""


SETTINGS_FILE = os.path.join(AUDITS_DIR, "workflow_settings.json")


def notifications_enabled() -> bool:
    """Respect the orchestrator's notifications setting (user: little to no
    automated junk — only the main session texts, plus deadman emergencies)."""
    try:
        with open(SETTINGS_FILE) as f:
            return json.load(f).get("notifications", "on") != "off"
    except Exception:
        return True  # fail open to alerting on a missing settings file


def send_telegram(text: str):
    if not notifications_enabled():
        log(f"suppressed by notifications=off: {text[:80]}")
        return
    token = get_token()
    if not token:
        log("no bot token available for Telegram alert")
        return
    if not CHAT_ID:
        log("no TELEGRAM_CHAT_ID set — skipping alert")
        return
    try:
        data = urllib.parse.urlencode(
            {"chat_id": CHAT_ID, "text": text}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{token}/sendMessage", data=data)
        with urllib.request.urlopen(req, timeout=10) as r:
            if r.status != 200:
                log(f"telegram ack failed: HTTP {r.status}")
    except Exception as e:
        log(f"telegram ack error: {e}")


def read_inbox() -> list:
    try:
        with open(INBOX) as f:
            d = json.load(f)
        if isinstance(d, list):
            return d
    except Exception:
        pass
    return []


def signature(m: dict) -> str:
    return f"{m.get('ts')}|{str(m.get('text'))[:80]}"


def orchestrator_alive() -> bool:
    try:
        out = subprocess.run(
            ["ps", "-eo", "args"], capture_output=True, text=True, timeout=10).stdout
        return "run_workflow.py" in out
    except Exception:
        return True  # can't check -> assume fine (don't alarm)


def load_seen() -> list:
    try:
        with open(SEEN_FILE) as f:
            return json.load(f)
    except Exception:
        return []


def save_seen(seen: list):
    try:
        with open(SEEN_FILE, "w") as f:
            json.dump(seen[-200:], f)
    except Exception:
        pass


def main():
    log("=== inbox monitor started ===")
    seen = load_seen()
    last_ack = 0.0
    relay_warned = False

    while True:
        time.sleep(POLL_SECONDS)
        msgs = read_inbox()
        if not msgs:
            continue

        new = [m for m in msgs if signature(m) not in seen]
        if new:
            seen.extend(signature(m) for m in new)
            save_seen(seen)
            for m in new[-5:]:  # cap the log to avoid spam on bulk
                log(f"NEW from {m.get('from')}: {str(m.get('text'))[:160]}")
            # Flag for the Claude session to pick up and reply to
            try:
                with open(FLAG_FILE, "w") as f:
                    json.dump({"count": len(new),
                               "newest": new[-1]}, f)
                log(f"wrote {FLAG_FILE} ({len(new)} new message(s))")
            except Exception as e:
                log(f"could not write flag file: {e}")
            # Rate-limited Telegram ack so the user knows it landed
            now = time.time()
            if now - last_ack >= ACK_INTERVAL:
                last_ack = now
                send_telegram(f"📥 {len(new)} message(s) received — Claude has been alerted.")

        # Relay health: if the orchestrator (which runs the outbox relay) is
        # dead, replies can't reach Telegram. Warn once per outage.
        if not orchestrator_alive():
            if not relay_warned:
                log("WARNING: orchestrator (outbox relay) is DOWN — replies won't be delivered")
                send_telegram("⚠️ Relay is down — the orchestrator isn't running. Replies won't reach you until it's back.")
                relay_warned = True
        else:
            relay_warned = False


if __name__ == "__main__":
    main()
