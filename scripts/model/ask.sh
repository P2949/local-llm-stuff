#!/usr/bin/env bash
set -euo pipefail

PORT="${1:?Usage: ask.sh <port> <system-file> <user-file> <output-file>}"
SYSTEM_FILE="${2:?}"
USER_FILE="${3:?}"
OUTPUT_FILE="${4:?}"

[ -f "$SYSTEM_FILE" ] || { echo "ERROR: system prompt not found: $SYSTEM_FILE" >&2; exit 1; }
[ -f "$USER_FILE" ] || { echo "ERROR: user prompt not found: $USER_FILE" >&2; exit 1; }

SYSTEM_PROMPT="$(cat "$SYSTEM_FILE")"
USER_PROMPT="$(cat "$USER_FILE")"
TMP_RESPONSE="${OUTPUT_FILE}.raw.json"

PAYLOAD="$(jq -n \
  --arg sys "$SYSTEM_PROMPT" \
  --arg usr "$USER_PROMPT" \
  '{
    model: "local",
    temperature: 0.0,
    max_tokens: 8192,
    messages: [
      {role: "system", content: $sys},
      {role: "user", content: $usr}
    ]
  }')"

curl -sf \
  --max-time 900 \
  "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
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
