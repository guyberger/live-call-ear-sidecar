#!/usr/bin/env bash
# Stop EAR sidecar processes listed in /tmp/ear-sidecar.pid
set -euo pipefail

PID_FILE="/tmp/ear-sidecar.pid"
if [[ ! -f "$PID_FILE" ]]; then
  echo "Not running (no $PID_FILE)"
  exit 0
fi

while read -r pid; do
  [[ -z "${pid:-}" ]] && continue
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
done < "$PID_FILE"

sleep 0.4
rm -f "$PID_FILE"
echo "stopped"
