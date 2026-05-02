#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 02-challenge.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 2: Challenge ==="

USER_PROMPT_FILE="/tmp/llm-pipeline-challenge-user-$RUN_ID.md"
SYSTEM_PROMPT="$PIPELINE_DIR/prompts/challenge.md"
if [ "${TASK_MODE:-fix}" = "feature" ]; then
  SYSTEM_PROMPT="$PIPELINE_DIR/prompts/challenge-feature.md"
fi

SHADOW_SECTION=""
if [ -f "$RUN_DIR/01b-finder-second-opinion.md" ]; then
  SHADOW_SECTION="# Shadow finder report
$(cat "$RUN_DIR/01b-finder-second-opinion.md")"
fi

{
  echo "# Task"
  cat "$RUN_DIR/00-task.md"
  echo
  echo "# Primary finder report"
  cat "$RUN_DIR/01-finder.md"
  echo
  printf '%s\n' "$SHADOW_SECTION"
  echo
  echo "# Repository map"
  cat "$RUN_DIR/00-repo-map.md"
  echo
  echo "# Source context"
  pack_repo_sources "$TARGET_REPO" "$CONTEXT_MAX_SOURCE_FILES" "$CONTEXT_MAX_SOURCE_BYTES"
  echo
  echo "Attack every issue or implementation item. Output required Decision lines."
} > "$USER_PROMPT_FILE"

"$PIPELINE_DIR/scripts/model/start.sh" qwen35b
"$PIPELINE_DIR/scripts/model/ask.sh" "$QWEN35B_PORT" "$SYSTEM_PROMPT" "$USER_PROMPT_FILE" "$RUN_DIR/02-challenge.md"
"$PIPELINE_DIR/scripts/model/stop.sh" qwen35b
rm -f "$USER_PROMPT_FILE"

echo "INFO: challenge complete -> $RUN_DIR/02-challenge.md"
