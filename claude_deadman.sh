#!/usr/bin/env bash
# claude_deadman.sh — watchdog that reaches the USER directly when no Claude
# session is processing Telegram, so a dead/stalled session can't go silent.
#
# Detection (every 60s):
#   - NO claude session process running (tmux main or --resume/bg-pty), OR
#   - the newest /main message is unanswered: outbox empty AND no relay
#     sendMessage logged after the message timestamp (stall detection).
#
# Escalation on first detection:
#   1. Direct Telegram alert (bot API sendMessage) — bypasses the outbox relay
#      entirely, so it works with ZERO claude processes alive.
#   2. URGENT POKE appended to claude_inbox.json — any future session sees it.
#   3. Auto-relaunch the tmux main session (max 2/hour) via `claude --resume`.
# Re-alerts every 15 min while still down (max 3), then stays quiet.
#
# Durable: launched from the tmux auto-start (start_always_on_tmux.sh) so it
# survives reboots. /tmp is wiped at boot — this file lives in $HOME.
#
# Token: read from ~/.claude/channels/telegram/.env (TELEGRAM_BOT_TOKEN,
# TELEGRAM_CHAT_ID). NEVER echoed — only used inside the send.

ENV_FILE="$HOME/.claude/channels/telegram/.env"
INBOX="${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/claude_inbox.json"
OUTBOX="${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/claude_outbox.json"
MAIN_INBOX="${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/claude_main_inbox.json"
HANDOFF="${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/handoff_session_8_7.md"
RELAY_LOG="/tmp/orchestrator_start_test.log"
MAIN_DIR="${MAIN_DIR:-$HOME/.claude/projects}"
LOCK="/tmp/claude_deadman.lock"
LOG="/tmp/claude_deadman.log"
# Pipeline-health: alert when the ORCHESTRATOR hits a phase error and freezes
# (2026-08-07: my _plan_path bug froze execution for 7.5h — process stayed
# alive, relay kept working, only orchestrator.log had the error. phase_monitor
# checks subagents/OmniRoute, not orchestrator phase errors.)
PIPE_LOG="${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/orchestrator_stdout.log"
PIPE_STATE="/tmp/claude_deadman_pipe.state"
PIPE_FRESH=3600   # only alert on errors newer than this many seconds

# ── state ───────────────────────────────────────────────────────────────────
ALERTED=0           # times alerted since the current outage started
LAST_ALERT=0        # epoch of last alert
RELAUNCHED=0        # relaunches this hour
LAST_RELAUNCH=0

log() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }

send_direct() {  # send_direct "text"
  local text="$1"
  [ -z "$text" ] && return 1
  # shellcheck disable=SC1090
  [ -f "$ENV_FILE" ] && . "$ENV_FILE"
  [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && { log "no token"; return 1; }
  curl -s -m 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${text}" \
    -d "parse_mode=" >/dev/null
  log "direct alert sent"
}

claude_alive() {
  pgrep -f "claude --plugin-dir" >/dev/null 2>&1 && return 0
  pgrep -f "claude.exe --resume" >/dev/null 2>&1 && return 0
  pgrep -f "claude agents" >/dev/null 2>&1 && return 0
  return 1
}

newest_main_msg() {  # echoes epoch of newest /main inbox message, or nothing
  python3 - "$INBOX" << 'PYEOF'
import json, sys, os
from datetime import datetime
try:
    inbox = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
for m in reversed(inbox):
    t = m.get('text', '')
    if t.startswith('/main') or t.startswith('URGENT'):
        ts = m.get('ts', '')
        try:
            dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
            print(int(dt.timestamp()))
            raise SystemExit(0)
        except Exception:
            continue
PYEOF
}

outbox_sent_since() {  # 0 if the bot last SENT a message after epoch $1
  # RELAY_LOG is the orchestrator's stdout — updated by every cycle log line,
  # so an mtime check is meaningless. Real evidence = a sendMessage POST in
  # orchestrator.log (relay delivers outbox messages through the same bot).
  [ -f "$PIPE_LOG" ] || return 1
  local line ts epoch
  line=$(grep -aE "sendMessage.*200 OK" "$PIPE_LOG" | tail -1)
  [ -z "$line" ] && return 1
  ts=$(echo "$line" | cut -d, -f1 | cut -d' ' -f1-2)
  epoch=$(date -d "$ts" +%s 2>/dev/null) || epoch=0
  [ "$epoch" -gt "$1" ] && return 0 || return 1
}

# Session-work signal: the main worker session appends to its transcript
# jsonl on every turn (tool calls, wake events). If a transcript was written
# AFTER the unanswered message, the session is alive and grinding — NOT
# stalled. Prevents false "SESSION DOWN" alerts during long step-fixes.
SESSION_DIRS="$HOME/.claude/projects/-home-roni $MAIN_DIR"
session_working() {  # 0 if a claude transcript was written after epoch $1
  local since=$1 d f mt
  for d in $SESSION_DIRS; do
    [ -d "$d" ] || continue
    f=$(ls -t "$d"/*.jsonl 2>/dev/null | head -1)
    [ -n "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$mt" -gt "$since" ] && return 0
  done
  return 1
}

stalled() {
  # unanswered /main message (no outbox reply, no relay send after it)
  local newest
  newest=$(newest_main_msg) || newest=""
  [ -z "$newest" ] && return 1
  local now; now=$(date +%s)
  [ $((now - newest)) -lt 600 ] && return 1   # <10min old — session may still be working
  # answered? outbox non-empty means a reply is queued; relay mtime newer = sent
  if [ -s "$OUTBOX" ]; then
    if python3 -c "import json,sys; d=json.load(open('$OUTBOX')); sys.exit(0 if len(d)>0 else 1)"; then
      return 1   # reply pending in outbox → not stalled
    fi
  fi
  outbox_sent_since "$newest" && return 1
  session_working "$newest" && return 1   # session actively working → not stalled
  return 0
}

pipeline_error() {  # echoes epoch+text of latest orchestrator error, or nothing
  [ -f "$PIPE_LOG" ] || return 1
  local line ts epoch
  line=$(grep -aE "Orchestrator error|Traceback \(most recent" "$PIPE_LOG" | tail -1)
  [ -z "$line" ] && return 1
  ts=$(echo "$line" | cut -d, -f1 | cut -d' ' -f1-2)
  epoch=$(date -d "$ts" +%s 2>/dev/null) || epoch=0
  [ "$epoch" -lt 1 ] && return 1
  echo "$epoch|$line"
}

relaunch_main() {
  local newest_jsonl
  # Newest across BOTH live project dirs — the main session's transcript lives
  # in -home-roni/, not the telegram-monitor dir (2026-08-08 fix).
  newest_jsonl=$(ls -t "$MAIN_DIR"/*.jsonl "$HOME/.claude/projects/-home-roni"/*.jsonl 2>/dev/null | head -1)
  [ -z "$newest_jsonl" ] && { log "no jsonl to resume"; return 1; }
  tmux has-session -t ${TMUX_SESSION:-main} 2>/dev/null || { log "no tmux session ${TMUX_SESSION:-main}"; return 1; }
  # Extract a compact conversation copy of the session for the successor to
  # read (user request 2026-08-08), then relaunch with bypassPermissions.
  "${PYTHON:-python3}" \
    "$HOME/Roni_workspace/audits_plans/extract_session_convo.py" "$newest_jsonl" --max-turns 400 \
    >>"$LOG" 2>&1
  tmux new-window -t ${TMUX_SESSION:-main} -n claude-resume \
    "cd ${PLUGIN_DIR:-$HOME/.claude/plugins/telegram-monitor} && claude --resume \"$newest_jsonl\" --plugin-dir ${PLUGIN_DIR:-$HOME/.claude/plugins/telegram-monitor} --permission-mode bypassPermissions" 2>>"$LOG"
  log "relaunched main from $newest_jsonl"
  text_handoff
}

# Inject the session handoff into the MAIN inbox so the (re)started session
# receives it as its first message (user request 2026-08-08: resurrection must
# text the handoff). Reads the handoff file; appends as one entry, from deadman.
text_handoff() {
  [ -f "$HANDOFF" ] || { log "no handoff file at $HANDOFF"; return 0; }
  local htext
  htext=$(cat "$HANDOFF")
  python3 - "$MAIN_INBOX" "$htext" << 'PYEOF'
import json, sys
try:
    inbox = json.load(open(sys.argv[1]))
except Exception:
    inbox = []
inbox.append({"ts": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "from": "deadman", "text": sys.argv[2], "direct": True})
tmp = sys.argv[1] + ".tmp"
open(tmp, "w").write(json.dumps(inbox, indent=2))
import os; os.replace(tmp, sys.argv[1])
PYEOF
  log "handoff texted to main inbox (len $(echo "$htext" | wc -c))"
}

# ── loop ────────────────────────────────────────────────────────────────────
if [ "$1" = "--test" ]; then
  send_direct "✅ deadman direct-alert channel test — if u see this, the bot can reach u even if the claude session dies (bypasses the relay). — claude_deadman"
  exit 0
fi

exec 9>"$LOCK"
flock -n 9 || exit 0

while true; do
  now=$(date +%s)
  if ! claude_alive || stalled; then
    if [ $((now - LAST_ALERT)) -ge 900 ] && [ "$ALERTED" -lt 3 ]; then
      if claude_alive; then
        send_direct "⚠️ CLAUDE SESSION BUSY (deadman) — a claude session is running but hasn't answered your last /main msg in 10+ min (likely grinding an CLAUDE step). Send /wake if it feels stuck. — claude_deadman"
      else
        send_direct "🚨 CLAUDE SESSION DOWN (deadman) — no claude process answering your msgs. cross_eval keeps running; a claude session is being (re)started. — claude_deadman"
      fi
      # poke for any future session
      python3 - "$INBOX" "$(date -u +%Y-%m-%dT%H:%M:%S.%fZ)" << 'PYEOF'
import json, sys
try:
    inbox = json.load(open(sys.argv[1]))
except Exception:
    inbox = []
inbox.append({"ts": sys.argv[2], "from": "deadman", "text": "URGENT POKE: user pings went unanswered (deadman). Check claude_outbox.json/claude_inbox.json and reply now.", "direct": True})
tmp = sys.argv[1] + ".tmp"
open(tmp, "w").write(json.dumps(inbox, indent=2))
import os; os.replace(tmp, sys.argv[1])
PYEOF
      ALERTED=$((ALERTED + 1)); LAST_ALERT=$now
      log "alert #$ALERTED (alive=$(claude_alive && echo yes || echo no), stalled=$(stalled && echo yes || echo no))"
      # auto-relaunch (max 2/hour)
      if ! claude_alive && [ $((now - LAST_RELAUNCH)) -ge 1800 ] && [ "$RELAUNCHED" -lt 2 ]; then
        relaunch_main; RELAUNCHED=$((RELAUNCHED + 1)); LAST_RELAUNCH=$now
      fi
    fi
  else
    ALERTED=0  # healthy again — reset outage state
  fi

  # ── pipeline-health: orchestrator phase error (stuck, not user-stall) ─────
  perr=$(pipeline_error) || perr=""
  if [ -n "$perr" ]; then
    perr_epoch=${perr%%|*}
    perr_text=${perr#*|}
    last_alerted=$(cat "$PIPE_STATE" 2>/dev/null || echo 0)
    if [ $((now - perr_epoch)) -le "$PIPE_FRESH" ] && [ "$perr_epoch" -gt "$last_alerted" ]; then
      send_direct "⚠️ PIPELINE ERROR (deadman): orchestrator hit an error and may be frozen — ${perr_text:0:200}"
      echo "$perr_epoch" > "$PIPE_STATE"
      log "pipeline error alert: ${perr_text:0:120}"
    fi
  fi
  sleep 60
done
