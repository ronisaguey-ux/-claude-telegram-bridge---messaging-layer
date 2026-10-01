#!/usr/bin/env python3
"""oc_helpticket_wake.py — wake the agent when a help ticket arrives.

The "Ask the Developer" ticket is public BY NECESSITY: it exists for people who
cannot log in, so it cannot require a login. That makes this monitor the only
thing standing between a stranded user and silence.

Flow (owner directive 2026-09-18): a ticket wakes the agent, the agent
investigates the report and forwards its own assessment to the owner on Telegram
for a decision. Nothing is auto-actioned from a ticket — the owner decides the
course of action, and a ticket is by definition an unverified claim from someone
who could not prove who they are.

Deliberately its own monitor with its own state: the datalake watcher is a
different monitor for a different signal, and the owner has already said not to
blend the two (a QUIET datalake line was firing on every Telegram message).

Read-only against the prod DB. One ticket row is never delivered twice.
"""
from __future__ import annotations

import json
import os
import subprocess
import sqlite3
import sys
import time
from pathlib import Path

DB = os.environ.get(
    "OC_HELPTICKET_DB",
    "/home/roni/Roni_workspace/helpotron/data/db/helpotron.db",
)
STATE = Path(
    os.environ.get(
        "OC_HELPTICKET_STATE",
        os.path.expanduser("~/.local/share/opencode/helpticket_wake.last_id"),
    )
)
COOLDOWN_FILE = Path(
    os.path.expanduser("~/.local/share/opencode/helpticket_wake.last")
)
INBOX = os.environ.get("OC_INBOX", "/tmp/clone_inbox.jsonl")
COOLDOWN_SEC = float(os.environ.get("OC_HELPTICKET_COOLDOWN", "60"))
POLL_SEC = float(os.environ.get("OC_HELPTICKET_POLL", "5"))

SEND = os.environ.get("OC_HELPTICKET_SEND", os.path.expanduser("~/.local/lib/ocbridge/oc_send.js"))
BUN = os.environ.get("OC_HELPTICKET_BUN", os.path.expanduser("~/.local/bin/bun"))


def log(msg: str) -> None:
    print(f"oc_helpticket_wake: {msg}", flush=True)


def read_state() -> int | None:
    try:
        return int(STATE.read_text().strip())
    except Exception:
        return None


def write_state(value: int) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(str(value))
    tmp.replace(STATE)


def fetch_new(last_id: int | None) -> tuple[int | None, list[tuple]]:
    """Return (newest_id, rows with id > last_id).

    last_id None means first run: baseline on the current max and deliver
    nothing, so enabling this monitor never replays historical tickets as
    if they had just arrived.
    """
    if not Path(DB).exists():
        return last_id, []
    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=10)
    try:
        newest = conn.execute("SELECT COALESCE(MAX(id), 0) FROM admin_messages").fetchone()[0]
        if last_id is None:
            return newest, []
        rows = conn.execute(
            "SELECT id, user_id, subject, category, message, created_at "
            "FROM admin_messages WHERE id > ? ORDER BY id",
            (last_id,),
        ).fetchall()
        return newest, rows
    finally:
        conn.close()


def detect_rewind(newest: int, last_id: int | None) -> bool:
    """True when the id high-water mark no longer means what we think it means.

    `admin_messages.id` is a plain INTEGER PRIMARY KEY — NOT AUTOINCREMENT — so
    SQLite hands out `max(rowid) + 1` and deleting rows REWINDS the sequence. An
    admin can delete tickets (there is a delete route and a clear-all route), and
    after a clear the next ticket is id 1 again.

    Against a stale high-water mark of, say, 2, that ticket is `id > 2` == false
    and is NEVER DELIVERED. Silent loss of exactly the signal this monitor exists
    to carry — and the same failure shape as false negatives elsewhere in this
    file. Measured 2026-09-18: cleaning probe rows left the table empty with the
    watermark at 2, so the very next real ticket would have been dropped.

    The asymmetry decides the response: a watermark that is too LOW re-delivers a
    ticket (harmless — the agent just triages it twice), while a watermark that is
    too HIGH loses one outright. So a detected rewind resets to zero and lets the
    next poll re-evaluate everything present.
    """
    if last_id is None:
        return False
    return newest < last_id


def sender_of(user_id: str) -> str:
    """Tickets arrive as `unverified:<typed id>`; show what the sender claimed."""
    uid = (user_id or "").strip()
    if uid.startswith("unverified:"):
        return uid.split(":", 1)[1] or "unknown"
    return uid or "unknown"


def build_wake(rows: list[tuple]) -> str:
    first = rows[0]
    head = (
        f"🎫 HELP TICKET #{first[0]} from {sender_of(first[1])} "
        f"[{first[3]}] — {str(first[2])[:80]} | triage, investigate, "
        f"then send your assessment to the owner on Telegram for the course of action"
    )
    if len(rows) > 1:
        head += f" (+{len(rows) - 1} more)"
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
                            "source": "helpticket",
                            "kind": "help_ticket",
                            "title": f"HELP TICKET #{r[0]} from {sender_of(r[1])}: {str(r[2])[:120]}",
                            "ts": str(r[5]),
                        }
                    )
                    + "\n"
                )
    except Exception as exc:  # the wake still fires; the inbox is a record
        log(f"inbox append failed: {type(exc).__name__}")


def main() -> int:
    log(f"watching {DB}")
    last = read_state()
    while True:
        time.sleep(POLL_SEC)
        try:
            newest, rows = fetch_new(last)
        except Exception as exc:
            log(f"poll failed: {type(exc).__name__}: {exc}")
            continue
        if last is None:
            last = newest
            write_state(last)
            log(f"baselined at ticket id {last}")
            continue

        # A shrunk id space means the watermark is meaningless — see
        # detect_rewind(). Correct it and re-read BEFORE the emptiness check, so
        # a rewound ticket is delivered on this poll rather than the next one.
        if detect_rewind(newest, last):
            log(f"id rewind detected (max {newest} < watermark {last}) — resetting watermark")
            last = 0
            write_state(last)
            try:
                newest, rows = fetch_new(last)
            except Exception as exc:
                log(f"re-read after rewind failed: {type(exc).__name__}")
                continue

        if not rows:
            continue

        # Collapse a burst into one wake, but never DROP a ticket. The state is
        # only advanced after delivery, so a suppressed batch is re-evaluated on
        # the next poll instead of being consumed silently — the bug that lost
        # inbox lines 106/107 in the telegram watcher (fixed 2026-09-18: HOLD,
        # do not advance).
        now = time.time()
        try:
            last_sent = float(COOLDOWN_FILE.read_text().strip())
        except Exception:
            last_sent = 0.0
        if now - last_sent < COOLDOWN_SEC:
            continue

        append_inbox(rows)
        COOLDOWN_FILE.parent.mkdir(parents=True, exist_ok=True)
        COOLDOWN_FILE.write_text(str(now))
        wake(build_wake(rows))
        for r in rows:
            log(f"WOKE ticket #{r[0]} from {sender_of(r[1])}")
        last = max(r[0] for r in rows)
        write_state(last)
    return 0


if __name__ == "__main__":
    sys.exit(main())
