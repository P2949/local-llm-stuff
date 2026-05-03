#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 03-accepted-issues.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"

echo "=== Stage 3: Extract Accepted Items ==="

OUT="$RUN_DIR/03-accepted-issues.md"
{
  echo "# Accepted Items"
  echo
  echo "Extracted from: 02-challenge.md"
  echo "Date: $(date -Iseconds)"
  echo "Mode: ${TASK_MODE:-fix}"
  echo
  echo "Only accepted challenge items may reach patch-writer/editor stages. In review mode, these are findings for human inspection only."
  echo
  awk '
    function accepted(b) {
      return b ~ /(^|\n)Decision:[[:space:]]*ACCEPT([[:space:]]|\n|$)/
    }
    /^## [FPI]-[0-9]+:/ {
      if (accepted(block)) print block "\n"
      block=$0 "\n"
      inblock=1
      next
    }
    /^## / {
      if (inblock && accepted(block)) print block "\n"
      inblock=0
      block=""
      next
    }
    inblock { block=block $0 "\n" }
    END {
      if (inblock && accepted(block)) print block "\n"
    }
  ' "$RUN_DIR/02-challenge.md"
} > "$OUT"

ACCEPTED_COUNT="$(grep -Ec '^Decision:[[:space:]]*ACCEPT([[:space:]]|$)' "$OUT" 2>/dev/null || true)"
echo "INFO: accepted items: ${ACCEPTED_COUNT:-0}"
echo "INFO: accepted items -> $OUT"
