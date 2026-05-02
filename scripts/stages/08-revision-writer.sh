#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: 08-revision-writer.sh <run-dir>}"
source "$RUN_DIR/00-meta.env"
source "$PIPELINE_DIR/config/models.env"
source "$PIPELINE_DIR/config/pipeline.env"
source "$PIPELINE_DIR/scripts/lib/context.sh"

echo "=== Stage 8: Revision Writer ==="

OUTPUT_FILE="$RUN_DIR/04-revision-prompt-${ITERATION}.md"
USER_PROMPT_FILE="/tmp/llm-pipeline-revision-user-$RUN_ID.md"

{
  echo "# Original task"
  cat "$RUN_DIR/00-task.md"
  echo
  echo "# Accepted items (authoritative)"
  cat "$RUN_DIR/03-accepted-issues.md"
  echo
  echo "# Original patch prompt"
  cat "$RUN_DIR/04-patch-prompt.md"
  echo
  echo "# Harness verification result"
  cat "$RUN_DIR/05-agent-result.md" 2>/dev/null || true
  echo
  echo "# Diff reviewed"
  truncate_file "$RUN_DIR/06-diff.patch" 100000
  echo
  echo "# Review output"
  cat "$RUN_DIR/07-review.md" 2>/dev/null || echo "(no review; verification was BLOCKED)"
  echo
  echo "# Clippy output"
  tail -"$CONTEXT_MAX_COMMAND_LINES" "$RUN_DIR/06-clippy.txt" 2>/dev/null || true
  echo
  echo "# Test output"
  tail -"$CONTEXT_MAX_COMMAND_LINES" "$RUN_DIR/06-test.txt" 2>/dev/null || true
  echo
  echo "Write a narrow revision prompt. Do not broaden scope."
} > "$USER_PROMPT_FILE"

"$PIPELINE_DIR/scripts/model/start.sh" qwen27b
"$PIPELINE_DIR/scripts/model/ask.sh" "$QWEN27B_PORT" "$PIPELINE_DIR/prompts/patch-writer-revision.md" "$USER_PROMPT_FILE" "$OUTPUT_FILE"
"$PIPELINE_DIR/scripts/model/stop.sh" qwen27b
rm -f "$USER_PROMPT_FILE"

echo "INFO: revision prompt -> $OUTPUT_FILE"
