#!/usr/bin/env bash
# wake-on-inbox.sh — asyncRewake Stop hook: wakes an idle Claude session the
# moment a new Telegram message lands in claude_inbox.json.
#
# Spawned async by the Stop hook (asyncRewake:true). Single instance via
# flock — if a watcher is already waiting, a new one exits immediately.
#
# IMPORTANT (2026-08-04): do NOT advance the offset past existing messages on
# start. Messages can arrive while the session is mid-turn (busy) and the MCP
# channel may NOT deliver them — skipping them loses messages permanently.
# Instead: emit ANY messages beyond the offset immediately (covers mid-turn
# arrivals missed earlier) and exit 2 to wake the session.
#
# The SESSION updates the offset after replying. So no message is ever lost:
# if a wake fires while busy, the messages stay beyond the offset and the next
# watcher start re-emits them.
#
# 2026-08-12 FIX: offset file is in /tmp — wiped at every boot, so after a
# reboot offset=0 and EVERY Stop-hook wake re-dumped the whole inbox history
# (the "spam" the user saw: 152 messages re-emitted per wake). Initialize the
# offset to the CURRENT inbox length on first run, exactly like the ts-based
# siblings (telegram-inbox-watch.sh / watch-inbox.sh): the wake hook's job is
# to nudge an idle session, message CONTENT is delivered by those ts-watchers,
# so replaying history here is pure spam. Also clamp length < offset (buffer
# truncation) so the hook never goes blind after the inbox shrinks.

INBOX="${WAKE_INBOX:-${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/claude_inbox.json}"
OFFSET="${WAKE_OFFSET:-/tmp/telegram_monitor_offset}"
LOCK="/tmp/telegram_wake.lock"

exec 9>"$LOCK"
flock -n 9 || exit 0   # another watcher is already waiting

# First run after a boot: /tmp is empty — start at the CURRENT length so we
# never replay history, only future messages (2026-08-12, post-reboot spam).
if [[ ! -f "$OFFSET" ]]; then
  length0=$(jq 'length' "$INBOX" 2>/dev/null || echo 0)
  echo "$length0" > "$OFFSET"
fi

while true; do
  length=$(jq 'length' "$INBOX" 2>/dev/null || echo 0)
  offset=$(cat "$OFFSET" 2>/dev/null || echo 0)
  if (( length < offset )); then
    echo "$length" > "$OFFSET"   # buffer truncated — follow it, don't go blind
    offset=$length
  fi
  if (( length > offset )); then
    jq -r --argjson off "$offset" \
      '.[$off:] | .[] | "[telegram] " + .from + ": " + (((.text // "") | gsub("[\r\n]+"; " ")))' \
      "$INBOX" 2>/dev/null
    exit 2
  fi
  sleep 2
done
