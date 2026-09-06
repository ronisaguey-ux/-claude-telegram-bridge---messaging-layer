#!/usr/bin/env bash
# sessionstart_arm_wake.sh — SessionStart hook output: tells the freshly started
# session to (re)arm the Telegram wake Monitor.
#
# Why: the wake receiver is an in-session Monitor (tail -F /tmp/main_wake.log).
# If the CLI process restarts (supervisor bounce, compaction resume, crash), the
# Monitor dies with it and /main-or-plain Telegram messages silently stop waking
# the session. This hook re-injects the arm instruction on EVERY session start
# so the wake chain is self-healing and permanent.
#
# Output format: SessionStart additionalContext (valid JSON), applied as context.

cat <<'EOF'
{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "[WAKE-ARM] You are the Claude main session. A durable chain exists: watch-inbox.sh -> claude_main_inbox.json -> watch-claude-main-inbox.sh -> /tmp/main_wake.log. ALWAYS ensure, immediately after this start, that a persistent Monitor is running with the command: tail -F -n 0 /tmp/main_wake.log (description: 'main wake log — new Telegram messages for this session'). If it is not already active, arm it via the Monitor tool (persistent=true). A line appearing on that file means a NEW Telegram message arrived — wake up and read the newest entry(ies) from /home/roni/Roni_Workspace/audits_plans/claude_main_inbox.json and respond accordingly (prefix replies with 'main: ')."}}
EOF
