#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 01b-shadow-finder.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 1b: Shadow Finder ==="

USER_PROMPT_FILE="/tmp/llm-pipeline-shadow-finder-user-$RUN_ID.md"
SYSTEM_PROMPT="$PIPELINE_DIR/prompts/finder.md"
if [ "${TASK_MODE:-fix}" = "feature" ]; then
  SYSTEM_PROMPT="$PIPELINE_DIR/prompts/finder-feature.md"
fi

{
  echo "# Task"
  cat "$RUN_DIR/00-task.md"
  echo
  echo "# Baseline status"
  cat "$RUN_DIR/00-baseline.md"
  echo
  echo "# Repository map"
  cat "$RUN_DIR/00-repo-map.md"
  echo
  echo "# Primary finder report"
  cat "$RUN_DIR/01-finder.md"
  echo
  echo "# Source context"
  pack_repo_sources "$TARGET_REPO" "$CONTEXT_MAX_SOURCE_FILES" "$CONTEXT_MAX_SOURCE_BYTES"
  echo
  echo "Perform an independent second pass. You may agree, disagree, or add supported items."
} > "$USER_PROMPT_FILE"

"$PIPELINE_DIR/scripts/model/start.sh" gemma
"$PIPELINE_DIR/scripts/model/ask.sh" "$GEMMA_PORT" "$SYSTEM_PROMPT" "$USER_PROMPT_FILE" "$RUN_DIR/01b-finder-second-opinion.md"
"$PIPELINE_DIR/scripts/model/stop.sh" gemma
rm -f "$USER_PROMPT_FILE"

echo "INFO: shadow finder complete -> $RUN_DIR/01b-finder-second-opinion.md"
