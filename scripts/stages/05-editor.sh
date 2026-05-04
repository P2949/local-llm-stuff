#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 05-editor.sh <run-dir> [prompt-file] [qwen|devstral]}"
PROMPT_FILE="${2:-$RUN_DIR/04-patch-prompt.md}"
EDITOR_CANDIDATE="${3:-qwen}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
source "$PIPELINE_DIR/scripts/lib/policy.sh"
if [ -n "${PROJECT_PROFILE_FILE:-}" ] && [ -f "$PROJECT_PROFILE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$PROJECT_PROFILE_FILE"
fi

case "$EDITOR_CANDIDATE" in
  qwen)
    EDITOR_MODEL_ROLE="qwen_coder"
    ACTIVE_EDITOR_MODEL="$EDITOR_MODEL"
    EDITOR_API_PORT="$QWEN_CODER_PORT"
    ;;
  devstral)
    EDITOR_MODEL_ROLE="devstral"
    ACTIVE_EDITOR_MODEL="$EDITOR_CHALLENGER_MODEL"
    EDITOR_API_PORT="$DEVSTRAL_PORT"
    ;;
  *)
    echo "ERROR: unknown editor candidate: $EDITOR_CANDIDATE" >&2
    exit 1
    ;;
esac

echo "=== Stage 5: Editor ($EDITOR_CANDIDATE) ==="
echo "INFO: prompt: $PROMPT_FILE"
echo "INFO: worktree: $WORKTREE_PATH"
echo "INFO: editor role: $EDITOR_MODEL_ROLE"
echo "INFO: editor model: $ACTIVE_EDITOR_MODEL"

[ -f "$PROMPT_FILE" ] || { echo "ERROR: prompt file missing: $PROMPT_FILE" >&2; exit 1; }
[ -d "$WORKTREE_PATH/.git" ] || [ -f "$WORKTREE_PATH/.git" ] || { echo "ERROR: worktree missing: $WORKTREE_PATH" >&2; exit 1; }

policy_assert_local_editor_model

if [ "${TASK_MODE:-fix}" = "review" ]; then
  echo "ERROR: editor stage must never run in review-only mode" >&2
  exit 1
fi

extract_required_source_locations() {
  local prompt_file="${1:?prompt required}"
  awk '
    BEGIN { in_section=0 }
    /^## Required source locations/ { in_section=1; next }
    /^## / && in_section { exit }
    in_section && /^- / {
      line=$0
      sub(/^- /, "", line)
      gsub(/`/, "", line)
      split(line, parts, ":")
      symbol=parts[1]
      sub(/^[[:space:]]+/, "", symbol)
      sub(/[[:space:]]+$/, "", symbol)
      path=line
      sub(/^[^:]+:/, "", path)
      sub(/:[0-9]+(:.*)?$/, "", path)
      sub(/^[[:space:]]+/, "", path)
      sub(/[[:space:]]+$/, "", path)
      is_new=0
      if (symbol ~ /[[:space:]]*\((new|new helper)\)[[:space:]]*$/) {
        sub(/[[:space:]]*\((new|new helper)\)[[:space:]]*$/, "", symbol)
        is_new=1
      }
      if (symbol != "" && path != "") print symbol "\t" path "\t" is_new
    }
  ' "$prompt_file"
}

allowed_file_matches() {
  local file="${1:?file required}"
  local pattern
  for pattern in "${ALLOWED_FILES[@]:-}"; do
    case "$pattern" in
      "<"*|"("*) continue ;;
    esac
    if [ "$file" = "$pattern" ] || [[ "$file" == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

append_unique_aider_file() {
  local file="${1:?file required}"
  local existing
  for existing in "${AIDER_FILE_ARGV[@]:-}"; do
    [ "$existing" = "$file" ] && return 0
  done
  AIDER_FILE_ARGV+=("$file")
}

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

BASE_BEFORE="$(git rev-parse HEAD)"
if [ -n "${AGENT_BASE_COMMIT:-}" ] && [ "$BASE_BEFORE" != "$AGENT_BASE_COMMIT" ]; then
  echo "ERROR: worktree HEAD changed before editor stage. Expected $AGENT_BASE_COMMIT got $BASE_BEFORE" >&2
  exit 1
fi

MODEL_STARTED=0
cleanup() {
  if [ "$MODEL_STARTED" -eq 1 ]; then
    "$PIPELINE_DIR/scripts/model/stop.sh" "$EDITOR_MODEL_ROLE" || true
  fi
}
trap cleanup EXIT

"$PIPELINE_DIR/scripts/model/start.sh" "$EDITOR_MODEL_ROLE"
MODEL_STARTED=1

AIDER_EXTRA_ARGV=()
if [ -n "${AIDER_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  AIDER_EXTRA_ARGV=($AIDER_EXTRA_ARGS)
fi

AIDER_NONINTERACTIVE_ARGV=()
if "$AIDER_BIN" --help 2>/dev/null | grep -q -- '--yes-always'; then
  AIDER_NONINTERACTIVE_ARGV+=(--yes-always)
fi

mapfile -t ALLOWED_FILES < <(policy_extract_allowed_files "$PROMPT_FILE")
AIDER_FILE_ARGV=()
while IFS= read -r allowed_file; do
  [ -n "$allowed_file" ] || continue
  case "$allowed_file" in
    "<"*|"("*|*"*"*|*"?"*|*"["*)
      continue
      ;;
  esac
  if [ -e "$allowed_file" ]; then
    append_unique_aider_file "$allowed_file"
  fi
done < <(printf '%s\n' "${ALLOWED_FILES[@]:-}")

SOURCE_CHECK_OUT="$RUN_DIR/05-source-location-check.txt"
SOURCE_CHECK_FAILED=0
SOURCE_LOCATION_COUNT=0
{
  echo "# Source-location check"
  echo "Prompt: $PROMPT_FILE"
  echo "Editor candidate: $EDITOR_CANDIDATE"
  echo
} > "$SOURCE_CHECK_OUT"

while IFS=$'\t' read -r symbol source_file is_new_symbol; do
  [ -n "${symbol:-}" ] || continue
  SOURCE_LOCATION_COUNT=$((SOURCE_LOCATION_COUNT + 1))
  echo "- symbol=$symbol file=$source_file" >> "$SOURCE_CHECK_OUT"

  if [ ! -f "$source_file" ]; then
    echo "  FAIL: required source file does not exist" >> "$SOURCE_CHECK_OUT"
    SOURCE_CHECK_FAILED=1
    continue
  fi

  if ! allowed_file_matches "$source_file"; then
    echo "  FAIL: required source file is not present in Allowed files" >> "$SOURCE_CHECK_OUT"
    SOURCE_CHECK_FAILED=1
  fi

  if [ "${is_new_symbol:-0}" = "1" ]; then
    echo "  PASS: new symbol allowed; source file found" >> "$SOURCE_CHECK_OUT"
  elif grep -nF -- "$symbol" "$source_file" >> "$SOURCE_CHECK_OUT" 2>/dev/null; then
    echo "  PASS: symbol found" >> "$SOURCE_CHECK_OUT"
  else
    echo "  FAIL: symbol not found in required source file" >> "$SOURCE_CHECK_OUT"
    SOURCE_CHECK_FAILED=1
  fi

  append_unique_aider_file "$source_file"
done < <(extract_required_source_locations "$PROMPT_FILE")

if [ "$SOURCE_LOCATION_COUNT" -eq 0 ]; then
  echo "FAIL: no Required source locations section found in patch prompt" >> "$SOURCE_CHECK_OUT"
  SOURCE_CHECK_FAILED=1
fi

if [ "$SOURCE_CHECK_FAILED" -ne 0 ]; then
  cat "$SOURCE_CHECK_OUT" | tee "$RUN_DIR/05-agent-output.txt" >&2
  echo "2" > "$RUN_DIR/05-agent-exit-code.txt"
  exit 1
fi

if [ "${#AIDER_FILE_ARGV[@]}" -gt 0 ]; then
  printf 'INFO: Aider allowed/source file args:' | tee "$RUN_DIR/05-aider-files.txt"
  printf ' %s' "${AIDER_FILE_ARGV[@]}" | tee -a "$RUN_DIR/05-aider-files.txt"
  printf '\n' | tee -a "$RUN_DIR/05-aider-files.txt"
else
  echo "WARN: no exact existing allowed files found to pass to Aider" | tee "$RUN_DIR/05-aider-files.txt"
fi

EDITOR_API_BASE="http://127.0.0.1:${EDITOR_API_PORT}/v1"
policy_assert_local_api_base "$EDITOR_API_BASE"

set +e
AIDER_OPENAI_API_BASE="$EDITOR_API_BASE" \
OPENAI_API_KEY="local" \
timeout "${AIDER_TIMEOUT_SECONDS:-3600}" \
"$AIDER_BIN" \
  --model "$ACTIVE_EDITOR_MODEL" \
  --edit-format "$AIDER_EDIT_FORMAT" \
  --map-tokens "$AIDER_MAP_TOKENS" \
  --no-auto-commits \
  --no-dirty-commits \
  --no-gitignore \
  --no-show-model-warnings \
  --no-auto-lint \
  "${AIDER_NONINTERACTIVE_ARGV[@]}" \
  "${AIDER_EXTRA_ARGV[@]}" \
  "${AIDER_FILE_ARGV[@]}" \
  "${AIDER_PROMPT_ARGS[@]}" \
  2>&1 | tee "$RUN_DIR/05-agent-output.txt"
AIDER_EXIT=${PIPESTATUS[0]}
set -e

trap - EXIT
cleanup

BASE_AFTER="$(git rev-parse HEAD)"
{
  echo "# Editor policy result"
  echo "candidate=$EDITOR_CANDIDATE"
  echo "editor_role=$EDITOR_MODEL_ROLE"
  echo "editor_model=$ACTIVE_EDITOR_MODEL"
  echo "api_base=$EDITOR_API_BASE"
  echo "base_before=$BASE_BEFORE"
  echo "base_after=$BASE_AFTER"
  echo "aider_exit=$AIDER_EXIT"
} > "$RUN_DIR/05-editor-policy.txt"

if policy_bool_enabled "${ENFORCE_NO_AGENT_COMMITS:-1}" && [ "$BASE_AFTER" != "$BASE_BEFORE" ]; then
  echo "ERROR: editor changed HEAD; agents must not commit" | tee -a "$RUN_DIR/05-editor-policy.txt" >&2
  echo "$AIDER_EXIT" > "$RUN_DIR/05-agent-exit-code.txt"
  exit 1
fi

if [ "$AIDER_EXIT" -eq 124 ]; then
  echo "ERROR: Aider timed out after ${AIDER_TIMEOUT_SECONDS:-3600}s" | tee -a "$RUN_DIR/05-agent-output.txt" >&2
fi

echo "INFO: Aider exit code: $AIDER_EXIT" | tee -a "$RUN_DIR/05-agent-output.txt"
# Do not fail the whole harness just because aider exits non-zero; verifier/reviewer decide next.
echo "$AIDER_EXIT" > "$RUN_DIR/05-agent-exit-code.txt"
