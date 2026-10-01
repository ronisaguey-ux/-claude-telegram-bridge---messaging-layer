#!/usr/bin/env bash
# oc_datalake_wake.sh — wake the opencode session when the helpotron Data Lake grows.
# The /main gate (tele_inbox_gate.py) REJECTS datalake/signup lines (they have no
# text starting with "/main"), so oc_wake_watch.sh ignores them. This watcher runs
# separately, accepts ONLY source:"datalake"/"signup" inbox lines, and injects a
# wake into the newest opencode session via oc_send.js. It keeps its own inbox
# pointer + its own single-instance lock, so it never conflicts with the Bob wake
# path or double-delivers a line. Add --daemon to self-background (nohup).
set -u
INBOX="${OC_INBOX:-/tmp/clone_inbox.jsonl}"
STATE="${OC_DATALAKE_STATE:-/tmp/oc_datalake_wake_line.no}"
LOCK="$HOME/.local/share/opencode/datalake_wake.lock"
LOG="$HOME/.local/share/opencode/datalake_wake.log"
PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

if [ "${1:-}" = "--daemon" ]; then
  [ -f "/tmp/oc_datalake_wake_daemon.pid" ] && [ -d "/proc/$(cat /tmp/oc_datalake_wake_daemon.pid 2>/dev/null)" ] && { echo "already daemonized"; exit 0; }
  nohup "$0" >>"$LOG" 2>&1 &
  echo $! > /tmp/oc_datalake_wake_daemon.pid
  echo "oc_datalake_wake: daemon pid $!"
  exit 0
fi

[ -f "$STATE" ] || echo 0 > "$STATE"
LAST=$(cat "$STATE")

# Single-instance guard: one watcher may run the loop at a time, exactly like
# oc_wake_watch.sh, so a restart overlap never re-delivers a line.
exec 9>"$LOCK"
flock -n 9 || { echo "oc_datalake_wake: another instance holds the lock, exiting"; exit 0; }

# Burst collapse: throttle re-wakes so a multi-line lake burst yields ONE ping.
COOLDOWN_SEC="${OC_DATALAKE_WAKE_COOLDOWN:-120}"
COOLDOWN_FILE="$HOME/.local/share/opencode/datalake_wake.last"

while true; do
  sleep 2
  [ -f "$INBOX" ] || continue
  NOW=$(wc -l < "$INBOX")
  # ── Pointer resync guard (2026-09-14) ─────────────────────────────────────
  # LAST is read ONCE at startup, but the pointer FILE can move without this
  # process knowing: a test cleanup, a manual edit, or an inbox truncation. If
  # the file slips BEHIND the in-memory LAST the loop is permanently ahead of
  # reality — `NOW > LAST` stays false forever and every future entry is skipped
  # SILENTLY. The Bob watcher lost a real owner message to exactly this. Take
  # the low-water mark; a missing/corrupt file must NOT resync, or it would
  # replay the whole inbox.
  FILE_LAST=$(cat "$STATE" 2>/dev/null || echo 0)
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

  # Accept only source:"datalake" / source:"signup" lines. Bob's /main lines have
  # no "source" field -> None -> not in the set -> rejected (disjoint from the
  # /main gate). One line of summary per accepted entry.
  # NOTE: batch must be passed as argv[1] (a temp file), NOT piped to stdin:
  # `python3 - <<PY` reads the PROGRAM from stdin, so piping the batch there too
  # collides and the filter parses the Python source instead of the JSON.
  BATCH_FILE=$(mktemp)
  printf '%s\n' "$BATCH" > "$BATCH_FILE"
  SUMMARY=$(python3 - "$BATCH_FILE" <<'PY'
import json, sys
accepted = []
loud = False
for raw in open(sys.argv[1], encoding="utf-8"):
    raw = raw.strip()
    if not raw:
        continue
    try:
        d = json.loads(raw)
    except Exception:
        continue
    src = d.get("source")
    if src not in ("datalake", "signup"):
        continue
    kind = str(d.get("kind") or "")
    title = str(d.get("title") or "entry")[:140]
    if src == "signup":
        accepted.append(title)
        loud = True
    elif kind == "feedback":
        accepted.append(f"{kind}: {title}")
        loud = True
    elif kind == "telemetry":
        # Telemetry IS a wake. It used to be QUIET, and QUIET sends with
        # --no-reply, which merely APPENDS the text — it does not start a run, so
        # the entry sat inert until the owner happened to type. That is exactly
        # how the 2026-09-15 18:20 `assignment_evasion` entries went unseen: they
        # were delivered into the session and did nothing. Verified they were
        # also cooldown-blocked (datalake_wake.last was 15s older than the first
        # entry, and the 120s cooldown swallowed the second).
        #
        # Telemetry volume is LOW — 2 rows in 24h against 797 all-time — so a real
        # wake per batch costs nothing, and the 120s cooldown already collapses a
        # burst into one ping. An entry nobody is told about is not telemetry,
        # it is a silent log.
        accepted.append(f"{kind}: {title}")
        loud = True
    else:
        # microcredit / training_corpus and anything else unknown stays QUIET:
        # machine growth noise, queued for the next run rather than starting one.
        accepted.append(f"{kind}: {title}")
# Emit NOTHING when nothing was accepted (owner, 2026-09-18).
#
# This used to print "QUIET" unconditionally, and that single word was the whole
# bug: SUMMARY is captured from this stdout and is tested with `[ -n "$SUMMARY" ]`,
# which "QUIET" satisfies. So a batch that contained ONLY the owner's Telegram
# lines — all correctly rejected below by the source filter — still produced a
# wake, and it arrived as "Data Lake: QUIET". The owner asked exactly this:
# "why does it send data lake quiet every tele message, data lake is a
# completely diff monitor". It is a different monitor, and it should have stayed
# silent; the empty accept-list was being reported as a status.
#
# No accepted entries => no output => no wake. Silence is the correct answer for
# "nothing to report", not a status line.
if not accepted:
    sys.exit(0)
# First line is the delivery class: LOUD wakes the session immediately, QUIET is
# queued for whenever a run next happens.
print("LOUD" if loud else "QUIET")
for b in accepted:
    print(b)
PY
)
  rm -f "$BATCH_FILE"

  if [ -n "$SUMMARY" ]; then
    NOW_EPOCH=$(date +%s)
    LASTSENT=0
    [ -f "$COOLDOWN_FILE" ] && LASTSENT=$(cat "$COOLDOWN_FILE" 2>/dev/null)
    if [ "$((NOW_EPOCH - LASTSENT))" -ge "$COOLDOWN_SEC" ]; then
      echo "$NOW_EPOCH" > "$COOLDOWN_FILE"
      CLASS=$(printf '%s\n' "$SUMMARY" | head -n 1)
      MAIN=$(printf '%s\n' "$SUMMARY" | tail -n 1)
      # LOUD (a signup, or a user feedback entry) is sent WITHOUT --no-reply so
      # session.prompt actually starts a run. With --no-reply the text is merely
      # appended and then sits inert until something else happens to trigger a
      # turn, which is how the HLP-9827-6X signup went unseen for 2.6 hours on
      # 2026-09-14: it only surfaced once the owner typed. A wake that needs
      # someone already at the keyboard is not a wake.
      #
      # QUIET telemetry keeps --no-reply deliberately: it is machine noise, and
      # firing an unattended run per entry would burn tokens for nothing.
        if [ "$CLASS" = "LOUD" ]; then
          # --async (2026-09-23). This used to be `setsid timeout 1800 bun ...`
          # detached, with no --no-reply. That worked — a detached child still
          # starts the run — but it held a bun process for up to 30 minutes per
          # wake, and because the send was backgrounded the watcher could not tell
          # whether it succeeded, so the state log recorded nothing either way.
          #
          # promptAsync returns as soon as the run is ACCEPTED, so the same
          # delivery costs ~0s and blocks nothing. Inline now, so a failure is
          # known before the pointer advances — the same silent-loss rule the
          # telegram watcher learned the hard way.
          if timeout 30 "$HOME/.local/bin/bun" \
               "$HOME/.local/lib/ocbridge/oc_send.js" "Data Lake: $MAIN" --async \
               >/dev/null 2>&1 < /dev/null; then
            echo "$(date '+%F %T') woke session for datalake: $(printf '%s' "$MAIN" | head -c 80)" >> "$HOME/.local/share/opencode/wake_delivery.log"
          else
            echo "$(date '+%F %T') FAILED to wake session for datalake: $(printf '%s' "$MAIN" | head -c 80)" >> "$HOME/.local/share/opencode/wake_delivery.log"
          fi
        else
          # QUIET telemetry keeps --no-reply DELIBERATELY: it appends the line to the
          # transcript without starting a run. That is machine noise the owner wants
          # visible but not acted on, and firing an unattended run per entry would
          # burn tokens for nothing. Do not "fix" this to --async.
          "$HOME/.local/bin/bun" "$HOME/.local/lib/ocbridge/oc_send.js" "Data Lake: $MAIN" --no-reply
        fi
    fi
  fi

  # Advance BOTH the persisted state AND in-memory LAST, closing the loop so the
  # same line is never delivered again (the oc_wake_watch 09-07 lesson).
  LAST="$NOW"
  echo "$NOW" > "$STATE"
done
