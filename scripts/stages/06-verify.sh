#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 06-verify.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"

echo "=== Stage 6: External Verification ==="
cd "$WORKTREE_PATH"

FMT_AUTOFIXED="no"
FINAL_STATUS="READY_FOR_REVIEW"
FMT1_STATUS=0
FMT2_STATUS=0
CLIPPY_STATUS="not-run"
TEST_STATUS="not-run"

set +e
cargo fmt --check > "$RUN_DIR/06-fmt-check-1.txt" 2>&1
FMT1_STATUS=$?
set -e

if [ "$FMT1_STATUS" -ne 0 ]; then
  FMT_AUTOFIXED="yes"
  set +e
  cargo fmt > "$RUN_DIR/06-fmt-autofix.txt" 2>&1
  FMT_AUTOFIX_STATUS=$?
  set -e
  if [ "$FMT_AUTOFIX_STATUS" -ne 0 ]; then
    FINAL_STATUS="BLOCKED"
    FMT2_STATUS=1
    echo "BLOCKED: cargo fmt failed during harness rescue" > "$RUN_DIR/06-fmt-check-2.txt"
  else
    set +e
    cargo fmt --check > "$RUN_DIR/06-fmt-check-2.txt" 2>&1
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
  cargo clippy --all-targets -- -D warnings > "$RUN_DIR/06-clippy.txt" 2>&1
  CLIPPY_STATUS=$?
  set -e
  [ "$CLIPPY_STATUS" -ne 0 ] && FINAL_STATUS="BLOCKED"
fi

if [ "$FINAL_STATUS" != "BLOCKED" ]; then
  set +e
  cargo test > "$RUN_DIR/06-test.txt" 2>&1
  TEST_STATUS=$?
  set -e
  [ "$TEST_STATUS" -ne 0 ] && FINAL_STATUS="BLOCKED"
fi

# Ensure output files exist even when skipped.
[ -f "$RUN_DIR/06-clippy.txt" ] || echo "NOT RUN" > "$RUN_DIR/06-clippy.txt"
[ -f "$RUN_DIR/06-test.txt" ] || echo "NOT RUN" > "$RUN_DIR/06-test.txt"

git diff --stat > "$RUN_DIR/06-diff-stat.txt"
git diff > "$RUN_DIR/06-diff.patch"
CHANGED_FILES="$(git diff --name-only | tr '\n' ' ')"

fmt1_label="$([ "$FMT1_STATUS" -eq 0 ] && echo PASS || echo FAIL)"
fmt2_label="$([ "$FMT2_STATUS" -eq 0 ] && echo PASS || echo FAIL)"
clippy_label="NOT RUN"
if [ "$CLIPPY_STATUS" != "not-run" ]; then
  clippy_label="$([ "$CLIPPY_STATUS" -eq 0 ] && echo PASS || echo FAIL)"
fi
test_label="NOT RUN"
if [ "$TEST_STATUS" != "not-run" ]; then
  test_label="$([ "$TEST_STATUS" -eq 0 ] && echo PASS || echo FAIL)"
fi

cat > "$RUN_DIR/05-agent-result.md" << EOF
# Agent Result

- Run: $RUN_ID
- Iteration: $ITERATION
- Final status: $FINAL_STATUS
- Editor model: $ACTIVE_EDITOR_MODEL
- Files changed: ${CHANGED_FILES:-"(none)"}

## Verification result

| Check | Result |
|---|---|
| cargo fmt --check before harness | $fmt1_label |
| cargo fmt auto-corrected by harness | $FMT_AUTOFIXED |
| cargo fmt --check after harness | $fmt2_label |
| cargo clippy --all-targets -- -D warnings | $clippy_label |
| cargo test | $test_label |

## Evidence

- Verification run by external harness after last source edit: yes
- No partial command output was treated as success: yes
- Formatting intervention recorded: yes
- Harness fmt rescue required: $FMT_AUTOFIXED
- Harness clippy/test rescue: not allowed

## Diff summary

$(cat "$RUN_DIR/06-diff-stat.txt" || true)
EOF

echo "$FINAL_STATUS" > "$RUN_DIR/06-status.txt"
echo "INFO: verification status: $FINAL_STATUS"
