#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 03-accepted-issues.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"

echo "=== Stage 3: Extract Consensus Accepted Items ==="

OUT="$RUN_DIR/03-accepted-issues.md"
QWEN_CHALLENGE="$RUN_DIR/02-challenge.md"
GEMMA_CHALLENGE="$RUN_DIR/02b-challenge-gemma.md"
EVIDENCE_AUDIT="$RUN_DIR/03-evidence-audit.md"

if [ ! -s "$QWEN_CHALLENGE" ]; then
  echo "ERROR: missing Qwen challenge report: $QWEN_CHALLENGE" >&2
  exit 1
fi

if [ ! -s "$GEMMA_CHALLENGE" ]; then
  echo "ERROR: missing Gemma challenge report: $GEMMA_CHALLENGE" >&2
  exit 1
fi

normalize_id() {
  local raw="$1"
  local prefix number
  raw="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]:.,;]+$//')"
  prefix="$(printf '%s' "$raw" | sed -nE 's/^([FPI])-?[0-9]+$/\1/p')"
  number="$(printf '%s' "$raw" | sed -nE 's/^[FPI]-?0*([0-9]+)$/\1/p')"
  if [ -n "$prefix" ] && [ -n "$number" ]; then
    printf '%s-%03d\n' "$prefix" "$number"
  fi
}

normalize_ids() {
  while IFS= read -r id; do
    normalize_id "$id"
  done | sort -u
}

# ACCEPT blocks are allowed through only when they include concrete source
# evidence. This is intentionally deterministic: prompt compliance is not enough.
# Accepted evidence must include at least one bullet like:
#   - stutter/src/main.rs:321: score.total = u64::MAX / 4;
# A source context range is also accepted when the bullet still includes a
# concrete snippet, for example:
#   - stutter/src/main.rs:815-823: fn tune_run_dir(...)
# Blocks using vague evidence language are rejected before consensus extraction.
extract_accepted_ids_raw() {
  awk -v report_name="$2" -v audit_file="$EVIDENCE_AUDIT" '
    function accepted(b) {
      return b ~ /(^|\n)Decision:[[:space:]]*ACCEPT([[:space:]]|\n|$)/
    }
    function has_source_evidence(b) {
      return b ~ /(^|\n)[[:space:]]*-[[:space:]]*[^[:space:]]+:[0-9]+(-[0-9]+)?:[[:space:]]*[^[:space:]]+/
    }
    function has_banned_evidence_language(b, lower) {
      lower = tolower(b)
      return lower ~ /(implied logic|likely|probably|without seeing the implementation|contextual analysis|standard behavior)/
    }
    function emit() {
      if (id == "" || !accepted(block)) return
      if (!has_source_evidence(block)) {
        print "- " report_name " " id ": rejected ACCEPT during extraction; missing exact source evidence bullet" >> audit_file
        return
      }
      if (has_banned_evidence_language(block)) {
        print "- " report_name " " id ": rejected ACCEPT during extraction; contains banned vague evidence language" >> audit_file
        return
      }
      print id
    }
    /^## [FPI]-?[0-9]+[[:space:]:]/ {
      emit()
      id=$2
      sub(/:$/, "", id)
      block=$0 "\n"
      next
    }
    /^## / {
      emit()
      id=""
      block=""
      next
    }
    id != "" { block=block $0 "\n" }
    END { emit() }
  ' "$1"
}

QWEN_IDS="$(mktemp)"
GEMMA_IDS="$(mktemp)"
CONSENSUS_IDS="$(mktemp)"
cleanup() { rm -f "$QWEN_IDS" "$GEMMA_IDS" "$CONSENSUS_IDS"; }
trap cleanup EXIT INT TERM

{
  echo "# Accepted Evidence Audit"
  echo
  echo "Only ACCEPT blocks with exact source evidence bullets may enter consensus."
  echo
} > "$EVIDENCE_AUDIT"

extract_accepted_ids_raw "$QWEN_CHALLENGE" "qwen" | normalize_ids > "$QWEN_IDS"
extract_accepted_ids_raw "$GEMMA_CHALLENGE" "gemma" | normalize_ids > "$GEMMA_IDS"
comm -12 "$QWEN_IDS" "$GEMMA_IDS" > "$CONSENSUS_IDS"

QWEN_COUNT="$(wc -l < "$QWEN_IDS" | tr -d ' ')"
GEMMA_COUNT="$(wc -l < "$GEMMA_IDS" | tr -d ' ')"
CONSENSUS_COUNT="$(wc -l < "$CONSENSUS_IDS" | tr -d ' ')"

{
  echo "# Accepted Items"
  echo
  echo "Extracted from: 02-challenge.md and 02b-challenge-gemma.md"
  echo "Consensus rule: only items accepted by both Qwen and Gemma may reach patch-writer/editor stages."
  echo "Evidence rule: accepted items must include exact source evidence bullets; see 03-evidence-audit.md."
  echo "Date: $(date -Iseconds)"
  echo "Mode: ${TASK_MODE:-fix}"
  echo "Qwen accepted: $QWEN_COUNT"
  echo "Gemma accepted: $GEMMA_COUNT"
  echo "Consensus accepted: $CONSENSUS_COUNT"
  echo
  echo "Only consensus-accepted items may reach patch-writer/editor stages. In review mode, these are findings for human inspection only."
  echo

  awk -v ids_file="$CONSENSUS_IDS" '
    function norm(raw, cleaned, prefix, number) {
      cleaned = raw
      gsub(/^[[:space:]]+/, "", cleaned)
      gsub(/[[:space:]:.,;]+$/, "", cleaned)
      if (match(cleaned, /^([FPI])-?0*([0-9]+)$/, m)) {
        prefix = m[1]
        number = m[2] + 0
        return sprintf("%s-%03d", prefix, number)
      }
      return ""
    }
    function accepted(b) { return b ~ /(^|\n)Decision:[[:space:]]*ACCEPT([[:space:]]|\n|$)/ }
    function has_source_evidence(b) { return b ~ /(^|\n)[[:space:]]*-[[:space:]]*[^[:space:]]+:[0-9]+(-[0-9]+)?:[[:space:]]*[^[:space:]]+/ }
    function has_banned_evidence_language(b, lower) {
      lower = tolower(b)
      return lower ~ /(implied logic|likely|probably|without seeing the implementation|contextual analysis|standard behavior)/
    }
    BEGIN {
      while ((getline id < ids_file) > 0) consensus[id]=1
      close(ids_file)
    }
    function emit() {
      normalized_id = norm(id)
      if (normalized_id != "" && (normalized_id in consensus) && accepted(block) && has_source_evidence(block) && !has_banned_evidence_language(block)) {
        print "<!-- consensus: qwen=ACCEPT gemma=ACCEPT id=" normalized_id " -->"
        print block "\n"
      }
    }
    /^## [FPI]-?[0-9]+[[:space:]:]/ {
      emit()
      id=$2
      sub(/:$/, "", id)
      block=$0 "\n"
      next
    }
    /^## / {
      emit()
      id=""
      block=""
      next
    }
    id != "" { block=block $0 "\n" }
    END { emit() }
  ' "$QWEN_CHALLENGE"
} > "$OUT"

trap - EXIT INT TERM
cleanup

echo "INFO: Qwen accepted items: ${QWEN_COUNT:-0}"
echo "INFO: Gemma accepted items: ${GEMMA_COUNT:-0}"
echo "INFO: consensus accepted items: ${CONSENSUS_COUNT:-0}"
echo "INFO: consensus accepted items -> $OUT"
