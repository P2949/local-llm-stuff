#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 12-second-opinion.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
if [ -n "${PROJECT_PROFILE_FILE:-}" ] && [ -f "$PROJECT_PROFILE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$PROJECT_PROFILE_FILE"
fi
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 12: Second Opinion ==="

USER_PROMPT_FILE="/tmp/llm-pipeline-second-opinion-user-$RUN_ID.md"
cleanup() { rm -f "$USER_PROMPT_FILE"; }
trap cleanup EXIT INT TERM

source_diff() {
  if [ -d "${WORKTREE_PATH:-}" ]; then
    (
      cd "$WORKTREE_PATH"
      git diff -- src tests stutter stutter-common stutter-ebpf 2>/dev/null || git diff -- . ':!target' ':!build' ':!debug' ':!release' 2>/dev/null || true
    )
  else
    awk '
      /^diff --git a\/target\// { skip=1 }
      /^diff --git / && $0 !~ /^diff --git a\/target\// { skip=0 }
      !skip { print }
    ' "$RUN_DIR/06-diff.patch"
  fi
}

harness_summary_without_build_artifacts() {
  awk '
    /^## Diff summary/ { print; print "(diff summary omitted here; source diff is provided separately)"; exit }
    { print }
  ' "$RUN_DIR/05-agent-result.md"
}

{
  echo "# Pipeline policy"
  cat "$RUN_DIR/00-policy.md"
  echo
  if [ -n "${PROJECT_REVIEW_ADDENDUM:-}" ] && [ -f "$PROJECT_REVIEW_ADDENDUM" ]; then
    echo "# Project-specific review addendum"
    cat "$PROJECT_REVIEW_ADDENDUM"
    echo
  fi
  echo "# Accepted items"
  truncate_file "$RUN_DIR/03-accepted-issues.md" 24000
  echo
  echo "# Patch prompt"
  truncate_file "$RUN_DIR/04-patch-prompt.md" 24000
  echo
  echo "# Harness result"
  harness_summary_without_build_artifacts
  echo
  echo "# Policy checks"
  cat "$RUN_DIR/06-no-agent-commits.txt" 2>/dev/null || true
  cat "$RUN_DIR/06-allowed-files.txt" 2>/dev/null || true
  cat "$RUN_DIR/06-patch-size.txt" 2>/dev/null || true
  cat "$RUN_DIR/06-feature-tests.txt" 2>/dev/null || true
  echo
  echo "# Source diff only"
  source_diff | head -c "$CONTEXT_MAX_DIFF_BYTES"
  echo
  echo "# Primary review"
  truncate_file "$RUN_DIR/07-review.md" 24000 2>/dev/null || true
  echo
  echo "Give independent second opinion with AGREE, DISAGREE, or BLOCK. Block on any policy violation."
} > "$USER_PROMPT_FILE"

bash "$PIPELINE_DIR/scripts/model/run.sh" gemma "$GEMMA_PORT" "$PIPELINE_DIR/prompts/second-opinion.md" "$USER_PROMPT_FILE" "$RUN_DIR/08-second-opinion.md"

trap - EXIT INT TERM
cleanup

echo "INFO: second opinion -> $RUN_DIR/08-second-opinion.md"
