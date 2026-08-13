# claude-telegram-bridge

A battle-tested messaging layer that connects a Claude Code session to
Telegram: receive messages, get instant receipts, wake the session when a
message lands, alert the user directly if the session dies, and keep a
heartbeat trail of everything.

Built from a production stack that has been running continuously since
2026-08 — every script in here survived real incidents (session deaths,
out-of-memory crashes, relay races) and was hardened against them.

## Components

| File | What it does |
|---|---|
| `telegram-monitor/` | Claude Code **plugin scaffold** (`.claude-plugin/`) with background monitors + a security-hardened auth layer and integrity-gated config |
| `telegram_ack_daemon.py` | On every new user message, instantly writes a `📥 #<30 random digits>` receipt to the outbox — the user always sees the bridge is alive |
| `inbox_wake.py` | Lightweight wake: when a new message lands, types `check inbox` into the always-on Claude session's terminal |
| `inbox_monitor.py` | Watches the inbox, flags the session, sends rate-limited Telegram acks, and alerts if the relay (outbox → Telegram) is down |
| `claude_deadman.sh` | Last-resort watchdog: if no Claude session processes the messages, it pings the user **directly** (bypassing the relay) and auto-relaunches the session |
| `session_heartbeat.sh` | Appends one JSON line per session activity to `claude_heartbeat.jsonl` — a live trail of what every session did |

## How the pieces fit

```
Telegram ──(bot API long-poll)──▶ claude_inbox.json ──▶ monitor/wake/ack daemons
                                     ▲                          │
claude_deadman.sh ◀── session alive? │                          ▼
  (direct alert if dead)             │              Claude session (reads inbox)
                                     │                          │
Telegram ◀──(relay: outbox 200 OK)───┴── claude_outbox.json ◀───┘
```

- **Inbox** (`claude_inbox.json`): the bot appends every incoming message.
- **Outbox** (`claude_outbox.json`): Claude writes replies; a relay claims
  the file (atomic rename → `.pending`), sends via the bot API, and deletes
  only after a 200 OK. A drained outbox = delivered.
- **Relay-claim semantics** are crash-safe: a process that dies between
  claim and send leaves the `.pending` file for the next relay to recover —
  no message is ever dropped (fixed 2026-08-11 after a real loss).

## Setup

1. Create a bot with [@BotFather](https://t.me/BotFather), get the token.
2. Point a long-polling client (e.g. the
   [Claude Code Telegram plugin](https://github.com/kgantsov/claude-code-telegram)
   or the `telegram-monitor` scaffold here) at `claude_inbox.json`.
3. Configure the environment (see below), then start the pieces:

```bash
python3 telegram_ack_daemon.py &   # instant 📥 receipts
python3 inbox_wake.py &            # wake the session on new messages
python3 inbox_monitor.py &         # inbox watch + relay health alerts
./claude_deadman.sh &              # direct alert + auto-relaunch if session dies
./session_heartbeat.sh &           # live activity trail
```

## Environment

| Variable | Used by | Description |
|---|---|---|
| `AUDITS_PLANS_DIR` | all | Directory holding the `claude_*_inbox/outbox.json` files (default `~/.claude/channels/telegram`) |
| `TELEGRAM_BOT_TOKEN` | monitor, deadman, inbox_monitor | Bot token (kept in an env file, never in the repo) |
| `TELEGRAM_CHAT_ID` | monitor, deadman, inbox_monitor | Chat id messages are sent to |
| `TELEGRAM_ALLOWED_USER_IDS` | plugin `auth.py` | Comma-separated user ids allowed to command the bot (empty = anyone) |
| `PLUGIN_DIR` | deadman, tmux watchers | Where this repo lives (for `--plugin-dir` relaunch) |
| `TMUX_SESSION` | deadman, tmux watchers | Session name of the always-on Claude (default `main`) |
| `PYTHON` | watcher scripts | Python interpreter to use (default `python3`) |
| `MONITORS_CONFIG_SHA256` | plugin `config_loader.py` | Integrity gate: sha256 of `monitors.json`; a mismatch fails closed |

## Security notes

- The plugin's `auth.py` validates every incoming message against an
  allow-list; `config_loader.py` fails closed if `monitors.json` is tampered
  with.
- Tokens are read from environment/env-file only — never hardcoded, never
  echoed into logs.
- `claude_deadman.sh` is the only component that talks to the bot API
  directly (so it works with zero Claude processes alive); everything else
  goes through the outbox relay.

## License

MIT
