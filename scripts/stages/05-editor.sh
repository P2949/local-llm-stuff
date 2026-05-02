#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 05-editor.sh <run-dir> [prompt-file]}"
PROMPT_FILE="${2:-$RUN_DIR/04-patch-prompt.md}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"

echo "=== Stage 5: Editor ==="
echo "INFO: prompt: $PROMPT_FILE"
echo "INFO: worktree: $WORKTREE_PATH"

[ -f "$PROMPT_FILE" ] || { echo "ERROR: prompt file missing: $PROMPT_FILE" >&2; exit 1; }
[ -d "$WORKTREE_PATH/.git" ] || [ -f "$WORKTREE_PATH/.git" ] || { echo "ERROR: worktree missing: $WORKTREE_PATH" >&2; exit 1; }

AIDER_PROMPT_ARGS=()
if "$AIDER_BIN" --help 2>/dev/null | grep -q -- '--message-file'; then
  AIDER_PROMPT_ARGS=(--message-file "$PROMPT_FILE")
  echo "INFO: Aider prompt mode: --message-file"
else
  PROMPT_BYTES="$(wc -c < "$PROMPT_FILE" | tr -d ' ')"
  if [ "$PROMPT_BYTES" -gt "$AIDER_MAX_MESSAGE_ARG_BYTES" ]; then
    {
      echo "ERROR: $AIDER_BIN does not support --message-file and prompt is too large for argv."
      echo "ERROR: prompt bytes: $PROMPT_BYTES"
      echo "ERROR: max fallback bytes: $AIDER_MAX_MESSAGE_ARG_BYTES"
      echo "ERROR: upgrade aider or reduce the patch prompt/context."
    } | tee "$RUN_DIR/05-agent-output.txt" >&2
    echo "2" > "$RUN_DIR/05-agent-exit-code.txt"
    exit 1
  fi
  AIDER_PROMPT_ARGS=(--message "$(cat "$PROMPT_FILE")")
  echo "INFO: Aider prompt mode: --message argv fallback (${PROMPT_BYTES} bytes)"
fi

cd "$WORKTREE_PATH"

MODEL_STARTED=0
cleanup() {
  if [ "$MODEL_STARTED" -eq 1 ]; then
    "$PIPELINE_DIR/scripts/model/stop.sh" qwen_coder || true
  fi
}
trap cleanup EXIT

"$PIPELINE_DIR/scripts/model/start.sh" qwen_coder
MODEL_STARTED=1

AIDER_EXTRA_ARGV=()
if [ -n "${AIDER_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  AIDER_EXTRA_ARGV=($AIDER_EXTRA_ARGS)
fi

set +e
AIDER_OPENAI_API_BASE="http://127.0.0.1:${QWEN_CODER_PORT}/v1" \
OPENAI_API_KEY="local" \
"$AIDER_BIN" \
  --model "$ACTIVE_EDITOR_MODEL" \
  --edit-format "$AIDER_EDIT_FORMAT" \
  --map-tokens "$AIDER_MAP_TOKENS" \
  --no-auto-commits \
  --no-dirty-commits \
  --no-gitignore \
  --no-show-model-warnings \
  --no-auto-lint \
  "${AIDER_EXTRA_ARGV[@]}" \
  "${AIDER_PROMPT_ARGS[@]}" \
  2>&1 | tee "$RUN_DIR/05-agent-output.txt"
AIDER_EXIT=${PIPESTATUS[0]}
set -e

trap - EXIT
cleanup

echo "INFO: Aider exit code: $AIDER_EXIT" | tee -a "$RUN_DIR/05-agent-output.txt"
# Do not fail the whole harness just because aider exits non-zero; verifier/reviewer decide next.
echo "$AIDER_EXIT" > "$RUN_DIR/05-agent-exit-code.txt"
