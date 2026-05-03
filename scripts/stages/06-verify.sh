#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 06-verify.sh <run-dir> [prompt-file]}"
PROMPT_FILE="${2:-$RUN_DIR/04-patch-prompt.md}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/pipeline.env"
source "$PIPELINE_DIR/scripts/lib/policy.sh"
if [ -n "${PROJECT_PROFILE_FILE:-}" ] && [ -f "$PROJECT_PROFILE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$PROJECT_PROFILE_FILE"
fi

echo "=== Stage 6: External Verification ==="
cd "$WORKTREE_PATH"

FMT_AUTOFIXED="no"
FINAL_STATUS="READY_FOR_REVIEW"
FMT1_STATUS=0
FMT2_STATUS=0
BUILD_STATUS="not-run"
CLIPPY_STATUS="not-run"
TEST_STATUS="not-run"
WORKSPACE_TEST_STATUS="not-run"
OPTIONAL_STATUS="not-run"
POLICY_STATUS="pass"

# Formatter check with recorded fmt rescue only.
set +e
policy_run_shell_cmd "fmt check before rescue" "$RUN_DIR/06-fmt-check-1.txt" hard "${VERIFY_FMT_CMD:-cargo fmt --check}"
FMT1_STATUS=$?
set -e

if [ "$FMT1_STATUS" -ne 0 ]; then
  FMT_AUTOFIXED="yes"
  set +e
  policy_run_shell_cmd "fmt rescue" "$RUN_DIR/06-fmt-autofix.txt" hard "${VERIFY_FMT_RESCUE_CMD:-cargo fmt}"
  FMT_AUTOFIX_STATUS=$?
  set -e
  if [ "$FMT_AUTOFIX_STATUS" -ne 0 ]; then
    FINAL_STATUS="BLOCKED"
    FMT2_STATUS=1
    echo "BLOCKED: cargo fmt failed during harness rescue" > "$RUN_DIR/06-fmt-check-2.txt"
  else
    set +e
    policy_run_shell_cmd "fmt check after rescue" "$RUN_DIR/06-fmt-check-2.txt" hard "${VERIFY_FMT_CMD:-cargo fmt --check}"
    FMT2_STATUS=$?
    set -e
    [ "$FMT2_STATUS" -ne 0 ] && FINAL_STATUS="BLOCKED"
  fi
else
  cp "$RUN_DIR/06-fmt-check-1.txt" "$RUN_DIR/06-fmt-check-2.txt"
  FMT2_STATUS=0
fi

if [ "$FINAL_STATUS" != "BLOCKED" ]; then
  set +e
  policy_run_shell_cmd "build" "$RUN_DIR/06-build.txt" hard "${VERIFY_BUILD_CMD:-cargo build}"
  BUILD_STATUS=$?
  set -e
  [ "$BUILD_STATUS" -ne 0 ] && FINAL_STATUS="BLOCKED"
fi

if [ "$FINAL_STATUS" != "BLOCKED" ]; then
  set +e
  policy_run_shell_cmd "clippy" "$RUN_DIR/06-clippy.txt" hard "${VERIFY_CLIPPY_CMD:-cargo clippy --all-targets -- -D warnings}"
  CLIPPY_STATUS=$?
  set -e
  [ "$CLIPPY_STATUS" -ne 0 ] && FINAL_STATUS="BLOCKED"
fi

if [ "$FINAL_STATUS" != "BLOCKED" ]; then
  set +e
  policy_run_shell_cmd "test" "$RUN_DIR/06-test.txt" hard "${VERIFY_TEST_CMD:-cargo test}"
  TEST_STATUS=$?
  set -e
  [ "$TEST_STATUS" -ne 0 ] && FINAL_STATUS="BLOCKED"
fi

if [ "$FINAL_STATUS" != "BLOCKED" ]; then
  set +e
  policy_run_shell_cmd "workspace test" "$RUN_DIR/06-workspace-test.txt" hard "${VERIFY_WORKSPACE_TEST_CMD:-cargo test --workspace}"
  WORKSPACE_TEST_STATUS=$?
  set -e
  [ "$WORKSPACE_TEST_STATUS" -ne 0 ] && FINAL_STATUS="BLOCKED"
fi

# Ensure output files exist even when skipped.
[ -f "$RUN_DIR/06-build.txt" ] || echo "NOT RUN" > "$RUN_DIR/06-build.txt"
[ -f "$RUN_DIR/06-clippy.txt" ] || echo "NOT RUN" > "$RUN_DIR/06-clippy.txt"
[ -f "$RUN_DIR/06-test.txt" ] || echo "NOT RUN" > "$RUN_DIR/06-test.txt"
[ -f "$RUN_DIR/06-workspace-test.txt" ] || echo "NOT RUN" > "$RUN_DIR/06-workspace-test.txt"

git diff --stat > "$RUN_DIR/06-diff-stat.txt"
git diff > "$RUN_DIR/06-diff.patch"
CHANGED_FILES="$(git diff --name-only | tr '\n' ' ')"

# Policy checks that depend on the final diff.
if [ "$FINAL_STATUS" != "BLOCKED" ]; then
  if ! policy_check_no_agent_commits "$RUN_DIR"; then
    FINAL_STATUS="BLOCKED"
    POLICY_STATUS="fail"
  fi
fi
if [ "$FINAL_STATUS" != "BLOCKED" ]; then
  if ! policy_check_allowed_files "$RUN_DIR" "$PROMPT_FILE"; then
    FINAL_STATUS="BLOCKED"
    POLICY_STATUS="fail"
  fi
fi
if [ "$FINAL_STATUS" != "BLOCKED" ]; then
  if ! policy_check_patch_size "$RUN_DIR"; then
    FINAL_STATUS="BLOCKED"
    POLICY_STATUS="fail"
  fi
fi
if [ "$FINAL_STATUS" != "BLOCKED" ]; then
  if ! policy_check_feature_tests "$RUN_DIR"; then
    FINAL_STATUS="BLOCKED"
    POLICY_STATUS="fail"
  fi
fi

# Optional quality tools. These never run before hard gates pass.
OPTIONAL_OUT="$RUN_DIR/06-optional-quality.md"
{
  echo "# Optional Quality Tools"
  echo
} > "$OPTIONAL_OUT"
if [ "$FINAL_STATUS" != "BLOCKED" ]; then
  OPTIONAL_STATUS="pass"

  run_optional_tool() {
    local tool_name="$1"
    local mode="$2"
    local command_text="$3"
    local outfile="$RUN_DIR/06-optional-${tool_name}.txt"
    [ "$mode" = "off" ] && { echo "- $tool_name: SKIP (off)" >> "$OPTIONAL_OUT"; return 0; }
    local binary
    binary="$(echo "$command_text" | awk '{print $1}')"
    if ! command -v "$binary" >/dev/null 2>&1; then
      echo "- $tool_name: SKIP (missing $binary)" >> "$OPTIONAL_OUT"
      echo "SKIP: missing $binary" > "$outfile"
      return 0
    fi
    local status=0
    if policy_run_shell_cmd "$tool_name" "$outfile" "$mode" "$command_text"; then
      status=0
    else
      status=$?
    fi
    if [ "$status" -eq 0 ]; then
      echo "- $tool_name: PASS" >> "$OPTIONAL_OUT"
    elif [ "$mode" = "hard" ]; then
      echo "- $tool_name: FAIL (hard, status=$status)" >> "$OPTIONAL_OUT"
      FINAL_STATUS="BLOCKED"
      OPTIONAL_STATUS="fail"
    else
      echo "- $tool_name: WARN (status=$status)" >> "$OPTIONAL_OUT"
    fi
  }

  run_optional_tool "audit" "${CARGO_AUDIT_MODE:-warn}" "cargo audit"
  run_optional_tool "deny" "${CARGO_DENY_MODE:-warn}" "cargo deny check"
  run_optional_tool "machete" "${CARGO_MACHETE_MODE:-warn}" "cargo machete"
  run_optional_tool "llvm-cov" "${CARGO_LLVM_COV_MODE:-off}" "cargo llvm-cov --workspace --all-features --summary-only"
  run_optional_tool "mutants" "${CARGO_MUTANTS_MODE:-off}" "cargo mutants --no-shuffle --timeout 60"
fi

policy_quality_scorecard "$RUN_DIR" "$FINAL_STATUS"

fmt1_label="$([ "$FMT1_STATUS" -eq 0 ] && echo PASS || echo FAIL)"
fmt2_label="$([ "$FMT2_STATUS" -eq 0 ] && echo PASS || echo FAIL)"
build_label="NOT RUN"
if [ "$BUILD_STATUS" != "not-run" ]; then
  build_label="$([ "$BUILD_STATUS" -eq 0 ] && echo PASS || echo FAIL)"
fi
clippy_label="NOT RUN"
if [ "$CLIPPY_STATUS" != "not-run" ]; then
  clippy_label="$([ "$CLIPPY_STATUS" -eq 0 ] && echo PASS || echo FAIL)"
fi
test_label="NOT RUN"
if [ "$TEST_STATUS" != "not-run" ]; then
  test_label="$([ "$TEST_STATUS" -eq 0 ] && echo PASS || echo FAIL)"
fi
workspace_test_label="NOT RUN"
if [ "$WORKSPACE_TEST_STATUS" != "not-run" ]; then
  workspace_test_label="$([ "$WORKSPACE_TEST_STATUS" -eq 0 ] && echo PASS || echo FAIL)"
fi

cat > "$RUN_DIR/05-agent-result.md" << EOF_RESULT
# Agent Result

- Run: $RUN_ID
- Iteration: $ITERATION
- Final status: $FINAL_STATUS
- Editor model: $ACTIVE_EDITOR_MODEL
- Files changed: ${CHANGED_FILES:-"(none)"}
- Project profile: ${PROJECT_PROFILE_NAME:-generic}

## Verification result

| Check | Result |
|---|---|
| cargo fmt --check before harness | $fmt1_label |
| cargo fmt auto-corrected by harness | $FMT_AUTOFIXED |
| cargo fmt --check after harness | $fmt2_label |
| cargo build | $build_label |
| cargo clippy --all-targets -- -D warnings | $clippy_label |
| cargo test | $test_label |
| cargo test --workspace | $workspace_test_label |
| policy checks | $POLICY_STATUS |
| optional quality tools | $OPTIONAL_STATUS |

## Evidence

- Verification run by external harness after last source edit: yes
- No partial command output was treated as success: yes
- Formatting intervention recorded: yes
- Harness fmt rescue required: $FMT_AUTOFIXED
- Harness clippy/test/build rescue: not allowed
- Editor commits allowed: no
- Human merge required: yes

## Diff summary

$(cat "$RUN_DIR/06-diff-stat.txt" || true)
EOF_RESULT

echo "$FINAL_STATUS" > "$RUN_DIR/06-status.txt"
echo "INFO: verification status: $FINAL_STATUS"
