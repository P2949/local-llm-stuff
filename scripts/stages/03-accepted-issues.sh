#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 03-accepted-issues.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"

echo "=== Stage 3: Extract Consensus Accepted Items ==="

OUT="$RUN_DIR/03-accepted-issues.md"
QWEN_CHALLENGE="$RUN_DIR/02-challenge.md"
GEMMA_CHALLENGE="$RUN_DIR/02b-challenge-gemma.md"

if [ ! -s "$QWEN_CHALLENGE" ]; then
  echo "ERROR: missing Qwen challenge report: $QWEN_CHALLENGE" >&2
  exit 1
fi

if [ ! -s "$GEMMA_CHALLENGE" ]; then
  echo "ERROR: missing Gemma challenge report: $GEMMA_CHALLENGE" >&2
  exit 1
fi

extract_accepted_ids() {
  awk '
    function accepted(b) { return b ~ /(^|\n)Decision:[[:space:]]*ACCEPT([[:space:]]|\n|$)/ }
    function emit() { if (id != "" && accepted(block)) print id }
    /^## [FPI]-[0-9]+:/ {
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
  ' "$1" | sort -u
}

QWEN_IDS="$(mktemp)"
GEMMA_IDS="$(mktemp)"
CONSENSUS_IDS="$(mktemp)"
cleanup() { rm -f "$QWEN_IDS" "$GEMMA_IDS" "$CONSENSUS_IDS"; }
trap cleanup EXIT INT TERM

extract_accepted_ids "$QWEN_CHALLENGE" > "$QWEN_IDS"
extract_accepted_ids "$GEMMA_CHALLENGE" > "$GEMMA_IDS"
comm -12 "$QWEN_IDS" "$GEMMA_IDS" > "$CONSENSUS_IDS"

QWEN_COUNT="$(wc -l < "$QWEN_IDS" | tr -d ' ')"
GEMMA_COUNT="$(wc -l < "$GEMMA_IDS" | tr -d ' ')"
CONSENSUS_COUNT="$(wc -l < "$CONSENSUS_IDS" | tr -d ' ')"

{
  echo "# Accepted Items"
  echo
  echo "Extracted from: 02-challenge.md and 02b-challenge-gemma.md"
  echo "Consensus rule: only items accepted by both Qwen and Gemma may reach patch-writer/editor stages."
  echo "Date: $(date -Iseconds)"
  echo "Mode: ${TASK_MODE:-fix}"
  echo "Qwen accepted: $QWEN_COUNT"
  echo "Gemma accepted: $GEMMA_COUNT"
  echo "Consensus accepted: $CONSENSUS_COUNT"
  echo
  echo "Only consensus-accepted items may reach patch-writer/editor stages. In review mode, these are findings for human inspection only."
  echo

  awk -v ids_file="$CONSENSUS_IDS" '
    BEGIN {
      while ((getline id < ids_file) > 0) consensus[id]=1
      close(ids_file)
    }
    function accepted(b) { return b ~ /(^|\n)Decision:[[:space:]]*ACCEPT([[:space:]]|\n|$)/ }
    function emit() {
      if (id != "" && (id in consensus) && accepted(block)) {
        print "<!-- consensus: qwen=ACCEPT gemma=ACCEPT -->"
        print block "\n"
      }
    }
    /^## [FPI]-[0-9]+:/ {
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
