#!/usr/bin/env bash
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${1:?Usage: pipeline.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/pipeline.env"

STAGES="$PIPELINE_DIR/scripts/stages"

run_stage() {
  local name="$1"; shift
  echo
  echo "╔══════════════════════════════════════╗"
  printf "║  %-36s║\n" "$name"
  echo "╚══════════════════════════════════════╝"
  "$STAGES/$name" "$RUN_DIR" "$@"
}

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
  # Also trigger if primary finder reports high-risk terms or reports no confirmed items on a strict fix run.
  grep -qiE 'unsafe|pub (fn|struct|enum|trait)|serialize|deserialize|file I/O|state invariant' "$RUN_DIR/01-finder.md" 2>/dev/null && return 0
  if [ "${TASK_MODE:-fix}" = "fix" ] && ! grep -qE '^### [FP]-[0-9]+' "$RUN_DIR/01-finder.md" 2>/dev/null; then
    return 0
  fi
  return 1
}

should_trigger_second_opinion() {
  local verdict="$1"
  case "$verdict" in
    REQUEST_CHANGES|REJECT|UNCERTAIN|NEEDS_HUMAN_REVIEW) return 0 ;;
  esac
  grep -qiE '^[+-].*(unsafe|pub fn|pub struct|pub enum|pub trait|serialize|deserialize|file I/O|state invariant)' "$RUN_DIR/06-diff.patch" 2>/dev/null && return 0
  grep -qiE 'critical|high' "$RUN_DIR/03-accepted-issues.md" 2>/dev/null && return 0
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

# Stage 0: baseline.
run_stage 00-baseline.sh

# Stage 1: finder.
run_stage 01-finder.sh

# Optional shadow finder.
if should_trigger_shadow_finder; then
  echo "INFO: triggering shadow finder"
  run_stage 01b-shadow-finder.sh
else
  echo "INFO: shadow finder skipped"
fi

# Stage 2/3/4.
run_stage 02-challenge.sh
run_stage 03-accepted-issues.sh

ACCEPTED_COUNT="$(grep -c 'Decision: ACCEPT' "$RUN_DIR/03-accepted-issues.md" 2>/dev/null || true)"
ACCEPTED_COUNT="${ACCEPTED_COUNT:-0}"
if [ "$ACCEPTED_COUNT" -eq 0 ]; then
  write_decision "NO_ITEMS_ACCEPTED" "all finder/plan items rejected or unsupported"
  exit 0
fi

run_stage 04-patch-writer.sh

ITERATION=0
CURRENT_PROMPT="$RUN_DIR/04-patch-prompt.md"

while [ "$ITERATION" -lt "$MAX_PATCH_ITERATIONS" ]; do
  echo
  echo "── Patch iteration $((ITERATION + 1)) / $MAX_PATCH_ITERATIONS ──"
  sed -i "s/^ITERATION=.*/ITERATION=$ITERATION/" "$RUN_DIR/00-meta.env"
  # Refresh sourced vars after sed update.
  source "$RUN_DIR/00-meta.env"

  run_stage 05-editor.sh "$CURRENT_PROMPT"
  run_stage 06-verify.sh

  VERIFY_STATUS="$(cat "$RUN_DIR/06-status.txt")"
  echo "INFO: verification status: $VERIFY_STATUS"

  if [ "$VERIFY_STATUS" = "BLOCKED" ]; then
    ITERATION=$((ITERATION + 1))
    if [ "$ITERATION" -ge "$MAX_PATCH_ITERATIONS" ]; then
      write_decision "NEEDS_HUMAN_REVIEW" "verification blocked after max iterations"
      exit 1
    fi
    sed -i "s/^ITERATION=.*/ITERATION=$ITERATION/" "$RUN_DIR/00-meta.env"
    source "$RUN_DIR/00-meta.env"
    run_stage 08-revision-writer.sh
    REVISION_FILE="$RUN_DIR/04-revision-prompt-${ITERATION}.md"
    check_revision_for_escalation "$REVISION_FILE"
    CURRENT_PROMPT="$REVISION_FILE"
    continue
  fi

  run_stage 07-review.sh
  VERDICT="$(get_review_verdict)"
  echo "INFO: review verdict: $VERDICT"

  case "$VERDICT" in
    APPROVE)
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
            write_decision "APPROVED" "primary review approved and second opinion agreed"
            exit 0
            ;;
        esac
      else
        write_decision "APPROVED"
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
      # A reject can mean patch failure or pipeline contradiction. Do not attempt raw revision.
      if grep -qiE 'issue was invalid|not a real bug|should not have been accepted|NEEDS_RECHALLENGE|contradicts accepted' "$RUN_DIR/07-review.md"; then
        write_decision "NEEDS_HUMAN_REVIEW" "review contradicts accepted items; needs rechallenge"
      else
        write_decision "REJECTED" "review rejected the patch"
      fi
      exit 1
      ;;

    NEEDS_HUMAN_REVIEW|UNCERTAIN)
      if should_trigger_second_opinion "$VERDICT"; then
        run_stage 12-second-opinion.sh || true
      fi
      write_decision "NEEDS_HUMAN_REVIEW" "review verdict: $VERDICT"
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
