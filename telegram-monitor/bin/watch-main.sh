#!/usr/bin/env bash
# watch-main.sh — emit one stdout line per NEW message from the MAIN session
# (claude_monitor_inbox.json), waking the monitor session when main writes.
INBOX="${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/claude_monitor_inbox.json"
STATE="/tmp/telegram_monitor_main_offset"
if [[ ! -f "$STATE" ]]; then echo "$(jq 'length' "$INBOX" 2>/dev/null || echo 0)" > "$STATE"; fi
while true; do
  if [[ -f "$INBOX" ]]; then
    total=$(jq 'length' "$INBOX" 2>/dev/null || echo 0)
    offset=$(cat "$STATE" 2>/dev/null || echo 0)
    if (( total > offset )); then
      jq -r --argjson off "$offset" '.[$off:][] | "[main] " + (.text | gsub("[\r\n]+"; " "))' "$INBOX" 2>/dev/null
      echo "$total" > "$STATE"
    fi
  fi
  sleep 2
done
