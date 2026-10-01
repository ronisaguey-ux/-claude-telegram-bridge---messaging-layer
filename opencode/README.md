# opencode side of the messaging layer

The Claude half of this repo wakes a **Claude Code** session. This directory is the
equivalent for an **opencode** session: the same three jobs — receive a Telegram
message, append it to an inbox, and wake the session — plus the two things the
opencode API makes possible that the terminal-scraping Claude path cannot do.

Nothing here is specific to one machine. Every path is env-overridable, and no
token is ever stored in a file that is committed.

## Components

| File | What it does |
|---|---|
| `tele_poller.py` | Long-polls the Telegram bot API, appends each message to the inbox (`/tmp/clone_inbox.jsonl` by default), fires the wake, and implements the `/interrupt` urgent channel. |
| `oc_send.js` | Delivers a message into the running opencode session over the HTTP API — the `--async` path that lands mid-turn. |
| `oc_wake_watch.sh` | Watches the inbox and wakes the session on a new line, with a burst cooldown so a batch becomes one wake. |
| `tg_send.sh` | One-argument outbound send. Prints the HTTP status code. |
| `tg_send_checked.sh` | Wrapper over `tg_send.sh` that **reads the response body** and fails loudly. Use this one — see *Why the checked sender* below. |
| `oc_datalake_wake.sh`, `oc_oom_watch.sh`, `oc_calendar_wake.py`, `oc_helpticket_wake.py` | The other watchers: data-lake submissions, memory pressure/OOM, due calendar notes, and new help tickets. Each is a systemd unit in `units/`. |
| `units/` | The systemd user units that run the above, so the bridge survives a reboot instead of dying with the shell that started it. |

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `TELE_BOT_ENV` | `~/telebridge/bot.env` | Where the bot token and chat id are read from. |
| `TELEGRAM_BOT_TOKEN` | — | Read directly if the env file is not used. |
| `TELEGRAM_CHAT_ID` | discovered | Pinned by the env file; otherwise the most recent chat is used. |
| `TELE_INBOX` | `/tmp/clone_inbox.jsonl` | The incoming queue. |
| `OC_WAKE_LOG` | `~/.local/share/opencode/wake_delivery.log` | Delivery log, so a lost wake is visible instead of silent. |

Install the units with `systemctl --user enable --now <name>`, adjusting the paths
inside them for your own checkout.

## Two things worth knowing before you change this

**A status code is not a delivery.** `tg_send.sh` runs curl with `-o /dev/null -w
"%{http_code}"`, so it discards the body — and Telegram answers **HTTP 200 with
`{"ok":false,...}`** for an API-level rejection such as text over 4096 characters.
A failed send and a delivered send are therefore identical at the call site. The
`_checked` wrapper reads the body and prints `DELIVERED chars=N msg_id=<id>` or
`NOT DELIVERED: <description>` and exits non-zero. The same rule applies to the
opencode HTTP API: a `200` on a prompt route does not prove the message was
stored. Verify by reading the session back.

**`/interrupt` ends the running turn, and that requires the v1 abort route.**
`POST /session/{id}/abort` terminates the turn *including a tool that is still
executing*, so a queued message is picked up immediately instead of waiting for a
five-minute command to finish. The v2 `/api/session/{id}/interrupt` route stops
generation but leaves the tool running, which is why an interrupt that used it
still appeared to queue. Measure the effect, never the status code — both routes
return success on paths where nothing happened.

The poller has a `main()` and an `if __name__ == "__main__":` guard on purpose.
It is a daemon: importing it must not start a second copy, or the two processes
fight over `getUpdates` and every poll fails with `409 Conflict`.
