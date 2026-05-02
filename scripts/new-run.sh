#!/usr/bin/env bash
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PIPELINE_DIR/config/pipeline.env"

TARGET_REPO="${1:?Usage: new-run.sh <path-to-rust-repo> [fix|feature] [task-description]}"
TASK_MODE="${2:-$DEFAULT_TASK_MODE}"
TASK_DESC="${3:-}"

case "$TASK_MODE" in
  fix|feature) ;;
  *) echo "ERROR: task mode must be 'fix' or 'feature'" >&2; exit 1 ;;
esac

TARGET_REPO="$(realpath "$TARGET_REPO")"
[ -f "$TARGET_REPO/Cargo.toml" ] || { echo "ERROR: no Cargo.toml in $TARGET_REPO" >&2; exit 1; }

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$TARGET_REPO/.llm-runs/$RUN_ID"
WORKTREE_PATH="$(dirname "$TARGET_REPO")/llm-agent-${RUN_ID}"
mkdir -p "$RUN_DIR"

cat > "$RUN_DIR/00-meta.env" << EOF
RUN_ID="$RUN_ID"
TASK_MODE="$TASK_MODE"
TARGET_REPO="$TARGET_REPO"
PIPELINE_DIR="$PIPELINE_DIR"
RUN_DIR="$RUN_DIR"
WORKTREE_PATH="$WORKTREE_PATH"
ITERATION=0
ACTIVE_EDITOR_MODEL="$ACTIVE_EDITOR_MODEL"
EOF

if [ -n "$TASK_DESC" ]; then
  printf '%s\n' "$TASK_DESC" > "$RUN_DIR/00-task.md"
else
  cat > "$RUN_DIR/00-task.md" << EOF
# Task

Edit this file before running the pipeline.

Mode: $TASK_MODE

Describe:
- What module/subsystem to inspect or implement.
- What must change.
- What must not change.
- Any known constraints.
EOF
fi

cd "$TARGET_REPO"
git worktree add "$WORKTREE_PATH" -b "llm/agent-${RUN_ID}"

# Repo map is generated during baseline too, but create a first copy now.
source "$PIPELINE_DIR/scripts/lib/context.sh"
write_context_manifest "$RUN_DIR" "$TARGET_REPO"

cat << EOF
INFO: run initialized
  RUN_ID:   $RUN_ID
  MODE:     $TASK_MODE
  RUN_DIR:  $RUN_DIR
  WORKTREE: $WORKTREE_PATH

Run:
  bash $PIPELINE_DIR/scripts/pipeline.sh $RUN_DIR
EOF
