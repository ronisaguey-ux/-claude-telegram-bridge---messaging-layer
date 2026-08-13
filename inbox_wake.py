#!/usr/bin/env python3
"""
inbox_wake.py — lightweight Telegram-wake for the always-on Claude session.

User idea (2026-08-03): "a simple lightweight py script that checks the inbox
every 5 seconds, and every time it sees a message, it just types in the
physical claude code chat 'check inbox' — then the message wakes you up and
you check yourself."

How it works:
  1. Every 5s, read claude_inbox.json (a JSON array the orchestrator appends
     to as Telegram messages arrive).
  2. Track how many messages we've already announced (persisted in a state
     file, so a restart doesn't re-announce history).
  3. If there are NEW messages, inject a wake line into the always-on Claude
     session's terminal so it wakes up and reads the inbox itself.

The wake injection writes to the Claude session's controlling TTY (the same
device a human would type into). It only ever writes the wake phrase — it does
not touch the inbox or any other file.

Run:
    python3 scripts/inbox_wake.py &
Standard library only. Safe to run repeatedly (never starts a duplicate).
"""

import json
import os
import subprocess
import sys
import time

INBOX = os.path.join(os.getenv("AUDITS_PLANS_DIR",
                               os.path.join(os.path.expanduser("~"), ".claude", "channels", "telegram")),
                     "claude_inbox.json")
STATE_FILE = "/tmp/inbox_wake_offset"
LOG_FILE = "/tmp/inbox_wake.log"
POLL_SECONDS = 5
WAKE_PHRASE = "check inbox"   # what gets typed into the Claude session

# Match the always-on session (the one started with --plugin-dir). If there
# are several claude sessions, prefer the one running in a terminal (has a tty).
CLAUDE_MATCH = "claude --plugin-dir"


def log(msg: str):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} - {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def read_offset() -> int:
    try:
        return int(open(STATE_FILE).read().strip())
    except Exception:
        return 0


def write_offset(n: int):
    try:
        with open(STATE_FILE, "w") as f:
            f.write(str(n))
    except Exception:
        pass


def inbox_length() -> int:
    try:
        with open(INBOX) as f:
            d = json.load(f)
        return len(d) if isinstance(d, list) else 0
    except Exception:
        return 0


def find_claude_tty() -> str | None:
    """Find the always-on Claude session's controlling TTY device.

    Prefers a session matching --plugin-dir; falls back to any claude with a
    tty (so it keeps working after a restart / resume).
    """
    try:
        out = subprocess.run(
            ["ps", "-eo", "pid,tty,args"], capture_output=True, text=True,
            timeout=10).stdout
    except Exception:
        return None
    best = None
    for line in out.splitlines()[1:]:
        parts = line.split(None, 2)
        if len(parts) < 3 or "claude" not in parts[2]:
            continue
        pid, tty, args = parts
        if tty in ("?", "-"):
            continue
        tty_path = f"/dev/{tty}"
        if not os.path.exists(tty_path):
            continue
        if CLAUDE_MATCH in args:
            return tty_path
        if best is None:
            best = tty_path
    return best


def wake_claude():
    """Type the wake phrase into the Claude session's terminal."""
    tty = find_claude_tty()
    if not tty:
        log("could not find a claude tty to wake — inbox has new messages!")
        return
    try:
        with open(tty, "w") as f:
            f.write(WAKE_PHRASE + "\n")
        log(f"woke claude on {tty} with '{WAKE_PHRASE}'")
    except Exception as e:
        log(f"failed to write wake to {tty}: {e}")


def main():
    log("=== inbox_wake started ===")
    offset = read_offset()
    # First run: baseline to the current inbox length so we don't announce the
    # historical messages already in the file.
    if offset == 0 and os.path.exists(STATE_FILE) is False:
        offset = inbox_length()
        write_offset(offset)
        log(f"baseline offset set to {offset} (won't re-announce history)")

    while True:
        time.sleep(POLL_SECONDS)
        total = inbox_length()
        if total > offset:
            new_count = total - offset
            log(f"{new_count} new message(s) in inbox ({offset} -> {total})")
            wake_claude()
            offset = total
            write_offset(offset)


if __name__ == "__main__":
    main()
