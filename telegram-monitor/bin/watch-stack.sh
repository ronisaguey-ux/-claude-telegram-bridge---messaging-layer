#!/usr/bin/env bash
# watch-stack.sh — emit one stdout line per CLAUDE stack process death.
#
# Contract: every stdout line is delivered to Claude as a notification. We
# poll the critical processes every 30s and emit ONE line the first time one
# of them is found DOWN. After all are back up, re-arm so the next death is
# caught again.

declare -A PROC
PROC[orchestrator]="run_workflow.py"
PROC[inbox_monitor]="inbox_monitor.py"
PROC[phase_monitor]="phase_monitor.py"
PROC[memory_watchdog]="memory_watchdog.py"

# state file: holds "armed" (ready to alert) or "fired"
STATE="/tmp/stack_monitor_armed"
if [[ ! -f "$STATE" ]]; then echo "armed" > "$STATE"; fi

while true; do
  sleep 30

  down=""
  for name in "${!PROC[@]}"; do
    frag="${PROC[$name]}"
    if ! pgrep -f "$frag" >/dev/null 2>&1; then
      down="${down}${name} "
    fi
  done

  armed=$(cat "$STATE")
  if [[ -n "$down" ]]; then
    if [[ "$armed" == "armed" ]]; then
      echo "[stack] DOWN: ${down% }"
      echo "fired" > "$STATE"
    fi
  else
    if [[ "$armed" == "fired" ]]; then
      echo "[stack] all back up"
      echo "armed" > "$STATE"
    fi
  fi
done
