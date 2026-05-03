#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:?Usage: ask.sh <role> <port> <system-file> <user-file> <output-file>}"
PORT="${2:?}"
SYSTEM_FILE="${3:?}"
USER_FILE="${4:?}"
OUTPUT_FILE="${5:?}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/models.env"

[ -f "$SYSTEM_FILE" ] || { echo "ERROR: system prompt not found: $SYSTEM_FILE" >&2; exit 1; }
[ -f "$USER_FILE" ] || { echo "ERROR: user prompt not found: $USER_FILE" >&2; exit 1; }

case "$ROLE" in
  qwen27b)           MAX_TOKENS="$QWEN27B_MAX_TOKENS";     OUTPUT_MAX_BYTES="$QWEN27B_OUTPUT_MAX_BYTES" ;;
  qwen35b|qwen35b_fallback) MAX_TOKENS="$QWEN35B_MAX_TOKENS"; OUTPUT_MAX_BYTES="$QWEN35B_OUTPUT_MAX_BYTES" ;;
  qwen_coder)        MAX_TOKENS="$QWEN_CODER_MAX_TOKENS"; OUTPUT_MAX_BYTES="$QWEN_CODER_OUTPUT_MAX_BYTES" ;;
  gemma)             MAX_TOKENS="$GEMMA_MAX_TOKENS";     OUTPUT_MAX_BYTES="$GEMMA_OUTPUT_MAX_BYTES" ;;
  devstral)          MAX_TOKENS="$DEVSTRAL_MAX_TOKENS";  OUTPUT_MAX_BYTES="$DEVSTRAL_OUTPUT_MAX_BYTES" ;;
  *)                 MAX_TOKENS="$MODEL_MAX_TOKENS_DEFAULT"; OUTPUT_MAX_BYTES="$MODEL_OUTPUT_MAX_BYTES_DEFAULT" ;;
esac

TMP_RESPONSE="${OUTPUT_FILE}.raw.json"
PAYLOAD_FILE="$(mktemp "${TMPDIR:-/tmp}/llm-pipeline-payload.XXXXXX.json")"
trap 'rm -f "$PAYLOAD_FILE"' EXIT

# Do not pass prompt contents through argv. Large repo prompts can exceed ARG_MAX
# if they are passed via jq --arg or curl -d "$PAYLOAD".
jq -n \
  --argjson max_tokens "$MAX_TOKENS" \
  --rawfile sys "$SYSTEM_FILE" \
  --rawfile usr "$USER_FILE" \
  '{
    model: "local",
    temperature: 0.0,
    top_p: 0.8,
    repeat_penalty: 1.12,
    max_tokens: $max_tokens,
    messages: [
      {role: "system", content: $sys},
      {role: "user", content: $usr}
    ]
  }' > "$PAYLOAD_FILE"

HTTP_CODE="$(curl -sS \
  --max-time "$MODEL_ASK_TIMEOUT_SECONDS" \
  -o "$TMP_RESPONSE" \
  -w '%{http_code}' \
  "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  --data-binary "@$PAYLOAD_FILE")" || {
    echo "ERROR: curl transport failed for role $ROLE on port $PORT" >&2
    [ -s "$TMP_RESPONSE" ] && {
      echo "ERROR: raw response kept at $TMP_RESPONSE" >&2
      head -c 4000 "$TMP_RESPONSE" >&2
      echo >&2
    }
    exit 1
  }

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "ERROR: model server returned HTTP $HTTP_CODE for role $ROLE on port $PORT" >&2
  echo "ERROR: raw response kept at $TMP_RESPONSE" >&2
  if [ -s "$TMP_RESPONSE" ]; then
    head -c 4000 "$TMP_RESPONSE" >&2
    echo >&2
  fi
  exit 1
fi

# Fail if any object in the response contains reasoning_content. The old jq
# expression could miss this because jq -e uses the last produced boolean.
if jq -e 'any(.. | objects; has("reasoning_content"))' "$TMP_RESPONSE" >/dev/null 2>&1; then
  echo "ERROR: response contains reasoning_content; reasoning/thinking is not disabled" >&2
  echo "ERROR: raw response kept at $TMP_RESPONSE" >&2
  exit 1
fi

jq -r '.choices[0].message.content // empty' "$TMP_RESPONSE" > "$OUTPUT_FILE"

if [ ! -s "$OUTPUT_FILE" ]; then
  echo "ERROR: empty model content. Raw response kept at $TMP_RESPONSE" >&2
  exit 1
fi

BYTES="$(wc -c < "$OUTPUT_FILE" | tr -d ' ')"
if [ "$BYTES" -gt "$OUTPUT_MAX_BYTES" ]; then
  echo "ERROR: model output too large for role $ROLE: ${BYTES} bytes > ${OUTPUT_MAX_BYTES} bytes" >&2
  echo "ERROR: raw response kept at $TMP_RESPONSE" >&2
  exit 1
fi

# Catch common local-model failure mode: one line/sentence repeated many times.
# This is intentionally simple and conservative; legitimate reports should not
# contain the exact same non-empty line more than eight times.
if awk 'NF { count[$0]++ } END { for (line in count) if (count[line] > 8) { print count[line] "x " line; exit 1 } }' "$OUTPUT_FILE" > "${OUTPUT_FILE}.repeat-check"; then
  rm -f "${OUTPUT_FILE}.repeat-check"
else
  echo "ERROR: repeated output detected for role $ROLE" >&2
  cat "${OUTPUT_FILE}.repeat-check" >&2 || true
  echo "ERROR: raw response kept at $TMP_RESPONSE" >&2
  rm -f "${OUTPUT_FILE}.repeat-check"
  exit 1
fi

LINES="$(wc -l < "$OUTPUT_FILE" | tr -d ' ')"
echo "INFO: wrote $OUTPUT_FILE ($LINES lines, $BYTES bytes, max_tokens=$MAX_TOKENS)"

# Raw responses are useful on failures, but keeping successful raw JSON files
# doubles log noise and exposes huge model internals when users cat run dirs.
rm -f "$TMP_RESPONSE"
