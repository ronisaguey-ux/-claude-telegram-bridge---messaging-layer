#!/usr/bin/env bash
# watch-telegram-server.sh — keep the telegram plugin bun server alive.
#
# The bun server (server.ts) owns the getUpdates long-poll for the bot token;
# if it dies, inbound messages stop reaching the inbox. This watcher checks
# every 10s and restarts it if missing. Single instance via flock.
#
# Usage: bash bin/watch-telegram-server.sh  (or via Monitor persistent=true)

SERVER_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6"
LOCK="/tmp/telegram_server_watch.lock"
LOG="/tmp/telegram-server-watch.log"
# 2026-08-06: absolute path — reboots/launchd-style envs lose ~/.bun/bin from PATH
BUN_BIN="$HOME/.bun/bin/bun"

exec 9>"$LOCK"
flock -n 9 || exit 0   # another watcher already running

while true; do
  if ! pgrep -f "bun server.ts" >/dev/null 2>&1; then
    echo "$(date +%H:%M:%S) bun server down — restarting" >> "$LOG"
    cd "$SERVER_DIR" || continue
    # stdin-hold: the MCP server shuts down when stdin closes; tail -f /dev/null keeps it open
    setsid nohup bash -c "tail -f /dev/null | env TELEGRAM_ALLOW_ORPHAN=1 $BUN_BIN server.ts" >> /tmp/telegram-plugin-server.log 2>&1 &
    sleep 5
  fi
  sleep 10
done
