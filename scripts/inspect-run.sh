#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: inspect-run.sh <run-dir> [--verify]

Print the final decision, verification summary, review outputs, worktree status,
and source diff for a completed pipeline run.

Options:
  --verify   rerun cargo fmt --check, cargo clippy --all-targets -- -D warnings,
             and cargo test inside the agent worktree.
EOF
}

RUN_DIR="${1:-}"
VERIFY="no"

if [ -z "$RUN_DIR" ] || [ "$RUN_DIR" = "-h" ] || [ "$RUN_DIR" = "--help" ]; then
  usage
  exit 0
fi

shift || true
for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY="yes" ;;
    *) echo "ERROR: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

[ -d "$RUN_DIR" ] || { echo "ERROR: run dir not found: $RUN_DIR" >&2; exit 1; }
[ -f "$RUN_DIR/00-meta.env" ] || { echo "ERROR: missing run metadata: $RUN_DIR/00-meta.env" >&2; exit 1; }

# shellcheck source=/dev/null
source "$RUN_DIR/00-meta.env"

print_file() {
  local title="$1"
  local file="$2"
  echo
  echo "╔══════════════════════════════════════╗"
  printf "║  %-36s║\n" "$title"
  echo "╚══════════════════════════════════════╝"
  if [ -f "$file" ]; then
    cat "$file"
  else
    echo "(missing: $file)"
  fi
}

print_file "Final decision" "$RUN_DIR/09-final-decision.txt"
print_file "Agent result" "$RUN_DIR/05-agent-result.md"
print_file "Review" "$RUN_DIR/07-review.md"

if [ -f "$RUN_DIR/08-second-opinion.md" ]; then
  print_file "Second opinion" "$RUN_DIR/08-second-opinion.md"
fi

echo
echo "╔══════════════════════════════════════╗"
echo "║  Worktree                            ║"
echo "╚══════════════════════════════════════╝"
echo "Run dir:  $RUN_DIR"
echo "Worktree: $WORKTREE_PATH"

if [ -d "$WORKTREE_PATH" ]; then
  echo
  echo "--- git status --short ---"
  git -C "$WORKTREE_PATH" status --short

  echo
  echo "--- git diff --stat ---"
  git -C "$WORKTREE_PATH" diff --stat

  echo
  echo "--- git diff ---"
  git -C "$WORKTREE_PATH" diff
else
  echo "ERROR: worktree not found: $WORKTREE_PATH" >&2
  exit 1
fi

if [ "$VERIFY" = "yes" ]; then
  echo
  echo "╔══════════════════════════════════════╗"
  echo "║  Manual verification                 ║"
  echo "╚══════════════════════════════════════╝"
  (
    cd "$WORKTREE_PATH"
    cargo fmt --check
    cargo clippy --all-targets -- -D warnings
    cargo test
  )
fi
