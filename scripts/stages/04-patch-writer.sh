#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 04-patch-writer.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 4: Patch Writer ==="

USER_PROMPT_FILE="/tmp/llm-pipeline-patchwriter-user-$RUN_ID.md"

{
  echo "# Original task"
  cat "$RUN_DIR/00-task.md"
  echo
  echo "# Accepted items to implement/fix"
  cat "$RUN_DIR/03-accepted-issues.md"
  echo
  echo "# Full challenge report"
  cat "$RUN_DIR/02-challenge.md"
  echo
  echo "# Repository map"
  cat "$RUN_DIR/00-repo-map.md"
  echo
  echo "# Source context"
  pack_repo_sources "$TARGET_REPO" "$CONTEXT_MAX_SOURCE_FILES" "$CONTEXT_MAX_SOURCE_BYTES"
  echo
  echo "Write the precise patch prompt for the editor."
} > "$USER_PROMPT_FILE"

"$PIPELINE_DIR/scripts/model/start.sh" qwen27b
"$PIPELINE_DIR/scripts/model/ask.sh" "$QWEN27B_PORT" "$PIPELINE_DIR/prompts/patch-writer.md" "$USER_PROMPT_FILE" "$RUN_DIR/04-patch-prompt.md"
"$PIPELINE_DIR/scripts/model/stop.sh" qwen27b
rm -f "$USER_PROMPT_FILE"

echo "INFO: patch prompt -> $RUN_DIR/04-patch-prompt.md"
