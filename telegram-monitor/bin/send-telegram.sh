#!/usr/bin/env bash
# send-telegram.sh — send a message to the user's chat via the bot.
# Usage: send-telegram.sh "text"   (chat id defaults to the user)
set -euo pipefail
TEXT="${1:?usage: send-telegram.sh \"text\"}"
CHAT_ID="${CLAUDE_CHAT_ID:-${TELEGRAM_CHAT_ID}}"
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "TELEGRAM_BOT_TOKEN not set" >&2
  exit 1
fi
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" -d text="$TEXT" >/dev/null
