#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/models.env"

ROLE="${1:?Usage: start.sh <qwen27b|qwen35b|qwen35b_fallback|qwen_coder|gemma|devstral>}"

case "$ROLE" in
  qwen27b)           MODEL="$QWEN27B_MODEL";           PORT="$QWEN27B_PORT";     CTX="$QWEN27B_CTX" ;;
  qwen35b)           MODEL="$QWEN35B_MODEL";           PORT="$QWEN35B_PORT";     CTX="$QWEN35B_CTX" ;;
  qwen35b_fallback)  MODEL="$QWEN35B_FALLBACK_MODEL";  PORT="$QWEN35B_PORT";     CTX="$QWEN35B_CTX" ;;
  qwen_coder)        MODEL="$QWEN_CODER_MODEL";        PORT="$QWEN_CODER_PORT"; CTX="$QWEN_CODER_CTX" ;;
  gemma)             MODEL="$GEMMA_MODEL";             PORT="$GEMMA_PORT";      CTX="$GEMMA_CTX" ;;
  devstral)          MODEL="$DEVSTRAL_MODEL";          PORT="$DEVSTRAL_PORT";   CTX="$DEVSTRAL_CTX" ;;
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
echo "INFO: log: $LOGFILE"
echo "INFO: context: $CTX"
echo "INFO: startup timeout: ${MODEL_START_TIMEOUT_SECONDS}s"
[ -n "${MODEL_ENV_PREFIX:-}" ] && echo "INFO: env prefix: $MODEL_ENV_PREFIX"
[ -n "${LLAMA_EXTRA_ARGS:-}" ] && echo "INFO: extra args: $LLAMA_EXTRA_ARGS"

# shellcheck disable=SC2086
if [ -n "${MODEL_ENV_PREFIX:-}" ]; then
  env $MODEL_ENV_PREFIX "$LLAMA_SERVER" \
    -m "$MODEL" \
    -c "$CTX" \
    $LLAMA_FLAGS \
    $LLAMA_EXTRA_ARGS \
    --host 127.0.0.1 \
    --port "$PORT" \
    > "$LOGFILE" 2>&1 &
else
  # shellcheck disable=SC2086
  "$LLAMA_SERVER" \
    -m "$MODEL" \
    -c "$CTX" \
    $LLAMA_FLAGS \
    $LLAMA_EXTRA_ARGS \
    --host 127.0.0.1 \
    --port "$PORT" \
    > "$LOGFILE" 2>&1 &
fi

PID=$!
echo "$PID" > "$PIDFILE"
echo "INFO: pid $PID"

cleanup_startup_failure() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    echo "INFO: stopping $ROLE after startup failure (pid $pid)" >&2
    kill "$pid" 2>/dev/null || true
    sleep 2
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
}

for i in $(seq 1 "$MODEL_START_TIMEOUT_SECONDS"); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "INFO: $ROLE ready after ${i}s"
    exit 0
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: $ROLE exited during startup. Log follows:" >&2
    tail -120 "$LOGFILE" >&2 || true
    rm -f "$PIDFILE"
    exit 1
  fi
  sleep 1
done

echo "ERROR: $ROLE did not become ready within ${MODEL_START_TIMEOUT_SECONDS}s. Check $LOGFILE" >&2
tail -80 "$LOGFILE" >&2 || true
cleanup_startup_failure "$PID"
exit 1
