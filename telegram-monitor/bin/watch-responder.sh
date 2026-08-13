#!/usr/bin/env bash
# watch-responder.sh — emit one stdout line per telegram_auto_responder activity.
#
# The auto-responder daemon (scripts/telegram_auto_responder.py) replies to
# casual (non-command, non-direct) Telegram messages via DeepSeek and logs to
# audits_plans/auto_responder.log. This monitor tails that log so the monitor
# session sees each reply (and each escalation/error) as a notification.
#
# Contract: one line per new event; `tail -n 0` so historical log lines are
# never re-emitted.
LOG="${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/auto_responder.log"
[[ -f "$LOG" ]] || touch "$LOG"
tail -n 0 -F "$LOG" | grep -E --line-buffered "REPLY|-> ok|ESCALATED|ERROR|Loop error"
