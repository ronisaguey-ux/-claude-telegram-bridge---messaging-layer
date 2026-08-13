#!/usr/bin/env bash
# start_always_on_tmux.sh — host the always-on CLAUDE Telegram monitor inside
# a detached tmux session so it survives VS Code being closed.
#
# Why: this Claude session normally lives in a VS Code terminal — closing VS
# Code kills it. Running the monitor session inside tmux decouples it from the
# editor. The monitor still idles at zero tokens; the plugin's watch-inbox.sh
# subprocess wakes it the instant a Telegram message lands in claude_inbox.json.
#
# Usage:
#   ./start_always_on_tmux.sh          # create + enter the tmux session
#   ./start_always_on_tmux.sh bg       # create detached (no attach)
#   tmux attach -t ${SESS}              # reattach any time
#   tmux ls                            # list sessions

set -u

SESS="${TMUX_SESSION:-main}"
MON_DIR="${PLUGIN_DIR:-$HOME/.claude/plugins/telegram-monitor}"

if tmux has-session -t "$SESS" 2>/dev/null; then
  # Self-heal: if the tmux session exists but the claude process inside is
  # dead (it can hang/die while the session survives), recreate it fresh.
  if pgrep -f "claude --plugin-dir.*${MON_DIR}" >/dev/null 2>&1; then
    echo "Session '$SESS' already exists."
    if [[ "${1:-}" != "bg" ]]; then
      exec tmux attach -t "$SESS"
    fi
    exit 0
  fi
  echo "Session '$SESS' exists but claude inside is dead — recreating."
  tmux kill-session -t "$SESS" 2>/dev/null
fi

echo "Creating tmux session '$SESS' in $MON_DIR ..."
# Create detached session running the always-on claude monitor with the
# telegram-inbox plugin monitors active (monitors.json -> watch-inbox.sh).
# Fresh session (no --resume): the plugin dir loads the 5 background monitors.
tmux new-session -d -s "$SESS" -c "$MON_DIR" \
  "claude --plugin-dir ${MON_DIR} --permission-mode bypassPermissions"

sleep 2
if tmux has-session -t "$SESS" 2>/dev/null; then
  echo "OK  session '$SESS' is running."
else
  echo "ERROR session '$SESS' failed to start — check 'tmux ls'."
  exit 1
fi

# 2026-08-06: keep the Telegram bun server (getUpdates poller) alive across
# reboots. flock'd — a second watcher (e.g. from a Monitor) exits cleanly.
nohup bash "$MON_DIR/bin/watch-telegram-server.sh" >> /tmp/telegram-server-watch.log 2>&1 &
echo "OK  telegram bun-server watcher started."

# 2026-08-06 (post-reboot fix): durable watchers in HOME (not /tmp — wiped at
# boot). Actions still happen even when no harness Monitor is attached.
nohup bash $HOME/vpn_watch.sh >> /tmp/vpn_watch.log 2>&1 &
nohup bash $HOME/audit_heartbeat.sh >> /tmp/audit_heartbeat.log 2>&1 &
echo "OK  vpn_watch + audit_heartbeat started (durable copies)."

# 2026-08-07: claude_deadman — direct-send watchdog. If no claude session
# answers the user within 10 min, it alerts via the bot API directly (works
# with zero sessions alive), pokes the inbox, and auto-relaunches the main
# session. flock'd, survives reboots via this auto-start.
nohup bash $HOME/claude_deadman.sh >> /tmp/claude_deadman.log 2>&1 &
echo "OK  claude_deadman started (direct-alert watchdog)."

if [[ "${1:-}" != "bg" ]]; then
  exec tmux attach -t "$SESS"
fi
