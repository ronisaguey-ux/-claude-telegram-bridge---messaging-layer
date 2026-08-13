#!/usr/bin/env bash
# watch-inbox-persistent.sh — persistent inbox watcher for the always-on session.
#
# Emits exactly one "[telegram] ..." line per NEW message in claude_inbox.json
# (delivered to Claude as a notification → wakes an idle session).
#
# Design (2026-08-04, from wake-on-inbox.sh lessons):
# - Tracks `seen` IN MEMORY so it never re-emits a message twice while running.
# - Does NOT advance /tmp/telegram_monitor_offset — the SESSION advances the
#   offset after replying. If this watcher dies and restarts, it re-reads the
#   offset file and re-emits anything beyond it (never loses mid-turn arrivals).

INBOX="${WAKE_INBOX:-${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/claude_inbox.json}"
OFFSET="${WAKE_OFFSET:-/tmp/telegram_monitor_offset}"

seen=$(cat "$OFFSET" 2>/dev/null || echo 0)

while true; do
  total=$(jq 'length' "$INBOX" 2>/dev/null || echo 0)
  if (( total > seen )); then
    jq -r --argjson off "$seen" \
      '.[$off:] | .[] | "[telegram] " + .from + ": " + (((.text // "") | gsub("[\r\n]+"; " ")))' \
      "$INBOX" 2>/dev/null
    seen=$total
  fi
  sleep 2
done
