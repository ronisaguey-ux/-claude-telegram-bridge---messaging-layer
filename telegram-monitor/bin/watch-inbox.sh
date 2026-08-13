#!/usr/bin/env bash
# watch-inbox.sh — route Telegram messages to the right destination.
#
# Contract: one stdout line per NEW non-/main message, delivered to the
# monitor Claude as a notification (wakes the idle session). /main messages
# are routed MECHANICALLY — appended to claude_main_inbox.json for the main
# session and NOT emitted here — so routing never depends on LLM judgment.
#
# 2026-08-09 FIX: ts-based tracking, NOT length-based. claude_inbox.json is a
# ring buffer (LEN 500): once full, `length` stays 500 while the tail rotates,
# so `length > offset` is permanently false and the router goes blind (the
# 03:02:38Z batch of 5 messages sat unrouted because of exactly that).
# We now track the newest ts seen (/tmp/telegram_monitor_last_ts) and process
# anything strictly newer.

INBOX="${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/claude_inbox.json"
STATE_TS="/tmp/telegram_monitor_last_ts"
MAIN_INBOX="${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/claude_main_inbox.json"
PY="${PYTHON:-python3}"

# Initialize to the newest ts on first run so we only process FUTURE messages.
if [[ ! -f "$STATE_TS" ]]; then
  last_ts=$("$PY" - "$INBOX" <<'PYEOF'
import json, sys
try:
    msgs = json.load(open(sys.argv[1]))
    print(max((m.get('ts', '') for m in msgs), default=''))
except Exception:
    print('')
PYEOF
)
  echo "$last_ts" > "$STATE_TS"
fi

while true; do
  if [[ -f "$INBOX" ]]; then
    last_ts=$(cat "$STATE_TS" 2>/dev/null || echo "")
    out=$("$PY" - "$INBOX" "$last_ts" <<'PYEOF'
import json, sys
msgs = json.load(open(sys.argv[1]))
last = sys.argv[2]
new = [m for m in msgs if (m.get('ts') or '') > last]
if not new:
    sys.exit(0)
for m in new:
    text = m.get('text') or ''
    from_ = m.get('from') or ''
    print(f"TS:{m.get('ts', '')}|FROM:{from_}|{text}")
print("__MAX_TS__" + max(m.get('ts', '') for m in new))
PYEOF
)
    if [ -n "$out" ]; then
      new_last=$(printf '%s\n' "$out" | sed -n 's/^__MAX_TS__//p' | tail -1)
      printf '%s\n' "$out" | grep '^TS:' | while IFS= read -r line; do
        body="${line#TS:}"
        ts="${body%%|*}"
        rest="${body#*|}"
        from="${rest%%|*}"
        text="${rest#*|}"
        if [[ "$text" == "/main"* ]]; then
          # Mechanical /main routing -> main session inbox (no LLM judgment)
          "$PY" - "$ts" "$text" "$MAIN_INBOX" <<'PYEOF' >/dev/null 2>&1
import json, os, sys
ts, text, path = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path)) if os.path.exists(path) else []
key = (ts, text)
if (any((m.get('ts'), m.get('text')) == key for m in d)):
    sys.exit(0)
d.append({"ts": ts, "text": text})
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PYEOF
        else
          echo "[telegram] ${from}: $(printf '%s' "$text" | tr '\n' ' ')"
        fi
      done
      echo "$new_last" > "$STATE_TS"
    fi
  fi
  sleep 2
done
