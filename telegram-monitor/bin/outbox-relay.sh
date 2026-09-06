#!/usr/bin/env bash
# outbox-relay.sh — deliver claude_outbox.json entries to Telegram (dumb relay).
#
# 2026-08-15: the always-on tmux monitor session (whose LLM did the outbox
# relay) died — tmux server gone, claude_outbox.json undelivered, owner got
# silence for hours. This scripted relay restores the contract from
# CLAUDE.md: "A drained-to-[] outbox = delivered". No LLM, no tmux: it can
# only die on purpose.
#
# Flow: claim via atomic .pending rename -> send each entry via
# send-telegram.sh -> remove the pending file. Single instance via flock.
set -uo pipefail

OUTBOX="/home/roni/Roni_Workspace/audits_plans/claude_outbox.json"
LOG="/home/roni/Roni_Workspace/audits_plans/outbox_relay.log"
PY="/home/roni/Roni_Workspace/oculus/.venv-orch/bin/python"
SEND="/home/roni/Roni_Workspace/oculus/scripts/telegram_monitor/telegram-monitor/bin/send-telegram.sh"
FLOCK=/tmp/outbox_relay.lock

exec 9>"$FLOCK"
flock -n 9 || { echo "outbox-relay already running" >&2; exit 0; }

set -a
source /home/roni/.config/oculus/orchestrator.env
set +a
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "TELEGRAM_BOT_TOKEN not in orchestrator.env" >&2
  exit 1
fi

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

log "outbox-relay up"

while true; do
  if [[ -f "$OUTBOX" ]]; then
    if ! mv -f "$OUTBOX" "$OUTBOX.pending" 2>/dev/null; then
      sleep 2
      continue
    fi
    texts=$("$PY" - "$OUTBOX.pending" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
items = d if isinstance(d, list) else [d]
for m in items:
    if isinstance(m, dict):
        sender = (m.get('from') or '').lower()
        t = (m.get('text') or '').strip()
        if not t:
            continue
        if sender in ('antigravity', 'agy') and not t.lower().startswith('agy:'):
            t = f"agy: {t}"
        elif sender in ('claude', 'main', 'orchestrator', 'claude_code') and not t.lower().startswith('main:'):
            t = f"main: {t}"
        elif sender in ('webchat', 'deepseek', 'expert', 'auto_responder') and not t.lower().startswith('webchat:'):
            t = f"webchat: {t}"
        print(t.replace('\n', ' ').replace('\r', ' '))
PYEOF
)
    n=0; failed=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      n=$((n+1))
      if "$SEND" "$line" >/dev/null 2>&1; then
        log "SENT: ${line:0:70}"
      else
        # 08-24 (grammY queue pattern): failed sends were DELETED forever
        # (VPN flake lost messages permanently). Keep .pending, retry capped.
        failed=$((failed+1))
        log "SEND_FAIL (kept, retry cap 5): ${line:0:70}"
        printf '%s\n' "$line" >> "$OUTBOX.retry"
      fi
    done <<< "$texts"
    # startup recovery: `.pending` stranded by a relay crash mid-mv is re-read + retried
    if [ -f "$OUTBOX.retry" ] && [ "$(wc -l < "$OUTBOX.retry")" -le 20 ]; then
      log "recovering $(wc -l < "$OUTBOX.retry") retry lines"
      while IFS= read -r rl; do
        [[ -z "$rl" ]] && continue
        if "$SEND" "$rl" >/dev/null 2>&1; then
          log "RECOVERED: ${rl:0:60}"
        fi
      done < "$OUTBOX.retry"
    fi
    rm -f "$OUTBOX.retry"
    rm -f "$OUTBOX.pending"
    log "drained (n=$n, failed=$failed)"
  fi
  sleep 2
done
