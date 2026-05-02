#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:?Usage: run.sh <role> <port> <system-file> <user-file> <output-file>}"
PORT="${2:?}"
SYSTEM_FILE="${3:?}"
USER_FILE="${4:?}"
OUTPUT_FILE="${5:?}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cleanup() {
  bash "$SCRIPT_DIR/stop.sh" "$ROLE" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

bash "$SCRIPT_DIR/start.sh" "$ROLE"
bash "$SCRIPT_DIR/ask.sh" "$PORT" "$SYSTEM_FILE" "$USER_FILE" "$OUTPUT_FILE"

trap - EXIT INT TERM
cleanup
