#!/usr/bin/env bash
# Telegram send (Oculus bot) for the helpotron clone machine.
# Usage: ./tg_send.sh "message text"
# Token comes from bot.env (in this dir) — created by setup from helpotron/.env.
set -euo pipefail
cd "$(dirname "$0")"
set -a; [ -f bot.env ] && . ./bot.env; set +a
: "${TELEGRAM_BOT_TOKEN:?bot.env missing TELEGRAM_BOT_TOKEN — see links.md}"

CHAT_ID="${TELEGRAM_CHAT_ID:-}"
if [ -z "$CHAT_ID" ]; then
  # discover the most recent chat that talked to this bot
  CHAT_ID=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates?limit=10" \
    | sed -n 's/.*"chat":{[^}]*"id":\(-\?[0-9]\+\).*/\1/p' | tail -1)
fi
[ -z "$CHAT_ID" ] && { echo "no chat_id discovered — set TELEGRAM_CHAT_ID in bot.env"; exit 1; }

# operator 08-28: --photo <path> [caption] sends a PNG/JPG screenshot via sendPhoto
if [ "${1:-}" = "--photo" ]; then
  : "${2:?photo path required}"
  curl -s -o /dev/null -w "%{http_code}\n" \
    "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendPhoto" \
    -F "chat_id=$CHAT_ID" \
    -F "photo=@${2}" \
    ${3:+-F "caption=$3"}
  exit $?
fi

curl -s -o /dev/null -w "%{http_code}\n" \
  "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
  --data-urlencode "chat_id=$CHAT_ID" \
  --data-urlencode "text=${1:?message required}"
