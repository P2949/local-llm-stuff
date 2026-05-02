#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 00-baseline.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/pipeline.env"
source "$PIPELINE_DIR/scripts/lib/policy.sh"
if [ -n "${PROJECT_PROFILE_FILE:-}" ] && [ -f "$PROJECT_PROFILE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$PROJECT_PROFILE_FILE"
fi
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 0: Baseline ==="
cd "$TARGET_REPO"
write_context_manifest "$RUN_DIR" "$TARGET_REPO"
policy_write_manifest "$RUN_DIR"

{
  echo "# Baseline Snapshot"
  echo
  echo "- Run: $RUN_ID"
  echo "- Mode: $TASK_MODE"
  echo "- Project profile: ${PROJECT_PROFILE_NAME:-generic}"
  echo "- Date: $(date -Iseconds)"
  echo "- Commit: $(git rev-parse HEAD)"
  echo "- Branch: $(git branch --show-current)"
  echo "- Toolchain env: $(policy_toolchain_env | tr '\n' ' ' || true)"
  echo
  echo "## Dirty files before run"
  git status --short || true
  echo
} > "$RUN_DIR/00-baseline.md"

run_check() {
  local label="$1"; shift
  local outfile="$1"; shift
  local command_text="$*"
  if policy_run_shell_cmd "$label" "$outfile" record "$command_text"; then
    echo "- $label: PASS" >> "$RUN_DIR/00-baseline.md"
  else
    echo "- $label: FAIL (pre-existing, recorded)" >> "$RUN_DIR/00-baseline.md"
  fi
}

run_check "fmt" "$RUN_DIR/00-baseline-fmt.txt" "${VERIFY_FMT_CMD:-cargo fmt --check}"
run_check "build" "$RUN_DIR/00-baseline-build.txt" "${VERIFY_BUILD_CMD:-cargo build}"
run_check "clippy" "$RUN_DIR/00-baseline-clippy.txt" "${VERIFY_CLIPPY_CMD:-cargo clippy --all-targets -- -D warnings}"
run_check "test" "$RUN_DIR/00-baseline-test.txt" "${VERIFY_TEST_CMD:-cargo test}"
run_check "workspace test" "$RUN_DIR/00-baseline-workspace-test.txt" "${VERIFY_WORKSPACE_TEST_CMD:-cargo test --workspace}"

echo "INFO: baseline complete -> $RUN_DIR/00-baseline.md"
