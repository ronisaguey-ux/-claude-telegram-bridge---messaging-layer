#!/usr/bin/env bash
# send-telegram.sh — send a message to the user's chat via the bot.
# Usage: send-telegram.sh "text"   (chat id defaults to the user)
set -euo pipefail
TEXT="${1:?usage: send-telegram.sh \"text\"}"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  if [[ -f "/home/roni/.config/oculus/orchestrator.env" ]]; then
    set -a
    source "/home/roni/.config/oculus/orchestrator.env"
    set +a
  fi
fi

# Fallback defaults if env file was missing or unset
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN env var}"
CHAT_ID="${OCULUS_CHAT_ID:-8932953349}"

# 2026-08-20: --max-time 20 — a hung curl (flaky VPN, no timeout before)
# wedged the outbox relay in do_wait indefinitely, stalling the report lane.
curl -s --max-time 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" \
  --data-urlencode "text=$TEXT" >/dev/null
