#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 01-finder.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
if [ -n "${PROJECT_PROFILE_FILE:-}" ] && [ -f "$PROJECT_PROFILE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$PROJECT_PROFILE_FILE"
fi
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 1: Finder ==="

USER_PROMPT_FILE="/tmp/llm-pipeline-finder-user-$RUN_ID.md"
cleanup() { rm -f "$USER_PROMPT_FILE"; }
trap cleanup EXIT INT TERM

SYSTEM_PROMPT="$PIPELINE_DIR/prompts/finder.md"
if [ "${TASK_MODE:-fix}" = "feature" ]; then
  SYSTEM_PROMPT="$PIPELINE_DIR/prompts/finder-feature.md"
fi

{
  echo "# Task"
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
  echo "# Baseline status"
  cat "$RUN_DIR/00-baseline.md"
  echo
  echo "# Repository map"
  truncate_file "$RUN_DIR/00-repo-map.md" "${CONTEXT_MAX_REPO_MAP_BYTES:-8000}"
  echo
  echo "# Exact required source snippets"
  pack_required_source_context "$TARGET_REPO" "$RUN_DIR/00-task.md" "${CONTEXT_REQUIRED_SOURCE_CONTEXT_LINES:-8}"
  echo
  echo "# Baseline build output"
  truncate_file "$RUN_DIR/00-baseline-build.txt" "${CONTEXT_MAX_COMMAND_BYTES:-4000}"
  echo
  echo "# Baseline clippy output"
  truncate_file "$RUN_DIR/00-baseline-clippy.txt" "${CONTEXT_MAX_COMMAND_BYTES:-4000}"
  echo
  echo "# Baseline test output"
  truncate_file "$RUN_DIR/00-baseline-test.txt" "${CONTEXT_MAX_COMMAND_BYTES:-4000}"
  echo
  echo "# Project-prioritized source context"
  pack_project_context_packs "$TARGET_REPO" "$RUN_DIR/00-task.md" "$CONTEXT_MAX_SOURCE_BYTES"
  echo
  echo "# Generic source context"
  pack_repo_sources "$TARGET_REPO" "$CONTEXT_MAX_SOURCE_FILES" "$CONTEXT_MAX_SOURCE_BYTES"
  echo
  echo "Now produce the required finder report. In review mode, produce findings only; no edits will be made."
} > "$USER_PROMPT_FILE"

bash "$PIPELINE_DIR/scripts/model/run.sh" qwen27b "$QWEN27B_PORT" "$SYSTEM_PROMPT" "$USER_PROMPT_FILE" "$RUN_DIR/01-finder.md"

trap - EXIT INT TERM
cleanup

echo "INFO: finder complete -> $RUN_DIR/01-finder.md"
