#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 07-review.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 7: Final Review ==="

USER_PROMPT_FILE="/tmp/llm-pipeline-review-user-$RUN_ID.md"
cleanup() { rm -f "$USER_PROMPT_FILE"; }
trap cleanup EXIT INT TERM

{
  echo "# Original task"
  cat "$RUN_DIR/00-task.md"
  echo
  echo "# Accepted items"
  cat "$RUN_DIR/03-accepted-issues.md"
  echo
  echo "# Patch prompt given to the editor"
  if [ -f "$RUN_DIR/04-revision-prompt-${ITERATION}.md" ]; then
    cat "$RUN_DIR/04-revision-prompt-${ITERATION}.md"
  else
    cat "$RUN_DIR/04-patch-prompt.md"
  fi
  echo
  echo "# Agent result written by harness"
  cat "$RUN_DIR/05-agent-result.md"
  echo
  echo "# Diff stat"
  cat "$RUN_DIR/06-diff-stat.txt"
  echo
  echo "# Final diff"
  truncate_file "$RUN_DIR/06-diff.patch" "$CONTEXT_MAX_DIFF_BYTES"
  echo
  echo "# Clippy output"
  tail -"$CONTEXT_MAX_COMMAND_LINES" "$RUN_DIR/06-clippy.txt"
  echo
  echo "# Test output"
  tail -"$CONTEXT_MAX_COMMAND_LINES" "$RUN_DIR/06-test.txt"
  echo
  echo "# Touched file context"
  pack_touched_files "$WORKTREE_PATH" "$RUN_DIR/06-diff.patch" "$CONTEXT_MAX_SOURCE_BYTES"
  echo
  echo "Review the patch. Output the required verdict format."
} > "$USER_PROMPT_FILE"

"$PIPELINE_DIR/scripts/model/run.sh" qwen27b "$QWEN27B_PORT" "$PIPELINE_DIR/prompts/review.md" "$USER_PROMPT_FILE" "$RUN_DIR/07-review.md"

trap - EXIT INT TERM
cleanup

echo "INFO: review complete -> $RUN_DIR/07-review.md"
