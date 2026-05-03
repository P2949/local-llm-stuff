#!/usr/bin/env bash
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${1:?Usage: pipeline.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/pipeline.env"
source "$PIPELINE_DIR/scripts/lib/policy.sh"

if [ -n "${PROJECT_PROFILE_FILE:-}" ] && [ -f "$PROJECT_PROFILE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$PROJECT_PROFILE_FILE"
else
  policy_source_project_profile "$TARGET_REPO"
fi

STAGES="$PIPELINE_DIR/scripts/stages"

write_decision() {
  local decision="$1"
  local reason="${2:-}"
  if [ -n "$reason" ]; then
    echo "$decision: $reason" > "$RUN_DIR/09-final-decision.txt"
  else
    echo "$decision" > "$RUN_DIR/09-final-decision.txt"
  fi
  echo "INFO: final decision: $(cat "$RUN_DIR/09-final-decision.txt")"
}

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-unknown}
  if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ] && [ ! -s "$RUN_DIR/09-final-decision.txt" ]; then
    write_decision "NEEDS_HUMAN_REVIEW" "pipeline aborted at line $line_no with exit code $exit_code"
  fi
  exit "$exit_code"
}
trap on_error ERR

run_stage() {
  local name="$1"; shift
  echo
  echo "╔══════════════════════════════════════╗"
  printf "║  %-36s║\n" "$name"
  echo "╚══════════════════════════════════════╝"
  bash "$STAGES/$name" "$RUN_DIR" "$@"
}

get_review_verdict() {
  awk '
    BEGIN { found=0 }
    /^## Verdict/ { found=1; next }
    found && /APPROVE|REQUEST_CHANGES|REJECT|NEEDS_HUMAN_REVIEW|UNCERTAIN/ {
      print toupper($0); exit
    }
  ' "$RUN_DIR/07-review.md" 2>/dev/null \
    | grep -oiE 'APPROVE|REQUEST_CHANGES|REJECT|NEEDS_HUMAN_REVIEW|UNCERTAIN' \
    | head -1 || echo "UNKNOWN"
}

get_selected_candidate() {
  awk '
    BEGIN { found=0 }
    /^## Selected candidate/ { found=1; next }
    found && /qwen|devstral|none/ { print tolower($0); exit }
  ' "$RUN_DIR/07-review.md" 2>/dev/null \
    | grep -oiE 'qwen|devstral|none' \
    | head -1 || echo "none"
}

get_gemma_verdict() {
  awk '
    BEGIN { found=0 }
    /^## Verdict/ { found=1; next }
    found && /AGREE|DISAGREE|BLOCK/ { print toupper($0); exit }
  ' "$RUN_DIR/08-second-opinion.md" 2>/dev/null \
    | grep -oiE 'AGREE|DISAGREE|BLOCK' \
    | head -1 || echo "AGREE"
}

should_trigger_shadow_finder() {
  local task
  task="$(cat "$RUN_DIR/00-task.md")"
  local kw
  for kw in $(echo "$HIGH_SEVERITY_KEYWORDS" | tr ',' '\n'); do
    echo "$task" | grep -qi "$kw" && return 0
  done
  grep -qiE 'unsafe|pub (fn|struct|enum|trait)|serialize|deserialize|file I/O|state invariant|eBPF|tracepoint|affinity|restore' "$RUN_DIR/01-finder.md" 2>/dev/null && return 0
  if [ "${TASK_MODE:-fix}" != "feature" ] && ! grep -qE '^### [FPI]-[0-9]+' "$RUN_DIR/01-finder.md" 2>/dev/null; then
    return 0
  fi
  return 1
}

should_trigger_second_opinion() {
  local verdict="$1"
  if policy_bool_enabled "${ENFORCE_SECOND_OPINION_ON_RISK:-1}"; then
    case "$verdict" in
      REQUEST_CHANGES|REJECT|UNCERTAIN|NEEDS_HUMAN_REVIEW) return 0 ;;
    esac
    grep -qiE "${RISK_DIFF_REGEX:-unsafe|pub fn|serialize|file I/O}" "$RUN_DIR/06-diff.patch" 2>/dev/null && return 0
    grep -qiE 'critical|high|eBPF|ABI|affinity|restore|state invariant' "$RUN_DIR/03-accepted-issues.md" 2>/dev/null && return 0
  fi
  return 1
}

check_revision_for_escalation() {
  local revision_file="$1"
  if grep -q '^NEEDS_HUMAN_REVIEW' "$revision_file"; then
    write_decision "NEEDS_HUMAN_REVIEW" "revision-writer says broad redesign/human review required"
    exit 1
  fi
  if grep -q '^NEEDS_RECHALLENGE' "$revision_file"; then
    write_decision "NEEDS_HUMAN_REVIEW" "revision-writer says review contradicts accepted items"
    exit 1
  fi
}

reset_worktree_for_editor() {
  if [ -z "${WORKTREE_PATH:-}" ] || [ ! -d "$WORKTREE_PATH" ]; then
    echo "ERROR: worktree missing: ${WORKTREE_PATH:-}" >&2
    exit 1
  fi

  if [ -n "${AGENT_BASE_COMMIT:-}" ]; then
    git -C "$WORKTREE_PATH" reset --hard "$AGENT_BASE_COMMIT" >/dev/null
  else
    git -C "$WORKTREE_PATH" checkout -- .
  fi
  git -C "$WORKTREE_PATH" clean -fd >/dev/null
}

archive_candidate_artifacts() {
  local candidate="$1"
  local dir="$RUN_DIR/candidates/$candidate"
  rm -rf "$dir"
  mkdir -p "$dir"

  local file
  for file in \
    05-agent-output.txt \
    05-agent-exit-code.txt \
    05-editor-policy.txt \
    05-source-location-check.txt \
    05-aider-files.txt \
    05-agent-result.md \
    06-status.txt \
    06-status-reason.txt \
    06-editor-stop.txt \
    06-quality-scorecard.md \
    06-no-agent-commits.txt \
    06-allowed-files.txt \
    06-patch-size.txt \
    06-feature-tests.txt \
    06-optional-quality.md \
    06-diff-stat.txt \
    06-diff.patch \
    06-build.txt \
    06-clippy.txt \
    06-test.txt \
    06-workspace-test.txt \
    06-fmt-check-1.txt \
    06-fmt-check-2.txt \
    06-fmt-autofix.txt; do
    [ -e "$RUN_DIR/$file" ] && cp "$RUN_DIR/$file" "$dir/$file"
  done

  local status="missing"
  [ -s "$dir/06-status.txt" ] && status="$(cat "$dir/06-status.txt")"
  local reason="none"
  [ -s "$dir/06-status-reason.txt" ] && reason="$(cat "$dir/06-status-reason.txt")"
  local diff_sha="empty"
  if [ -s "$dir/06-diff.patch" ]; then
    diff_sha="$(sha256sum "$dir/06-diff.patch" | awk '{print $1}')"
  fi
  local changed_files="(none)"
  if [ -s "$dir/06-diff.patch" ]; then
    changed_files="$(git -C "$WORKTREE_PATH" diff --name-only | tr '\n' ' ')"
  fi

  cat > "$dir/candidate-summary.md" << EOF_SUMMARY
# Candidate Summary

- Candidate: $candidate
- Iteration: $ITERATION
- Verification status: $status
- Verification reason: $reason
- Diff sha256: $diff_sha
- Changed files: ${changed_files:-"(none)"}
EOF_SUMMARY
}

run_editor_candidate() {
  local candidate="$1"
  local prompt_file="$2"
  echo
  echo "── Candidate editor: $candidate ──"
  reset_worktree_for_editor
  rm -f "$RUN_DIR"/05-* "$RUN_DIR"/06-*
  run_stage 05-editor.sh "$prompt_file" "$candidate"
  run_stage 06-verify.sh "$prompt_file"
  archive_candidate_artifacts "$candidate"
}

run_dual_editor_iteration() {
  local prompt_file="$1"
  rm -rf "$RUN_DIR/candidates"
  mkdir -p "$RUN_DIR/candidates"

  run_editor_candidate qwen "$prompt_file"
  run_editor_candidate devstral "$prompt_file"

  reset_worktree_for_editor
}

restore_selected_candidate_artifacts() {
  local candidate="$1"
  local dir="$RUN_DIR/candidates/$candidate"
  [ -d "$dir" ] || { echo "ERROR: selected candidate artifacts missing: $candidate" >&2; return 1; }

  local file
  for file in "$dir"/*; do
    [ -f "$file" ] || continue
    case "$(basename "$file")" in
      candidate-summary.md) continue ;;
    esac
    cp "$file" "$RUN_DIR/$(basename "$file")"
  done
}

apply_selected_candidate_patch() {
  local candidate="$1"
  local dir="$RUN_DIR/candidates/$candidate"
  [ -d "$dir" ] || { echo "ERROR: selected candidate artifacts missing: $candidate" >&2; return 1; }
  [ -s "$dir/06-diff.patch" ] || { echo "ERROR: selected candidate has no diff: $candidate" >&2; return 1; }

  reset_worktree_for_editor
  git -C "$WORKTREE_PATH" apply "$dir/06-diff.patch"
  restore_selected_candidate_artifacts "$candidate"
  echo "$candidate" > "$RUN_DIR/07-selected-candidate.txt"
}

policy_write_manifest "$RUN_DIR"
policy_assert_local_editor_model

run_stage 00-baseline.sh
run_stage 01-finder.sh

if should_trigger_shadow_finder; then
  echo "INFO: triggering shadow finder"
  run_stage 01b-shadow-finder.sh
else
  echo "INFO: shadow finder skipped"
fi

run_stage 02-challenge.sh
run_stage 02b-gemma-challenge.sh
run_stage 03-accepted-issues.sh

ACCEPTED_COUNT="$(grep -c 'Decision: ACCEPT' "$RUN_DIR/03-accepted-issues.md" 2>/dev/null || true)"
ACCEPTED_COUNT="${ACCEPTED_COUNT:-0}"
if [ "$ACCEPTED_COUNT" -eq 0 ]; then
  write_decision "NO_CONSENSUS_ITEMS_ACCEPTED" "Qwen and Gemma did not both accept any finder/plan item"
  exit 0
fi

if [ "${TASK_MODE:-fix}" = "review" ]; then
  write_decision "REVIEW_READY" "review-only mode stopped after Qwen/Gemma consensus extraction; no editor stage was run"
  exit 0
fi

run_stage 04-patch-writer.sh

ITERATION=0
CURRENT_PROMPT="$RUN_DIR/04-patch-prompt.md"

while [ "$ITERATION" -lt "$MAX_PATCH_ITERATIONS" ]; do
  echo
  echo "── Patch iteration $((ITERATION + 1)) / $MAX_PATCH_ITERATIONS ──"
  sed -i "s/^ITERATION=.*/ITERATION=$ITERATION/" "$RUN_DIR/00-meta.env"
  source "$RUN_DIR/00-meta.env"

  run_dual_editor_iteration "$CURRENT_PROMPT"
  run_stage 07-review.sh "$CURRENT_PROMPT"
  VERDICT="$(get_review_verdict)"
  SELECTED_CANDIDATE="$(get_selected_candidate)"
  echo "INFO: review verdict: $VERDICT"
  echo "INFO: selected candidate: $SELECTED_CANDIDATE"

  case "$VERDICT" in
    APPROVE)
      case "$SELECTED_CANDIDATE" in
        qwen|devstral)
          apply_selected_candidate_patch "$SELECTED_CANDIDATE"
          ;;
        none|*)
          write_decision "NEEDS_HUMAN_REVIEW" "review approved but selected no usable candidate"
          exit 1
          ;;
      esac

      if should_trigger_second_opinion "$VERDICT"; then
        echo "INFO: triggering second opinion"
        run_stage 12-second-opinion.sh
        GEMMA_VERDICT="$(get_gemma_verdict)"
        echo "INFO: second opinion verdict: $GEMMA_VERDICT"
        case "$GEMMA_VERDICT" in
          BLOCK)
            write_decision "NEEDS_HUMAN_REVIEW" "Gemma found concrete blocking evidence"
            exit 1
            ;;
          DISAGREE)
            write_decision "NEEDS_HUMAN_REVIEW" "Gemma disagreed; inspect 08-second-opinion.md"
            exit 1
            ;;
          AGREE|*)
            write_decision "APPROVED" "candidate $SELECTED_CANDIDATE approved and second opinion agreed; human inspection required before merge"
            exit 0
            ;;
        esac
      else
        write_decision "APPROVED" "candidate $SELECTED_CANDIDATE ready for human inspection; no automatic merge allowed"
        exit 0
      fi
      ;;

    REQUEST_CHANGES)
      ITERATION=$((ITERATION + 1))
      if [ "$ITERATION" -ge "$MAX_PATCH_ITERATIONS" ]; then
        write_decision "NEEDS_HUMAN_REVIEW" "max iterations reached after REQUEST_CHANGES"
        exit 1
      fi
      sed -i "s/^ITERATION=.*/ITERATION=$ITERATION/" "$RUN_DIR/00-meta.env"
      source "$RUN_DIR/00-meta.env"
      run_stage 08-revision-writer.sh
      REVISION_FILE="$RUN_DIR/04-revision-prompt-${ITERATION}.md"
      check_revision_for_escalation "$REVISION_FILE"
      CURRENT_PROMPT="$REVISION_FILE"
      ;;

    REJECT)
      if grep -qiE 'issue was invalid|not a real bug|should not have been accepted|NEEDS_RECHALLENGE|contradicts accepted' "$RUN_DIR/07-review.md"; then
        write_decision "NEEDS_HUMAN_REVIEW" "review contradicts accepted items; needs rechallenge"
      else
        write_decision "REJECTED" "candidate review rejected both patches"
      fi
      exit 1
      ;;

    NEEDS_HUMAN_REVIEW|UNCERTAIN)
      write_decision "NEEDS_HUMAN_REVIEW" "candidate review verdict: $VERDICT"
      exit 1
      ;;

    UNKNOWN|*)
      write_decision "NEEDS_HUMAN_REVIEW" "missing or malformed review verdict: $VERDICT"
      exit 1
      ;;
  esac
done

write_decision "NEEDS_HUMAN_REVIEW" "max iterations exhausted"
exit 1
