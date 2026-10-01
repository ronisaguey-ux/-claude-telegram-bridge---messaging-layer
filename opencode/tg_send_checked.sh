#!/usr/bin/env bash
# Send to Bob's Telegram and report what TELEGRAM said, not what curl's exit status said.
#
# WHY THIS EXISTS: the stock tg_send.sh runs curl with `-o /dev/null -w "%{http_code}"`, so
# it prints 200 and throws the response body away. Telegram answers HTTP 200 with
# `{"ok":false,"description":"..."}` for API-level rejections — text too long, empty text,
# bad chat id. So a failed send and a delivered send are indistinguishable at the call site,
# which is exactly how an agent convinces itself it replied when nobody received anything.
#
# Usage: tg_send_checked.sh "message"        (or  tg_send_checked.sh --file path)
set -euo pipefail
BRIDGE=/home/roni/Roni_workspace/telebridge
set -a; [ -f "$BRIDGE/bot.env" ] && . "$BRIDGE/bot.env"; set +a
: "${TELEGRAM_BOT_TOKEN:?bot.env missing TELEGRAM_BOT_TOKEN}"

if [ "${1:-}" = "--file" ]; then
  : "${2:?--file needs a path}"
  BODY="$2"
  CHARS=$(wc -c < "$2" | tr -d ' ')
  # Telegram's hard cap is 4096 UTF-8 characters for a text message. Failing loudly here
  # is better than a silent partial delivery.
  if [ "$CHARS" -gt 4096 ]; then
    echo "REFUSED: $CHARS chars exceeds the 4096 limit — split it"; exit 2
  fi
  RESP=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID:-8932953349}" \
      --data-urlencode "text@$BODY")
else
  : "${1:?message required}"
  RESP=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID:-8932953349}" \
      --data-urlencode "text=$1")
fi

python3 - "$RESP" <<'PY'
import json, sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(raw)
except Exception:
    print(f"BAD RESPONSE (no JSON): {raw[:200]}"); raise SystemExit(1)
if not d.get("ok"):
    print(f"NOT DELIVERED: {d.get('error_code')} {d.get('description')}")
    raise SystemExit(1)
r = d["result"]
# The count Telegram actually accepted. A partial delivery would show up here.
print(f"DELIVERED chars={len(r.get('text',''))} msg_id={r.get('message_id')}")
PY
