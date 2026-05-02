#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/models.env"

ROLE="${1:?Usage: start.sh <qwen27b|qwen35b|qwen35b_fallback|qwen_coder|gemma|devstral>}"

case "$ROLE" in
  qwen27b)         MODEL="$QWEN27B_MODEL";          PORT="$QWEN27B_PORT" ;;
  qwen35b)         MODEL="$QWEN35B_MODEL";          PORT="$QWEN35B_PORT" ;;
  qwen35b_fallback) MODEL="$QWEN35B_FALLBACK_MODEL"; PORT="$QWEN35B_PORT" ;;
  qwen_coder)      MODEL="$QWEN_CODER_MODEL";       PORT="$QWEN_CODER_PORT" ;;
  gemma)           MODEL="$GEMMA_MODEL";            PORT="$GEMMA_PORT" ;;
  devstral)        MODEL="$DEVSTRAL_MODEL";         PORT="$DEVSTRAL_PORT" ;;
  *) echo "ERROR: unknown model role: $ROLE" >&2; exit 1 ;;
esac

[ -x "$LLAMA_SERVER" ] || { echo "ERROR: llama-server not executable: $LLAMA_SERVER" >&2; exit 1; }
[ -f "$MODEL" ] || { echo "ERROR: model file not found: $MODEL" >&2; exit 1; }

PIDFILE="/tmp/llm-pipeline-${ROLE}.pid"
LOGFILE="/tmp/llm-pipeline-${ROLE}.log"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "INFO: $ROLE already running on port $PORT (pid $(cat "$PIDFILE"))"
  exit 0
fi

rm -f "$PIDFILE"
echo "INFO: starting $ROLE on port $PORT"
echo "INFO: model: $MODEL"

# shellcheck disable=SC2086
if [ -n "${MODEL_ENV_PREFIX:-}" ]; then
  env $MODEL_ENV_PREFIX "$LLAMA_SERVER" \
    -m "$MODEL" \
    -c "$DEFAULT_CTX" \
    $LLAMA_FLAGS \
    --host 127.0.0.1 \
    --port "$PORT" \
    > "$LOGFILE" 2>&1 &
else
  # shellcheck disable=SC2086
  "$LLAMA_SERVER" \
    -m "$MODEL" \
    -c "$DEFAULT_CTX" \
    $LLAMA_FLAGS \
    --host 127.0.0.1 \
    --port "$PORT" \
    > "$LOGFILE" 2>&1 &
fi

PID=$!
echo "$PID" > "$PIDFILE"
echo "INFO: pid $PID, log $LOGFILE"

for i in $(seq 1 90); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "INFO: $ROLE ready after ${i}s"
    exit 0
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: $ROLE exited during startup. Log follows:" >&2
    tail -80 "$LOGFILE" >&2 || true
    rm -f "$PIDFILE"
    exit 1
  fi
  sleep 1
done

echo "ERROR: $ROLE did not become ready within 90s. Check $LOGFILE" >&2
exit 1
