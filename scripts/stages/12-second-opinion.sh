#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 12-second-opinion.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 12: Second Opinion ==="

USER_PROMPT_FILE="/tmp/llm-pipeline-second-opinion-user-$RUN_ID.md"
cleanup() { rm -f "$USER_PROMPT_FILE"; }
trap cleanup EXIT INT TERM

{
  echo "# Accepted items"
  cat "$RUN_DIR/03-accepted-issues.md"
  echo
  echo "# Patch prompt"
  cat "$RUN_DIR/04-patch-prompt.md"
  echo
  echo "# Harness result"
  cat "$RUN_DIR/05-agent-result.md"
  echo
  echo "# Final diff"
  truncate_file "$RUN_DIR/06-diff.patch" "$CONTEXT_MAX_DIFF_BYTES"
  echo
  echo "# Primary review"
  cat "$RUN_DIR/07-review.md" 2>/dev/null || true
  echo
  echo "Give independent second opinion with AGREE, DISAGREE, or BLOCK."
} > "$USER_PROMPT_FILE"

"$PIPELINE_DIR/scripts/model/run.sh" gemma "$GEMMA_PORT" "$PIPELINE_DIR/prompts/second-opinion.md" "$USER_PROMPT_FILE" "$RUN_DIR/08-second-opinion.md"

trap - EXIT INT TERM
cleanup

echo "INFO: second opinion -> $RUN_DIR/08-second-opinion.md"
