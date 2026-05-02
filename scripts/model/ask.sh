#!/usr/bin/env bash
set -euo pipefail

PORT="${1:?Usage: ask.sh <port> <system-file> <user-file> <output-file>}"
SYSTEM_FILE="${2:?}"
USER_FILE="${3:?}"
OUTPUT_FILE="${4:?}"

[ -f "$SYSTEM_FILE" ] || { echo "ERROR: system prompt not found: $SYSTEM_FILE" >&2; exit 1; }
[ -f "$USER_FILE" ] || { echo "ERROR: user prompt not found: $USER_FILE" >&2; exit 1; }

TMP_RESPONSE="${OUTPUT_FILE}.raw.json"
PAYLOAD_FILE="$(mktemp "${TMPDIR:-/tmp}/llm-pipeline-payload.XXXXXX.json")"
trap 'rm -f "$PAYLOAD_FILE"' EXIT

# Do not pass prompt contents through argv. Large repo prompts can exceed ARG_MAX
# if they are passed via jq --arg or curl -d "$PAYLOAD".
jq -n \
  --rawfile sys "$SYSTEM_FILE" \
  --rawfile usr "$USER_FILE" \
  '{
    model: "local",
    temperature: 0.0,
    max_tokens: 8192,
    messages: [
      {role: "system", content: $sys},
      {role: "user", content: $usr}
    ]
  }' > "$PAYLOAD_FILE"

curl -sf \
  --max-time 900 \
  "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  --data-binary "@$PAYLOAD_FILE" \
  > "$TMP_RESPONSE" || {
    echo "ERROR: curl failed for port $PORT" >&2
    exit 1
  }

if jq -e '.. | objects | has("reasoning_content")' "$TMP_RESPONSE" >/dev/null 2>&1; then
  echo "ERROR: response contains reasoning_content; reasoning/thinking is not disabled" >&2
  echo "ERROR: raw response kept at $TMP_RESPONSE" >&2
  exit 1
fi

jq -r '.choices[0].message.content // empty' "$TMP_RESPONSE" > "$OUTPUT_FILE"

if [ ! -s "$OUTPUT_FILE" ]; then
  echo "ERROR: empty model content. Raw response kept at $TMP_RESPONSE" >&2
  exit 1
fi

LINES="$(wc -l < "$OUTPUT_FILE" | tr -d ' ')"
echo "INFO: wrote $OUTPUT_FILE ($LINES lines)"
