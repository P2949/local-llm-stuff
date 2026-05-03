#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 08-revision-writer.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
if [ -n "${PROJECT_PROFILE_FILE:-}" ] && [ -f "$PROJECT_PROFILE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$PROJECT_PROFILE_FILE"
fi
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 8: Revision Writer ==="

OUTPUT_FILE="$RUN_DIR/04-revision-prompt-${ITERATION}.md"
USER_PROMPT_FILE="/tmp/llm-pipeline-revision-user-$RUN_ID.md"
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
  echo "# Accepted items (authoritative)"
  cat "$RUN_DIR/03-accepted-issues.md"
  echo
  echo "# Original patch prompt"
  cat "$RUN_DIR/04-patch-prompt.md"
  echo
  echo "# Harness verification result"
  cat "$RUN_DIR/05-agent-result.md" 2>/dev/null || true
  echo
  echo "# Policy checks"
  cat "$RUN_DIR/06-no-agent-commits.txt" 2>/dev/null || true
  cat "$RUN_DIR/06-allowed-files.txt" 2>/dev/null || true
  cat "$RUN_DIR/06-patch-size.txt" 2>/dev/null || true
  cat "$RUN_DIR/06-feature-tests.txt" 2>/dev/null || true
  echo
  echo "# Diff reviewed"
  truncate_file "$RUN_DIR/06-diff.patch" "${CONTEXT_MAX_DIFF_BYTES:-60000}"
  echo
  echo "# Review output"
  cat "$RUN_DIR/07-review.md" 2>/dev/null || echo "(no review; verification was BLOCKED)"
  echo
  echo "# Build output"
  tail -"$CONTEXT_MAX_COMMAND_LINES" "$RUN_DIR/06-build.txt" 2>/dev/null || true
  echo
  echo "# Clippy output"
  tail -"$CONTEXT_MAX_COMMAND_LINES" "$RUN_DIR/06-clippy.txt" 2>/dev/null || true
  echo
  echo "# Test output"
  tail -"$CONTEXT_MAX_COMMAND_LINES" "$RUN_DIR/06-test.txt" 2>/dev/null || true
  echo
  echo "Write a narrow revision prompt. Do not broaden scope. Preserve or narrow Allowed files."
} > "$USER_PROMPT_FILE"

"$PIPELINE_DIR/scripts/model/run.sh" qwen27b "$QWEN27B_PORT" "$PIPELINE_DIR/prompts/patch-writer-revision.md" "$USER_PROMPT_FILE" "$OUTPUT_FILE"

trap - EXIT INT TERM
cleanup

echo "INFO: revision prompt -> $OUTPUT_FILE"
