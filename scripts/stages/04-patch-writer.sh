#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 04-patch-writer.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
if [ -n "${PROJECT_PROFILE_FILE:-}" ] && [ -f "$PROJECT_PROFILE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$PROJECT_PROFILE_FILE"
fi
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 4: Patch Writer ==="

USER_PROMPT_FILE="/tmp/llm-pipeline-patchwriter-user-$RUN_ID.md"
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
  echo "# Accepted items to implement/fix"
  cat "$RUN_DIR/03-accepted-issues.md"
  echo
  echo "# Full challenge report"
  cat "$RUN_DIR/02-challenge.md"
  echo
  echo "# Repository map"
  cat "$RUN_DIR/00-repo-map.md"
  echo
  echo "# Project-prioritized source context"
  pack_project_context_packs "$TARGET_REPO" "$RUN_DIR/00-task.md" "$CONTEXT_MAX_SOURCE_BYTES"
  echo
  echo "# Generic source context"
  pack_repo_sources "$TARGET_REPO" "$CONTEXT_MAX_SOURCE_FILES" "$CONTEXT_MAX_SOURCE_BYTES"
  echo
  echo "Write the precise patch prompt for the editor. The Allowed files section is mandatory and is machine-enforced."
} > "$USER_PROMPT_FILE"

"$PIPELINE_DIR/scripts/model/run.sh" qwen27b "$QWEN27B_PORT" "$PIPELINE_DIR/prompts/patch-writer.md" "$USER_PROMPT_FILE" "$RUN_DIR/04-patch-prompt.md"

trap - EXIT INT TERM
cleanup

echo "INFO: patch prompt -> $RUN_DIR/04-patch-prompt.md"
