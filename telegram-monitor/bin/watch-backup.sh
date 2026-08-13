#!/usr/bin/env bash
# watch-backup.sh — emit one stdout line per rclone backup problem.
#
# Contract: every stdout line is delivered to Claude as a notification. We
# watch the rclone log (/tmp/rclone_backup.log) and emit a line when:
#   - an ERROR appears in the log (upload failed, token expired, DNS stall)
#   - the backup STOPS making progress (no new "Copied" for 10 minutes)
#
# Each condition fires at most once, then must recover before it can fire
# again, so the session isn't spammed.

LOG="/tmp/rclone_backup.log"
STATE="/tmp/backup_monitor_last"
# baseline of "Copied" lines to detect stalls; seconds threshold for stall
STALL_SECS=600

# where we track the last seen progress marker
MARK_FILE="/tmp/backup_monitor_mark"

# How many consecutive errors we've already reported (avoid re-alerting same)
ERR_FILE="/tmp/backup_monitor_errcount"

err_count() { cat "$ERR_FILE" 2>/dev/null || echo 0; }
set_err_count() { echo "$1" > "$ERR_FILE"; }

# Track last progress timestamp (file mtime of log counts as progress)
last_progress() { stat -c %Y "$LOG" 2>/dev/null || echo 0; }

# Initialize marker
if [[ ! -f "$MARK_FILE" ]]; then
  echo "$(last_progress)" > "$MARK_FILE"
fi

while true; do
  sleep 30

  # --- 1) Errors in the log ---
  if [[ -f "$LOG" ]]; then
    # The retry wrapper logs "ERROR : Attempt N/3 succeeded" — the RESULT line
    # carries an ERROR-level prefix even on success. Filter those out so a
    # successful retry never fires an alert (2026-08-09: fired twice tonight).
    total_err=$(grep "ERROR" "$LOG" | grep -cv "succeeded" || echo 0)
    if (( total_err > $(err_count) )); then
      last_err=$(grep "ERROR" "$LOG" | grep -v "succeeded" | tail -1)
      echo "[backup] rclone ERROR: ${last_err:0:220}"
      set_err_count "$total_err"
    fi
  fi

  # --- 2) Stall: no progress for STALL_SECS ---
  if [[ -f "$LOG" ]]; then
    now=$(date +%s)
    last=$(cat "$MARK_FILE")
    # The backup wrapper runs TWO syncs back-to-back (repo + audits_plans),
    # each writing its own log — so "progress" = an rclone process in flight
    # OR either log growing. A stall is only real when rclone is ALIVE but
    # nothing has been written for STALL_SECS. Idle (no rclone at all) is a
    # normal completed backup, not a stall, and resets the clock so the next
    # backup starts fresh (2026-08-09: false STALLED while audits sync ran).
    if pgrep -x rclone >/dev/null 2>&1; then
      if [[ "$last" != "$(last_progress)" ]] || \
         [[ "$last" != "$(stat -c %Y /tmp/rclone_audits_plans.log 2>/dev/null || echo 0)" ]]; then
        echo "$(date +%s)" > "$MARK_FILE"
        echo "0" > "/tmp/backup_monitor_stalled"
      else
        stalled=$(cat "/tmp/backup_monitor_stalled" 2>/dev/null || echo 0)
        if (( now - last > STALL_SECS )) && [[ "$stalled" == "0" ]]; then
          echo "[backup] STALLED — no progress for $((STALL_SECS/60)) min (last: $(date -d @$last '+%H:%M'))"
          echo "1" > "/tmp/backup_monitor_stalled"
        fi
      fi
    else
      echo "$(date +%s)" > "$MARK_FILE"
      echo "0" > "/tmp/backup_monitor_stalled"
    fi
  fi
done
