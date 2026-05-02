#!/usr/bin/env bash

# Shared policy/enforcement helpers. Source this file from pipeline scripts.

policy_bool_enabled() {
  case "${1:-}" in
    1|yes|true|on|ON|TRUE|YES) return 0 ;;
    *) return 1 ;;
  esac
}

policy_source_project_profile() {
  local repo="${1:?repo path required}"
  local profile_dir="${PROJECT_PROFILE_DIR:-}"
  [ -n "$profile_dir" ] || return 0

  local name
  name="$(basename "$repo")"
  local profile="$profile_dir/$name.env"
  if [ -f "$profile" ]; then
    # shellcheck source=/dev/null
    source "$profile"
    export PROJECT_PROFILE_FILE="$profile"
    export PROJECT_PROFILE_NAME="${PROJECT_PROFILE_NAME:-$name}"
  else
    export PROJECT_PROFILE_FILE=""
    export PROJECT_PROFILE_NAME="generic"
  fi
}

policy_toolchain_env() {
  if policy_bool_enabled "${VERIFY_USE_RUSTUP_TOOLCHAIN:-0}" && [ -n "${VERIFY_RUSTUP_TOOLCHAIN:-}" ]; then
    printf 'RUSTUP_TOOLCHAIN=%s\n' "$VERIFY_RUSTUP_TOOLCHAIN"
  fi
}

policy_run_shell_cmd() {
  local label="$1"; shift
  local outfile="$1"; shift
  local mode="${1:-hard}"; shift || true
  local command_text="$*"

  {
    echo "# $label"
    echo "mode=$mode"
    echo "cwd=$(pwd)"
    echo "command=$command_text"
    echo
  } > "$outfile"

  local status=0
  set +e
  if policy_bool_enabled "${VERIFY_USE_RUSTUP_TOOLCHAIN:-0}" && [ -n "${VERIFY_RUSTUP_TOOLCHAIN:-}" ]; then
    RUSTUP_TOOLCHAIN="$VERIFY_RUSTUP_TOOLCHAIN" bash -lc "$command_text" >> "$outfile" 2>&1
  else
    bash -lc "$command_text" >> "$outfile" 2>&1
  fi
  status=$?
  set -e

  return "$status"
}

policy_assert_local_editor_model() {
  [ "${ENFORCE_LOCAL_EDITOR_ONLY:-1}" = "1" ] || return 0

  local model="${ACTIVE_EDITOR_MODEL:-}"
  local allowed=" ${LOCAL_EDITOR_MODEL_ALLOWLIST:-} "
  if [[ "$allowed" != *" $model "* ]]; then
    echo "ERROR: ACTIVE_EDITOR_MODEL is not in LOCAL_EDITOR_MODEL_ALLOWLIST: $model" >&2
    echo "Allowed: ${LOCAL_EDITOR_MODEL_ALLOWLIST:-}" >&2
    return 1
  fi

  if [[ "${model:-}" != openai/* ]]; then
    echo "ERROR: editor model must use the local OpenAI-compatible endpoint namespace: $model" >&2
    return 1
  fi
}

policy_assert_local_api_base() {
  [ "${ENFORCE_LOCAL_EDITOR_ONLY:-1}" = "1" ] || return 0
  local api_base="${1:-}"
  local prefix="${LOCAL_EDITOR_API_BASE_PREFIX:-http://127.0.0.1:}"
  if [[ "$api_base" != "$prefix"* ]]; then
    echo "ERROR: editor API base is not local-only: $api_base" >&2
    return 1
  fi
}

policy_write_manifest() {
  local run_dir="${1:?run dir required}"
  local out="$run_dir/00-policy.md"

  {
    echo "# Pipeline Policy Manifest"
    echo
    echo "Generated: $(date -Iseconds)"
    echo "Project profile: ${PROJECT_PROFILE_NAME:-generic}"
    if [ -n "${PROJECT_PROFILE_FILE:-}" ]; then
      echo "Project profile file: $PROJECT_PROFILE_FILE"
    fi
    echo
    echo "## Enforced 16-step rules"
    echo "1. Use separate review and feature/fix workflows."
    echo "2. Define quality through correctness, tests, safety, maintainability, overhead, observability, and dependency hygiene."
    echo "3. Hard-gate every patch with formatter, build, clippy, and tests."
    echo "4. Start from a mechanical baseline and architecture/context map."
    echo "5. Use local models only for file editing; read-only models may only plan/review."
    echo "6. Use finder -> challenge -> accepted-items -> patch-writer -> editor -> verifier -> reviewer loop."
    echo "7. Enforce role permissions; only Stage 5 may edit the isolated worktree."
    echo "8. Apply subsystem-specific review addenda when a project profile exists."
    echo "9. Run optional quality tools and record them."
    echo "10. Source project-specific harness rules and context packs."
    echo "11. Use an isolated llm/agent-* worktree branch; no direct main/master edits."
    echo "12. Keep patches small and scoped; enforce changed-file limits."
    echo "13. Feature prompts must include behavior, non-goals, compatibility, and tests."
    echo "14. Review-only mode stops before edits and outputs accepted findings."
    echo "15. Final approval means human inspection, not automatic merge."
    echo "16. Deterministic tools outrank LLM claims; shell logs are the source of truth."
    echo
    echo "## Active gates"
    echo "- ENFORCE_16_STEP_POLICY=${ENFORCE_16_STEP_POLICY:-1}"
    echo "- ENFORCE_LOCAL_EDITOR_ONLY=${ENFORCE_LOCAL_EDITOR_ONLY:-1}"
    echo "- ENFORCE_NO_AGENT_COMMITS=${ENFORCE_NO_AGENT_COMMITS:-1}"
    echo "- ENFORCE_ALLOWED_FILES=${ENFORCE_ALLOWED_FILES:-1}"
    echo "- ENFORCE_PATCH_SIZE_LIMIT=${ENFORCE_PATCH_SIZE_LIMIT:-1}"
    echo "- ENFORCE_FEATURE_TEST_CHANGE=${ENFORCE_FEATURE_TEST_CHANGE:-1}"
    echo "- ENFORCE_HARD_VERIFY_GATES=${ENFORCE_HARD_VERIFY_GATES:-1}"
    echo "- ENFORCE_SECOND_OPINION_ON_RISK=${ENFORCE_SECOND_OPINION_ON_RISK:-1}"
    echo "- ENFORCE_HUMAN_MERGE_ONLY=${ENFORCE_HUMAN_MERGE_ONLY:-1}"
    echo
    echo "## Verification commands"
    echo "- Toolchain: ${VERIFY_RUSTUP_TOOLCHAIN:-system}"
    echo "- fmt: ${VERIFY_FMT_CMD:-cargo fmt --check}"
    echo "- build: ${VERIFY_BUILD_CMD:-cargo build}"
    echo "- clippy: ${VERIFY_CLIPPY_CMD:-cargo clippy --all-targets -- -D warnings}"
    echo "- test: ${VERIFY_TEST_CMD:-cargo test}"
    echo "- workspace test: ${VERIFY_WORKSPACE_TEST_CMD:-cargo test --workspace}"
    echo
    echo "## Patch limits"
    echo "- MAX_CHANGED_FILES=${MAX_CHANGED_FILES:-5}"
    echo "- MAX_CHANGED_SOURCE_FILES=${MAX_CHANGED_SOURCE_FILES:-5}"
    echo "- MAX_DIFF_BYTES_FOR_APPROVAL=${MAX_DIFF_BYTES_FOR_APPROVAL:-120000}"
  } > "$out"
}

policy_extract_allowed_files() {
  local prompt_file="${1:?prompt required}"
  awk '
    BEGIN { in_allowed=0 }
    /^## Allowed files/ { in_allowed=1; next }
    /^## / && in_allowed { exit }
    in_allowed && /^- / {
      sub(/^- /, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if ($0 != "") print $0
    }
  ' "$prompt_file"
}

policy_check_allowed_files() {
  local run_dir="${1:?run dir required}"
  local prompt_file="${2:?prompt file required}"
  local diff_file="$run_dir/06-diff.patch"
  local out="$run_dir/06-allowed-files.txt"

  if ! policy_bool_enabled "${ENFORCE_ALLOWED_FILES:-1}"; then
    echo "SKIP: ENFORCE_ALLOWED_FILES disabled" > "$out"
    return 0
  fi

  mapfile -t allowed < <(policy_extract_allowed_files "$prompt_file")
  if [ "${#allowed[@]}" -eq 0 ]; then
    echo "FAIL: no Allowed files section found in patch prompt" > "$out"
    return 1
  fi

  local failed=0
  {
    echo "# Allowed-file check"
    echo "Prompt: $prompt_file"
    echo
    echo "Allowed files:"
    printf -- '- %s\n' "${allowed[@]}"
    echo
    echo "Changed files:"
  } > "$out"

  if [ ! -s "$diff_file" ]; then
    echo "(no diff)" >> "$out"
    return 0
  fi

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    echo "- $file" >> "$out"
    local ok=1
    local pattern
    for pattern in "${allowed[@]}"; do
      case "$pattern" in
        "<"*|"("*) continue ;;
      esac
      if [ "$file" = "$pattern" ] || [[ "$file" == $pattern ]]; then
        ok=0
        break
      fi
    done
    if [ "$ok" -ne 0 ]; then
      echo "FAIL: changed file not allowed by patch prompt: $file" >> "$out"
      failed=1
    fi
  done < <(cd "$WORKTREE_PATH" && git diff --name-only)

  return "$failed"
}

policy_check_patch_size() {
  local run_dir="${1:?run dir required}"
  local out="$run_dir/06-patch-size.txt"

  if ! policy_bool_enabled "${ENFORCE_PATCH_SIZE_LIMIT:-1}"; then
    echo "SKIP: ENFORCE_PATCH_SIZE_LIMIT disabled" > "$out"
    return 0
  fi

  local changed source_changed diff_bytes failed=0
  changed=$(cd "$WORKTREE_PATH" && git diff --name-only | sed '/^$/d' | wc -l | tr -d ' ')
  source_changed=$(cd "$WORKTREE_PATH" && git diff --name-only -- '*.rs' 'Cargo.toml' 'Cargo.lock' 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')
  diff_bytes=$(wc -c < "$run_dir/06-diff.patch" 2>/dev/null | tr -d ' ')
  diff_bytes="${diff_bytes:-0}"

  {
    echo "# Patch-size check"
    echo "changed_files=$changed limit=${MAX_CHANGED_FILES:-5}"
    echo "changed_source_files=$source_changed limit=${MAX_CHANGED_SOURCE_FILES:-5}"
    echo "diff_bytes=$diff_bytes limit=${MAX_DIFF_BYTES_FOR_APPROVAL:-120000}"
  } > "$out"

  if [ "$changed" -gt "${MAX_CHANGED_FILES:-5}" ]; then
    echo "FAIL: too many changed files" >> "$out"
    failed=1
  fi
  if [ "$source_changed" -gt "${MAX_CHANGED_SOURCE_FILES:-5}" ]; then
    echo "FAIL: too many changed Rust/Cargo files" >> "$out"
    failed=1
  fi
  if [ "$diff_bytes" -gt "${MAX_DIFF_BYTES_FOR_APPROVAL:-120000}" ]; then
    echo "FAIL: diff too large for automatic approval" >> "$out"
    failed=1
  fi

  return "$failed"
}

policy_check_feature_tests() {
  local run_dir="${1:?run dir required}"
  local out="$run_dir/06-feature-tests.txt"

  if [ "${TASK_MODE:-fix}" != "feature" ] || ! policy_bool_enabled "${FEATURE_REQUIRE_TEST_CHANGES:-1}"; then
    echo "SKIP: not a feature run or FEATURE_REQUIRE_TEST_CHANGES disabled" > "$out"
    return 0
  fi

  local changed_source
  changed_source=$(cd "$WORKTREE_PATH" && git diff --name-only -- '*.rs' 'Cargo.toml' 'Cargo.lock' 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "${changed_source:-0}" -eq 0 ]; then
    echo "SKIP: feature run has no Rust/Cargo source changes" > "$out"
    return 0
  fi

  local regex="${TEST_CHANGE_PATTERNS:-tests/|#\[test\]|mod tests}"
  {
    echo "# Feature test-change check"
    echo "pattern=$regex"
  } > "$out"

  if (cd "$WORKTREE_PATH" && git diff --name-only && git diff) | grep -Eq "$regex"; then
    echo "PASS: feature patch appears to include test coverage" >> "$out"
    return 0
  fi

  echo "FAIL: feature source patch does not appear to add/update tests" >> "$out"
  return 1
}

policy_check_no_agent_commits() {
  local run_dir="${1:?run dir required}"
  local out="$run_dir/06-no-agent-commits.txt"
  if ! policy_bool_enabled "${ENFORCE_NO_AGENT_COMMITS:-1}"; then
    echo "SKIP: ENFORCE_NO_AGENT_COMMITS disabled" > "$out"
    return 0
  fi

  local expected="${AGENT_BASE_COMMIT:-}"
  local current
  current=$(cd "$WORKTREE_PATH" && git rev-parse HEAD)
  {
    echo "# No-agent-commit check"
    echo "expected_head=$expected"
    echo "current_head=$current"
  } > "$out"

  if [ -n "$expected" ] && [ "$current" != "$expected" ]; then
    echo "FAIL: editor changed HEAD; agents must not commit" >> "$out"
    return 1
  fi

  echo "PASS: HEAD unchanged" >> "$out"
  return 0
}

policy_quality_scorecard() {
  local run_dir="${1:?run dir required}"
  local out="$run_dir/06-quality-scorecard.md"
  local final_status="${2:-UNKNOWN}"

  cat > "$out" <<EOF_SCORE
# Quality Scorecard

Final verification status: $final_status

| Area | Weight | Harness signal |
|---|---:|---|
| Correctness | 30% | build/test/workspace-test results |
| Regression coverage | 20% | cargo test and feature test-change gate |
| Safety | 15% | allowed-file, no-agent-commit, risky-diff second opinion |
| Maintainability | 15% | fmt/clippy/patch-size limits |
| Performance/overhead | 10% | project-specific reviewer checklist and optional benchmarks |
| Observability | 5% | review checklist and artifact/schema checks |
| Dependency/build hygiene | 5% | audit/deny/machete/optional tools |

This scorecard is a gate summary, not a merge decision. APPROVED means ready for human inspection only.
EOF_SCORE
}
