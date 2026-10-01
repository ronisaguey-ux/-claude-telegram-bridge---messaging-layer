#!/usr/bin/env bash
# oc_wake_watch.sh — Telegram wake: when a new Bob line whose text starts with
# "/main" lands in /tmp/clone_inbox.jsonl, inject "Bob: <text with /main
# stripped>" into the main opencode session (via oc_send.js → opencode serve)
# so the agent picks the task up immediately. GATE 2026-09-07: lines whose
# text does not start with "/main" are logged ("gated (no /main)") and advance
# the pointer WITHOUT waking. Add --daemon to self-background (nohup).
set -u
INBOX="${OC_INBOX:-/tmp/clone_inbox.jsonl}"
# Overridable so the hold/cooldown logic can be tested against a scratch inbox
# and pointer instead of the live ones. Same pattern as INBOX above.
STATE="${OC_WAKE_STATE:-/tmp/oc_wake_line.no}"
# Delivery log. Silent loss was the 2026-09-18 failure: the watcher advanced its
# pointer past three of the owner's messages and wrote nothing anywhere.
STATE_LOG="$HOME/.local/share/opencode/wake_delivery.log"
GATE="$HOME/.local/bin/tele_inbox_gate.py"   # shared /main gate (2026-09-07)
PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

if [ "${1:-}" = "--daemon" ]; then
  [ -f "/tmp/oc_wake_daemon.pid" ] && [ -d "/proc/$(cat /tmp/oc_wake_daemon.pid 2>/dev/null)" ] && { echo "already daemonized"; exit 0; }
  nohup "$0" >>"$HOME/.local/share/opencode/wake.log" 2>&1 &
  echo $! > /tmp/oc_wake_daemon.pid
  echo "oc_wake_watch: daemon pid $!"
  exit 0
fi

[ -f "$STATE" ] || echo 0 > "$STATE"
LAST=$(cat "$STATE")
# Single-instance guard: only one watcher may run the loop at a time. Without
# it, a second concurrent copy (or a systemd restart overlap) would each see
# the same new line and re-deliver it -> duplicate-Bob spam. Fixed 2026-09-07
# after a run where one "Hello" reached the session 18+ times.
# Single-instance lock. The path was hardcoded, which made the script impossible
# to run against a scratch inbox at all: the live watcher always held the lock, so
# every isolation test exited with "another instance holds the lock" and the only
# way to exercise the delivery path was to stop the real watcher. That is how two
# delivery bugs (blocking prompt, then inert --no-reply) both reached production
# untested. Overridable now, same pattern as OC_INBOX / OC_WAKE_STATE.
LOCK="${OC_WAKE_LOCK:-$HOME/.local/share/opencode/wake.lock}"
exec 9>"$LOCK"
flock -n 9 || { echo "oc_wake_watch: another instance holds the lock, exiting"; exit 0; }
# Burst collapse: if a wake was delivered recently, keep consuming new lines
# (advancing the pointer) SILENTLY for COOLDOWN_SEC and only re-wake after it
# elapses. A multi-line Bob burst then yields ONE ping instead of one per line.
COOLDOWN_SEC="${OC_WAKE_COOLDOWN:-300}"
# Also overridable, for the same reason as OC_WAKE_LOCK: with the real cooldown
# file shared, a scratch test is silently suppressed by the live watcher's last
# wake and reports "cooldown active" instead of exercising delivery.
COOLDOWN_FILE="${OC_WAKE_COOLDOWN_FILE:-$HOME/.local/share/opencode/wake.last}"
while true; do
  sleep 2
  [ -f "$INBOX" ] || continue
  NOW=$(wc -l < "$INBOX")
  # ── Pointer resync guard (2026-09-14) ─────────────────────────────────────
  # LAST is read ONCE at startup, but the pointer FILE can move without this
  # process knowing: a test cleanup, a manual edit, or an inbox truncation.
  # If the file slips BEHIND the in-memory LAST, the loop is permanently ahead
  # of reality — `NOW > LAST` stays false forever and every future message is
  # skipped SILENTLY with nothing in the log. That is exactly how the owner's
  # 12:06 Telegram message was lost: the pointer file said 13 while this
  # watcher held LAST=14 in memory. Resync to the low-water mark.
  FILE_LAST=$(cat "$STATE" 2>/dev/null || echo 0)
  # A missing or corrupt pointer file must NOT trigger a resync — that would
  # replay the whole inbox and spam the session with every historical message.
  # Only a VALID, LOWER value counts as a deliberate external reset.
  case "$FILE_LAST" in ''|*[!0-9]*) FILE_LAST=0 ;; esac
  if { [ "$FILE_LAST" -gt 0 ] && [ "$FILE_LAST" -lt "$LAST" ]; } || [ "$NOW" -lt "$LAST" ]; then
    NEW_LAST=$FILE_LAST
    [ "$NOW" -lt "$NEW_LAST" ] && NEW_LAST=$NOW
    echo "$(date '+%F %T') resync: file=${FILE_LAST} memory=${LAST} inbox=${NOW} -> ${NEW_LAST}" \
      >> "$HOME/.local/share/opencode/wake_resync.log"
    LAST="$NEW_LAST"
    echo "$LAST" > "$STATE"
    continue
  fi

  [ "$NOW" -gt "$LAST" ] || continue
  BATCH=$(sed -n "$((LAST+1)),${NOW}p" "$INBOX")
  # GATE 2026-09-07: only lines whose `text` starts with "/main" wake. The
  # gate prints the stripped text for each accepted line (empty line for a
  # bare "/main" -> still accepted) and logs "gated (no /main)" per rejected
  # line to this watcher's log (wake.log / journal); its exit code is 0 iff at
  # least one line was accepted. One wake per batch of new lines, exactly once.
  DELIVERED=$(printf '%s\n' "$BATCH" | python3 "$GATE")
  ACCEPTED=$?
  # Burst collapse (2026-09-07): if the last wake is younger than COOLDOWN_SEC,
  # do NOT ping the session again — just consume the lines silently. This turns
  # a multi-line Bob burst into a single wake instead of N pings.
  NOW_EPOCH=$(date +%s)
  LASTSENT=0
  [ -f "$COOLDOWN_FILE" ] && LASTSENT=$(cat "$COOLDOWN_FILE" 2>/dev/null)
  if [ "$ACCEPTED" -eq 0 ] && { [ "$((NOW_EPOCH - LASTSENT))" -ge "$COOLDOWN_SEC" ] || [ "$LASTSENT" -eq 0 ]; }; then
    MAIN=$(printf '%s\n' "$DELIVERED" | tail -n 1)  # newest accepted /main
    # touch the cooldown marker even if the send itself fails: the POINT of the
    # cooldown is to throttle, and a re-send attempt would defeat that.
    echo "$NOW_EPOCH" > "$COOLDOWN_FILE"
    # The message itself is NOT carried in the wake. Bob's messages run to
    # thousands of characters, and a long wake body does not survive the trip
    # into session.prompt intact — the wake truncates or fails, and the agent
    # has to be told to read the inbox anyway. A short signal that always
    # arrives beats a long one that sometimes does not. $MAIN is still computed
    # above (it is what proves a /main line was accepted) but is not sent.
    WAKE_TEXT="⚡ tele monitor — check inbox: /tmp/clone_inbox.jsonl"

    # ── QUEUED APPEND, not a blocking prompt (owner, 2026-09-18) ─────────────
    # Owner: "make it inject in between turns, like on ur next tool call loop,
    # have it queue like a reg message".
    #
    # ── HISTORY, because each fix caused the next bug ────────────────────────
    # 1. Plain `session.prompt` does not settle until the whole assistant run
    #    finishes, so during a long run it simply BLOCKED — measured 2026-09-18:
    #    three messages over ~40 min, each spawning a bun child that sat in
    #    do_wait until `timeout 1800` reaped it, having delivered nothing, while
    #    the pointer had already advanced past them.
    # 2. `--no-reply` fixed the blocking (returns in ~0 s) but created a WORSE
    #    bug: it appends the message and starts NO run, so on an IDLE session
    #    nothing ever processed it. Measured 2026-09-23 by reading the session:
    #    wakes at 17:00:21 and 18:33:20 both sat in the transcript as user
    #    messages with NO assistant reply after either — the next reply came only
    #    when the owner typed something himself. Reported verbatim: "it ddint send
    #    till i sent a message myself".
    #
    # ── THE FIX: --async ─────────────────────────────────────────────────────
    # `--async` maps to session.promptAsync → POST /session/{id}/prompt_async,
    # documented as "Create and send a new message to a session, start if needed
    # and return immediately". It does BOTH things the previous two attempts each
    # got half right: it starts the run (so an idle session is woken) and it
    # returns at once (so the watcher is never parked). Verified live 2026-09-23:
    # returned in 0s and the idle session produced an assistant reply on its own.
    #
    # When a run is ALREADY in flight the queued message is picked up at the next
    # turn boundary, which is the "queue like a regular message" behaviour asked
    # for — prompt_async accepts the message either way.
    #
    # Inline (not detached) so a failed append is KNOWN before the pointer
    # advances, and a short timeout so a wedged API can never park the watcher.
    # ── --steer IS A SILENT NO-OP ON THIS SERVE — DO NOT USE IT (2026-09-30) ──
    # The steer-first ordering below shipped on 09-29 and BROKE every wake for
    # ~5 hours. `--steer` exits 0 whatever happens, so the `elif --async` fallback
    # was unreachable and every wake was "steered" into nothing.
    #
    # Measured on this serve (2026-09-30), against a throwaway session:
    #   POST /api/session/<id>/prompt {delivery:"steer"} -> HTTP 200 + a full
    #     admittedSeq payload, and the session gained ZERO messages.
    #   {delivery:"steer", resume:true}                  -> same, zero messages.
    #   {delivery:"queue"}                               -> same, zero messages.
    #   POST /session/<id>/prompt_async (v1, --async)    -> HTTP 204, 2 messages.
    # The whole v2 `/api/session/*/prompt` family ADMITS AND NEVER PERSISTS in this
    # build, and it answers 200 every time — so a status code proves nothing here.
    # The 09-29 "verified mid-turn" note was reading that same 200 as success.
    #
    # ⇒ --async is the ONLY path known to deliver. It queues to the next turn
    # boundary rather than injecting mid-turn, which costs latency on a long turn
    # but never loses the message. Latency is recoverable; silence is not.
    #
    # If steer is ever revisited, it must be verified by READING THE SESSION for
    # the wake text — never by its exit code. `OC_WAKE_MODE=steer` is the opt-in
    # for that experiment; it is deliberately NOT the default.
    wake_ok=0
    if [ "${OC_WAKE_MODE:-async}" = "steer" ]; then
      if timeout 30 "$HOME/.local/bin/bun" \
           "$HOME/.local/lib/ocbridge/oc_send.js" "$WAKE_TEXT" --steer \
           >/dev/null 2>&1 < /dev/null; then
        wake_ok=1
        echo "$(date '+%F %T') steered (UNVERIFIED) for lines $((LAST+1))..${NOW}" >> "$STATE_LOG"
      fi
    fi
    if [ "$wake_ok" = "0" ] && timeout 30 "$HOME/.local/bin/bun" \
         "$HOME/.local/lib/ocbridge/oc_send.js" "$WAKE_TEXT" --async \
         >/dev/null 2>&1 < /dev/null; then
      wake_ok=1
      echo "$(date '+%F %T') woke session (async) for lines $((LAST+1))..${NOW}" >> "$STATE_LOG"
    fi
    if [ "$wake_ok" = "1" ]; then
      :
    else
      # Loud, because silent loss is what this fix exists to end.
      echo "$(date '+%F %T') FAILED to wake session for lines $((LAST+1))..${NOW} — message(s) may be unseen" \
        >> "$STATE_LOG"
      echo "oc_wake_watch: append failed for lines $((LAST+1))..${NOW}" >&2
    fi
  else
    # ── COOLDOWN: HOLD the lines, do NOT advance past them (owner, 2026-09-18) ─
    # This branch used to advance the pointer past the batch "without waking".
    # The owner hit exactly that: inbox lines 106 and 107 arrived inside the
    # 300 s cooldown and were consumed silently — only a LATER message (108)
    # produced a ping. Had he stopped typing at 107 those messages would have
    # been lost outright; line 108 only "covered" them because the wake text
    # happens to tell the agent to read the whole inbox.
    #
    # The cooldown's purpose is to collapse a burst into ONE ping, which is
    # right. Discarding the burst is not. Leaving the pointer where it is holds
    # the batch: the next iteration re-evaluates it, and once the cooldown
    # elapses the accumulated lines are delivered in a single wake.
    echo "oc_wake_watch: cooldown active (lastwake ${LASTSENT} now ${NOW_EPOCH}), HOLDING lines $((LAST+1))..${NOW}" >&2
    continue
  fi
  # Pointer advances even when the batch was gated: a gated line is PROCESSED,
  # so it must never be re-delivered on the next iteration.
  # Advance BOTH the persisted state AND the in-memory LAST. The in-memory
  # value was the bug: LAST was only read once before the loop, so after the
  # first delivery `NOW > LAST` stayed true forever and the same line got
  # delivered every 2s. Setting LAST here closes the loop. Fixed 2026-09-07.
  LAST="$NOW"
  echo "$NOW" > "$STATE"
done
