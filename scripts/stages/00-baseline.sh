#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 00-baseline.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 0: Baseline ==="
cd "$TARGET_REPO"
write_context_manifest "$RUN_DIR" "$TARGET_REPO"

{
  echo "# Baseline Snapshot"
  echo
  echo "- Run: $RUN_ID"
  echo "- Mode: $TASK_MODE"
  echo "- Date: $(date -Iseconds)"
  echo "- Commit: $(git rev-parse HEAD)"
  echo "- Branch: $(git branch --show-current)"
  echo
  echo "## Dirty files before run"
  git status --short || true
  echo
} > "$RUN_DIR/00-baseline.md"

run_check() {
  local label="$1"; shift
  local outfile="$1"; shift
  if "$@" > "$outfile" 2>&1; then
    echo "- $label: PASS" >> "$RUN_DIR/00-baseline.md"
  else
    echo "- $label: FAIL (pre-existing, recorded)" >> "$RUN_DIR/00-baseline.md"
  fi
}

run_check "cargo fmt --check" "$RUN_DIR/00-baseline-fmt.txt" cargo fmt --check
run_check "cargo clippy --all-targets -- -D warnings" "$RUN_DIR/00-baseline-clippy.txt" cargo clippy --all-targets -- -D warnings
run_check "cargo test" "$RUN_DIR/00-baseline-test.txt" cargo test

echo "INFO: baseline complete -> $RUN_DIR/00-baseline.md"
