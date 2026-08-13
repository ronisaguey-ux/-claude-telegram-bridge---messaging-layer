#!/usr/bin/env bash
# session_heartbeat.sh — live context heartbeat for the CLAUDE always-on bot.
#
# Wired as PostToolUse / UserPromptSubmit / Stop hooks in ~/.claude/settings.json.
# Every tool call, user prompt, and turn end in ANY claude session appends one
# JSON line to audits_plans/claude_heartbeat.jsonl carrying:
#   {ts, session, event, tool, summary, last_response}
# The always-on telegram-monitor session reads the tail of this file (filtered
# to the MAIN session id) before answering, so it always reflects live state —
# no hourly refresh needed.
#
# Must be fast (<100ms): jq + printf only. Never fails loudly.

set -u
HEARTBEAT="${AUDITS_PLANS_DIR:-$HOME/Roni_workspace/audits_plans}/claude_heartbeat.jsonl"

input=$(cat)

session=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // .event // "hook"' 2>/dev/null)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)

# Compact summary of what happened (tool input / user prompt), capped at 200 chars
summary=""
case "$event" in
  UserPromptSubmit)
    summary=$(printf '%s' "$input" | jq -r '.prompt // .message // .tool_input.prompt // ""' 2>/dev/null | tr '\n' ' ' | head -c 200)
    ;;
  PostToolUse|PostToolUseFailure)
    summary=$(printf '%s' "$input" | jq -r '.tool_input | tostring' 2>/dev/null | tr '\n' ' ' | head -c 200)
    ;;
  Stop)
    # grab the last assistant response from this session's transcript
    transcript=$(ls "$HOME/.claude/projects"/*/"$session".jsonl 2>/dev/null | head -1)
    if [ -n "$transcript" ]; then
      summary=$(python3 - "$transcript" << 'PYEOF' 2>/dev/null
import json, sys
path = sys.argv[1]
last = ""
try:
    with open(path, "rb") as f:
        f.seek(-12000, 2)
        tail = f.read().decode("utf-8", "ignore")
    for line in tail.splitlines():
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") == "assistant":
            c = d.get("message", {}).get("content", "")
            if isinstance(c, str) and c.strip():
                last = c
            elif isinstance(c, list):
                texts = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
                if texts:
                    last = " ".join(texts)
except Exception:
    pass
print(last.replace("\n", " ")[:200])
PYEOF
)
    fi
    ;;
esac

printf '%s\n' "$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                     --arg session "$session" --arg event "$event" --arg tool "$tool" \
                     --arg summary "$summary" \
                     '{ts:$ts, session:$session, event:$event, tool:$tool, summary:$summary}')" \
  >> "$HEARTBEAT" 2>/dev/null || true

# keep the file bounded (last ~2000 lines)
lines=$(wc -l < "$HEARTBEAT" 2>/dev/null || echo 0)
if [ "$lines" -gt 2000 ]; then
  tail -n 2000 "$HEARTBEAT" > "$HEARTBEAT.tmp" 2>/dev/null && mv "$HEARTBEAT.tmp" "$HEARTBEAT" 2>/dev/null
fi
exit 0
