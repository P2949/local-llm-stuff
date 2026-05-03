#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 02b-gemma-challenge.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
if [ -n "${PROJECT_PROFILE_FILE:-}" ] && [ -f "$PROJECT_PROFILE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$PROJECT_PROFILE_FILE"
fi
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 2b: Gemma Challenge ==="

USER_PROMPT_FILE="/tmp/llm-pipeline-gemma-challenge-user-$RUN_ID.md"
cleanup() { rm -f "$USER_PROMPT_FILE"; }
trap cleanup EXIT INT TERM

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
  echo "# Pipeline policy"
  cat "$RUN_DIR/00-policy.md"
  echo
  if [ -n "${PROJECT_REVIEW_ADDENDUM:-}" ] && [ -f "$PROJECT_REVIEW_ADDENDUM" ]; then
    echo "# Project-specific review addendum"
    cat "$PROJECT_REVIEW_ADDENDUM"
    echo
  fi
  echo "# Primary finder report"
  cat "$RUN_DIR/01-finder.md"
  echo
  printf '%s\n' "$SHADOW_SECTION"
  echo
  echo "# Repository map"
  truncate_file "$RUN_DIR/00-repo-map.md" "${CONTEXT_MAX_REPO_MAP_BYTES:-8000}"
  echo
  echo "# Exact required source snippets"
  pack_required_source_context "$TARGET_REPO" "$RUN_DIR/00-task.md" "${CONTEXT_REQUIRED_SOURCE_CONTEXT_LINES:-8}"
  echo
  echo "# Project-prioritized source context"
  pack_project_context_packs "$TARGET_REPO" "$RUN_DIR/00-task.md" "$CONTEXT_MAX_SOURCE_BYTES"
  echo
  echo "# Generic source context"
  pack_repo_sources "$TARGET_REPO" "$CONTEXT_MAX_SOURCE_FILES" "$CONTEXT_MAX_SOURCE_BYTES"
  echo
  echo "You are the independent Gemma consensus challenger. Do not defer to Qwen's challenge result; judge every finder item from the supplied task, policy, and source evidence."
  echo "Attack every issue or implementation item. Output required Decision lines. Reject anything unsupported by evidence or outside policy scope."
} > "$USER_PROMPT_FILE"

"$PIPELINE_DIR/scripts/model/run.sh" gemma "$GEMMA_PORT" "$SYSTEM_PROMPT" "$USER_PROMPT_FILE" "$RUN_DIR/02b-challenge-gemma.md"

trap - EXIT INT TERM
cleanup

echo "INFO: Gemma challenge complete -> $RUN_DIR/02b-challenge-gemma.md"
