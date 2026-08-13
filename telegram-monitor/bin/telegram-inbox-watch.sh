#!/usr/bin/env bash
# telegram-inbox-watch.sh — emit one line per NEW telegram message.
#
# Contract: every stdout line is delivered to Claude as a notification:
#   [telegram] <from>: <text>
#
# 2026-08-09: ts-based, NOT length-based — claude_inbox.json is a ring buffer
# (LEN 500), so length stays 500 while the tail rotates; length-based checks
# go blind once the buffer is full. We track the newest ts seen and emit
# anything strictly newer. Initializes to the newest ts at launch (no replay
# of history), then emits only genuinely new messages.
#
# Lives in telegram-monitor/bin/ so the memory watchdog's
# "/telegram-monitor/bin/" tier-0 rule protects it (the previous monitor was
# SIGTERM'd twice — exit 143/144).

INBOX="${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/claude_inbox.json"
PY="${PYTHON:-python3}"

last=$("$PY" - "$INBOX" <<'PYEOF'
import json, sys
try:
    msgs = json.load(open(sys.argv[1]))
    print(max((m.get('ts', '') for m in msgs), default=''))
except Exception:
    print('')
PYEOF
)

while true; do
  out=$("$PY" - "$INBOX" "$last" <<'PYEOF'
import json, sys
try:
    msgs = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
last = sys.argv[2]
new = [m for m in msgs if (m.get('ts') or '') > last]
if not new:
    sys.exit(0)
for m in new:
    text = (m.get('text') or '').replace('\n', ' ')
    print(f"[telegram] {m.get('from', 'telegram')}: {text}")
print("__LAST__" + max(m.get('ts', '') for m in new))
PYEOF
  )
  if [ -n "$out" ]; then
    last=$(printf '%s\n' "$out" | sed -n 's/^__LAST__//p' | tail -1)
    printf '%s\n' "$out" | grep -v '^__LAST__'
  fi
  sleep 3
done
