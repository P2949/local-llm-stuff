#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:?Usage: stop.sh <role>}"
PIDFILE="/tmp/llm-pipeline-${ROLE}.pid"

if [ ! -f "$PIDFILE" ]; then
  echo "INFO: no pidfile for $ROLE"
  exit 0
fi

PID="$(cat "$PIDFILE")"
if kill -0 "$PID" 2>/dev/null; then
  echo "INFO: stopping $ROLE (pid $PID)"
  kill "$PID" 2>/dev/null || true
  sleep 3
  if kill -0 "$PID" 2>/dev/null; then
    echo "INFO: force killing $ROLE"
    kill -9 "$PID" 2>/dev/null || true
  fi
fi

rm -f "$PIDFILE"
echo "INFO: $ROLE stopped"
