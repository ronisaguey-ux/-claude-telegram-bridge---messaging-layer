#!/usr/bin/env python3
"""oc_calendar_wake.py — wake the agent when a user's calendar note comes due.

Owner (2026-09-19): *"a callender where u can have agents remind u of certain
stuff on certain days"* — so the reminder is delivered BY THE AGENT, on Telegram,
not by a system notification. That distinction is the whole design, and it is why
this watcher wakes a turn instead of sending a message: the owner's standing rule
is *"i want 0 automated alerts, i want you to personally deliver information when
u deem necessary"*, and a calendar entry the user explicitly asked to be reminded
about is exactly the kind of judgement call the agent should be making.

How "due" is decided
- A row is a candidate when `remind = 1`, `reminded_at IS NULL`, and its
  `entry_date` is today or earlier. Dates are plain `YYYY-MM-DD` strings with no
  timezone, so "today" is the local date — the user wrote a day, not an instant.
- An entry dated in the FUTURE is never delivered early. A missed entry (the box
  was off) still fires on the next run, which is the honest behaviour for a note
  whose whole content is "don't forget this".
- `reminded_at` is stamped after the wake is launched so the same note is not
  announced on every poll. It is stamped on the row, not kept in a local file,
  because the calendar is the record — a local watermark would drift from it.

Why direct SQLite rather than the API
- `GET /api/calendar/upcoming` is the authenticated read view an agent uses
  inside a turn. This process has no session, and the read is one indexed scan;
  sqlite3 with `busy_timeout` against the WAL database is the same access the
  other watchers use. The single UPDATE is the only write.
"""
from __future__ import annotations

import json
import os
import subprocess
import sqlite3
import sys
import time
from datetime import date, datetime
from pathlib import Path

DB = os.environ.get(
    "OC_CALENDAR_DB",
    "/home/roni/Roni_workspace/helpotron/data/db/helpotron.db",
)
MARKER = Path(
    os.path.expanduser("~/.local/share/opencode/calendar_wake.last")
)
INBOX = os.environ.get("OC_INBOX", "/tmp/clone_inbox.jsonl")
COOLDOWN_SEC = float(os.environ.get("OC_CALENDAR_COOLDOWN", "300"))
POLL_SEC = float(os.environ.get("OC_CALENDAR_POLL", "60"))

SEND = os.environ.get(
    "OC_CALENDAR_SEND", os.path.expanduser("~/.local/lib/ocbridge/oc_send.js")
)
BUN = os.environ.get("OC_CALENDAR_BUN", os.path.expanduser("~/.local/bin/bun"))


def log(msg: str) -> None:
    print(f"oc_calendar_wake: {msg}", flush=True)


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB, timeout=30.0)
    conn.execute("PRAGMA busy_timeout=30000")
    return conn


def fetch_due() -> list[tuple]:
    """Due reminders, oldest first. `date('now','localtime')` matches how the user
    reads the calendar; an entry is due from its own day onward."""
    conn = connect()
    try:
        rows = conn.execute(
            """
            SELECT c.id, c.entry_date, c.title, c.description, u.public_id
              FROM calendar_entries c
              JOIN users u ON u.id = c.user_id
             WHERE c.remind = 1
               AND c.reminded_at IS NULL
               AND date(c.entry_date) <= date('now', 'localtime')
             ORDER BY c.entry_date ASC, c.id ASC
             LIMIT 25
            """
        ).fetchall()
        return rows
    finally:
        conn.close()


def stamp(ids: list[int]) -> None:
    if not ids:
        return
    conn = connect()
    try:
        now = datetime.now().isoformat(timespec="seconds")
        conn.executemany(
            "UPDATE calendar_entries SET reminded_at = ? WHERE id = ? AND reminded_at IS NULL",
            [(now, i) for i in ids],
        )
        conn.commit()
    finally:
        conn.close()


def build_wake(rows: list[tuple]) -> str:
    first = rows[0]
    head = (
        f"📅 CALENDAR REMINDER for {first[4]} — {first[1]}: {str(first[2])[:80]}"
        f" | deliver this reminder to the owner on Telegram in plain English, "
        f"including the note's own wording"
    )
    if len(rows) > 1:
        head += f" (+{len(rows) - 1} more due today)"
    return head


def wake(text: str) -> None:
    """Start a real run and return at once.

    --async maps to session.promptAsync, which starts the run and returns as soon
    as it is ACCEPTED. It replaces the previous detached
    `setsid timeout 1800 ...` call, which also worked but held a process for up to
    30 minutes per wake and left no failure signal. Calling it inline is safe now
    precisely because promptAsync does not block.
    """
    subprocess.Popen(
        [BUN, SEND, text, "--async"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def append_inbox(rows: list[tuple]) -> None:
    try:
        with open(INBOX, "a", encoding="utf-8") as fh:
            for r in rows:
                fh.write(
                    json.dumps(
                        {
                            "source": "calendar",
                            "kind": "calendar_reminder",
                            "title": f"CALENDAR {r[1]} for {r[4]}: {str(r[2])[:120]}",
                            "ts": str(r[1]),
                        }
                    )
                    + "\n"
                )
    except Exception as exc:  # the wake still fires; the inbox is a record
        log(f"inbox append failed: {type(exc).__name__}")


def main() -> int:
    log(f"watching {DB} (poll {POLL_SEC:g}s, cooldown {COOLDOWN_SEC:g}s)")
    while True:
        time.sleep(POLL_SEC)
        try:
            rows = fetch_due()
        except Exception as exc:
            log(f"poll failed: {type(exc).__name__}: {exc}")
            continue
        if not rows:
            continue

        # Collapse a burst into one wake, but never DROP a reminder: nothing is
        # stamped while we are in cooldown, so a suppressed batch is re-evaluated
        # on the next poll instead of being consumed silently (the HOLD-don't-
        # advance rule learned from the telegram watcher).
        now = time.time()
        try:
            last_sent = float(MARKER.read_text().strip())
        except Exception:
            last_sent = 0.0
        if now - last_sent < COOLDOWN_SEC:
            continue

        append_inbox(rows)
        MARKER.parent.mkdir(parents=True, exist_ok=True)
        MARKER.write_text(str(now))
        wake(build_wake(rows))
        ids = [r[0] for r in rows]
        try:
            stamp(ids)
        except Exception as exc:
            # The wake already fired; a failed stamp means a repeat next poll,
            # which is the harmless direction to fail in for a reminder.
            log(f"stamp failed: {type(exc).__name__}: {exc}")
        for r in rows:
            log(f"WOKE reminder #{r[0]} ({r[1]}) {str(r[2])[:50]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
