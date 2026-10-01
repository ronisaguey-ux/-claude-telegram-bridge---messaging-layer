#!/usr/bin/env bash
# oc_oom_watch.sh — wake the main opencode session when this box runs out of
# memory, or is about to.
#
# Requested by the owner 2026-09-14 ("add a monitor that wakes u up on any
# oom"), right after a desktop freeze caused by heavy parallel load — swap hit
# 3919/4095 MB and the machine thrashed for a minute. The existing
# envy-mem-watchdog PAUSES the biggest process and does not tell anyone; this
# one exists purely to WAKE THE AGENT so it can act.
#
# Four signals, cheapest first:
#   1. KERNEL OOM KILL — the literal "any OOM" the owner asked for. Read from
#      the journal (`oom-kill:` / `Killed process`). Each event is reported
#      once, keyed on the kernel timestamp, so restarts never re-fire it.
#   2. MemAvailable under a floor — the honest "about to die" number, not
#      "free" (which is ~0 on a healthy Linux box because of page cache).
#   3. PSI `memory full avg10` — the actual stall signal. `full` counts time
#      when EVERY task was blocked on memory; a high value is the freeze
#      itself, already happening.
#   4. Swap nearly full WITH low available RAM — thrashing, no headroom left.
#
# Delivery reuses the oc_send pattern fixed the same day: `oc_send.js` WITHOUT
# `--no-reply` (with `--no-reply` the message is appended and sits inert until
# something else triggers a turn — a wake that needs someone at the keyboard is
# not a wake), and DETACHED via setsid, because a non-reply send blocks until
# the whole assistant run finishes and would park this watcher inside the run.
#
# Deliberately tiny: bash + awk over /proc. It must never be part of the
# problem it reports.

set -u
PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# ── Tunables ─────────────────────────────────────────────────────────────────
AVAIL_FLOOR_MB="${OOM_AVAIL_FLOOR_MB:-700}"     # MemAvailable below this = act
PSI_FULL_TRIP="${OOM_PSI_FULL:-15}"             # PSI memory full avg10 >= this
SWAP_PCT_TRIP="${OOM_SWAP_PCT:-95}"             # swap used% >= this ...
SWAP_FLOOR_MB="${OOM_SWAP_AVAIL_MB:-1200}"      # ... but only if RAM this tight
POLL_SEC="${OOM_POLL_SEC:-5}"
COOLDOWN_SEC="${OOM_COOLDOWN_SEC:-240}"         # min gap between wakes
NEED_CONSEC="${OOM_CONSEC:-2}"                  # samples in a row before waking

LOG="$HOME/.local/share/opencode/oom_watch.log"
STATE="$HOME/.local/share/opencode/oom_watch.state"
COOLDOWN_FILE="$HOME/.local/share/opencode/oom_watch.last"
# Overridable so the watcher can be exercised without firing a real wake into
# the live session — point OOM_SEND at /bin/echo and OOM_BUN at /bin/echo to
# print instead of send.
SEND="${OOM_SEND:-$HOME/.local/lib/ocbridge/oc_send.js}"
BUN="${OOM_BUN:-$HOME/.local/bin/bun}"

mkdir -p "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

if [ "${1:-}" = "--daemon" ]; then
  setsid nohup "$0" run >>"$LOG" 2>&1 < /dev/null &
  echo "oc_oom_watch: daemon pid $!"
  exit 0
fi

# Single instance — two watchers would double every alert.
LOCK="$HOME/.local/share/opencode/oom_watch.lock"
exec 9>"$LOCK"
flock -n 9 || { log "another instance holds the lock, exiting"; exit 0; }

log "start: floor=${AVAIL_FLOOR_MB}MB psi_full=${PSI_FULL_TRIP} swap=${SWAP_PCT_TRIP}% cooldown=${COOLDOWN_SEC}s"

# ── The kernel's own OOM record. Each line carries a monotonic-ish kernel
#    timestamp; remember the last one seen so a restart does not re-report an
#    old kill forever. ─────────────────────────────────────────────────────────
LAST_OOM_TS=""
[ -f "$STATE" ] && LAST_OOM_TS=$(cat "$STATE" 2>/dev/null || true)

kernel_oom_since() {
  # Print any OOM-kill lines with a timestamp newer than LAST_OOM_TS.
  # `journalctl -k` needs no root for the user's own boot on this box (verified).
  journalctl -k --no-pager -o short-iso 2>/dev/null \
    | grep -iE "oom-kill:|Out of memory: Killed process|Memory cgroup out of memory" \
    | tail -n 20
}

memory_snapshot() {
  # Prints: <totalMB> <availMB> <swapTotalMB> <swapUsedPct>
  awk '
    /^MemTotal:/     { t=$2 }
    /^MemAvailable:/ { a=$2 }
    /^SwapTotal:/    { st=$2 }
    /^SwapFree:/     { sf=$2 }
    END {
      printf "%d %d %d %d\n", t/1024, a/1024, st/1024, (st>0 ? (st-sf)*100/st : 0)
    }' /proc/meminfo
}

psi_full_avg10() {
  # PSI reports `full avg10=0.00`; take the avg10 of the `full` line. The value
  # is a FLOAT, and bash arithmetic only speaks integers — so floor it here
  # rather than handing `[` a decimal and getting "integer expression expected".
  awk '/^full/ { for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) { sub(/avg10=/,"",$i); printf "%d\n", $i } }' \
    /proc/pressure/memory 2>/dev/null || echo 0
}

top_consumers() {
  ps -eo rss,comm --sort=-rss 2>/dev/null | awk 'NR>1 && NR<=7 { printf "    %s %dMB\n", $2, $1/1024 }'
}

fire() {
  local kind="$1" detail="$2"
  local now; now=$(date +%s)
  local last=0
  [ -f "$COOLDOWN_FILE" ] && last=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  if [ "$((now - last))" -lt "$COOLDOWN_SEC" ]; then
    log "cooldown active ($((now-last))s < ${COOLDOWN_SEC}s), suppressed: $kind"
    return
  fi
  echo "$now" > "$COOLDOWN_FILE"

  read -r MTOTAL MAVAIL MSTOTAL MSPCT <<<"$(memory_snapshot)"
  local psi; psi=$(psi_full_avg10)
  local msg="🚨 ${kind}: ${detail}. MemAvailable ${MAVAIL}MB/${MTOTAL}MB, swap ${MSPCT}% of ${MSTOTAL}MB, PSI full avg10=${psi}. Top RSS:
$(top_consumers)
Act: free memory (kill runaway renderers/chrome-headless, or pause the heavy job) before it freezes the desktop."

  log "WAKE [$kind] $detail (avail=${MAVAIL}MB swap=${MSPCT}% psi=${psi})"
  # Detached + no --no-reply => actually starts a run. See the header note.
  # --async (2026-09-23): starts the run AND returns immediately, so this is inline
  # rather than detached. Detached-without---no-reply did work, but it held a bun
  # process for up to 30 min per wake and hid failures from the log.
  if timeout 30 "$BUN" "$SEND" "$msg" --async >/dev/null 2>&1 < /dev/null; then
    log "wake accepted"
  else
    log "WAKE FAILED — the session did not accept the message"
  fi
}

hits=0
while true; do
  sleep "$POLL_SEC"
  fired_this_round=""

  # ── 1. kernel OOM kill (authoritative) ────────────────────────────────────
  oom_lines=$(kernel_oom_since)
  if [ -n "$oom_lines" ]; then
    newest=$(printf '%s\n' "$oom_lines" | tail -n 1)
    ts=$(printf '%s' "$newest" | awk '{print $1" "$2}')
    if [ "$ts" != "$LAST_OOM_TS" ]; then
      LAST_OOM_TS="$ts"
      echo "$LAST_OOM_TS" > "$STATE"
      who=$(printf '%s' "$newest" | sed -E 's/.*Killed process [0-9]+ \(([^)]+)\).*/\1/')
      log "kernel OOM detected: $newest"
      fire "KERNEL OOM-KILL" "the kernel killed ${who:-a process}"
      hits=0
      continue
    fi
  fi

  # ── 2-4. predictive thresholds, requiring consecutive samples ─────────────
  read -r MTOTAL MAVAIL MSTOTAL MSPCT <<<"$(memory_snapshot)"
  psi=$(psi_full_avg10)
  tripped=""
  if [ "${MAVAIL:-99999}" -lt "$AVAIL_FLOOR_MB" ]; then
    tripped="MemAvailable ${MAVAIL}MB < ${AVAIL_FLOOR_MB}MB"
  elif [ "${psi:-0}" -ge "$PSI_FULL_TRIP" ] 2>/dev/null; then
    tripped="memory PSI full avg10=${psi} >= ${PSI_FULL_TRIP} (tasks stalling)"
  elif [ "${MSPCT:-0}" -ge "$SWAP_PCT_TRIP" ] && [ "${MAVAIL:-99999}" -lt "$SWAP_FLOOR_MB" ]; then
    tripped="swap ${MSPCT}% and MemAvailable ${MAVAIL}MB"
  fi

  if [ -n "$tripped" ]; then
    hits=$((hits + 1))
    log "pressure sample $hits/$NEED_CONSEC: $tripped"
    if [ "$hits" -ge "$NEED_CONSEC" ]; then
      fire "MEMORY PRESSURE" "$tripped"
      hits=0                       # the cooldown throttles the rest
    fi
  else
    hits=0
  fi
done
