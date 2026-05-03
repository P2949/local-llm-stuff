#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 07-review.sh <run-dir> [prompt-file]}"
PROMPT_FILE="${2:-$RUN_DIR/04-patch-prompt.md}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
if [ -n "${PROJECT_PROFILE_FILE:-}" ] && [ -f "$PROJECT_PROFILE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$PROJECT_PROFILE_FILE"
fi
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 7: Final Review ==="

USER_PROMPT_FILE="/tmp/llm-pipeline-review-user-$RUN_ID.md"
cleanup() { rm -f "$USER_PROMPT_FILE"; }
trap cleanup EXIT INT TERM

{
  echo "# Original task"
  cat "$RUN_DIR/00-task.md"
  echo
  echo "# Pipeline policy"
  cat "$RUN_DIR/00-policy.md"
  echo
  if [ -n "${PROJECT_REVIEW_ADDENDUM:-}" ] && [ -f "$PROJECT_REVIEW_ADDENDUM" ]; then
    echo "# Project-specific review addendum"
    cat "$PROJECT_REVIEW_ADDENDUM"
    echo
  fi
  echo "# Accepted items"
  cat "$RUN_DIR/03-accepted-issues.md"
  echo
  echo "# Patch prompt given to the editor"
  cat "$PROMPT_FILE"
  echo
  echo "# Agent result written by harness"
  cat "$RUN_DIR/05-agent-result.md"
  echo
  echo "# Quality scorecard"
  cat "$RUN_DIR/06-quality-scorecard.md" 2>/dev/null || true
  echo
  echo "# Policy check outputs"
  cat "$RUN_DIR/06-no-agent-commits.txt" 2>/dev/null || true
  cat "$RUN_DIR/06-allowed-files.txt" 2>/dev/null || true
  cat "$RUN_DIR/06-patch-size.txt" 2>/dev/null || true
  cat "$RUN_DIR/06-feature-tests.txt" 2>/dev/null || true
  echo
  echo "# Optional quality output"
  cat "$RUN_DIR/06-optional-quality.md" 2>/dev/null || true
  echo
  echo "# Diff stat"
  cat "$RUN_DIR/06-diff-stat.txt"
  echo
  echo "# Final diff"
  truncate_file "$RUN_DIR/06-diff.patch" "$CONTEXT_MAX_DIFF_BYTES"
  echo
  echo "# Build output"
  tail -"$CONTEXT_MAX_COMMAND_LINES" "$RUN_DIR/06-build.txt"
  echo
  echo "# Clippy output"
  tail -"$CONTEXT_MAX_COMMAND_LINES" "$RUN_DIR/06-clippy.txt"
  echo
  echo "# Test output"
  tail -"$CONTEXT_MAX_COMMAND_LINES" "$RUN_DIR/06-test.txt"
  echo
  echo "# Workspace test output"
  tail -"$CONTEXT_MAX_COMMAND_LINES" "$RUN_DIR/06-workspace-test.txt"
  echo
  echo "# Touched file context"
  pack_touched_files "$WORKTREE_PATH" "$RUN_DIR/06-diff.patch" "$CONTEXT_MAX_SOURCE_BYTES"
  echo
  echo "Review the patch. Output the required verdict format. APPROVE only means ready for human inspection."
} > "$USER_PROMPT_FILE"

"$PIPELINE_DIR/scripts/model/run.sh" qwen27b "$QWEN27B_PORT" "$PIPELINE_DIR/prompts/review.md" "$USER_PROMPT_FILE" "$RUN_DIR/07-review.md"

trap - EXIT INT TERM
cleanup

echo "INFO: review complete -> $RUN_DIR/07-review.md"
