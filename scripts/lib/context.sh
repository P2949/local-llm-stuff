#!/usr/bin/env bash

# Shared helper functions for stage prompt construction.
# Source from stage scripts; do not execute directly.

require_file() {
  local file="$1"
  [ -f "$file" ] || { echo "ERROR: required file missing: $file" >&2; exit 1; }
}

truncate_file() {
  local file="$1"
  local max_bytes="${2:-120000}"
  if [ ! -f "$file" ]; then
    echo "(missing: $file)"
    return 0
  fi
  local size
  size=$(wc -c < "$file" | tr -d ' ')
  if [ "$size" -le "$max_bytes" ]; then
    cat "$file"
  else
    echo "<!-- truncated: $file, first $max_bytes bytes of $size -->"
    head -c "$max_bytes" "$file"
    echo
    echo "<!-- end truncated content -->"
  fi
}

print_numbered_file() {
  local file="${1:?file required}"
  nl -ba "$file"
}

repo_file_list() {
  local repo="$1"
  local max_files="${2:-80}"
  cd "$repo"
  git ls-files '*.rs' 'Cargo.toml' 'Cargo.lock' 2>/dev/null | sort | head -"$max_files"
}

context_pack_files_for_task() {
  local task_file="${1:?task file required}"
  local task_text=""
  [ -f "$task_file" ] && task_text="$(cat "$task_file")"

  # Project-specific packs are optional and sourced from config/projects/*.env.
  if echo "$task_text" | grep -qiE 'ebpf|tracepoint|ringbuf|aya|abi|drop counter|map'; then
    printf '%s\n' ${CONTEXT_PACK_EBPF:-}
  fi
  if echo "$task_text" | grep -qiE 'tree|tid|pid|proc|cgroup|watch-process|process'; then
    printf '%s\n' ${CONTEXT_PACK_TRACKING:-}
  fi
  if echo "$task_text" | grep -qiE 'record|report|json|schema|spike|percentile|html|csv'; then
    printf '%s\n' ${CONTEXT_PACK_REPORT:-}
  fi
  if echo "$task_text" | grep -qiE 'affinity|profile|restore|taskset|cpu mask|sched_setaffinity'; then
    printf '%s\n' ${CONTEXT_PACK_AFFINITY:-}
  fi
  if echo "$task_text" | grep -qiE 'tune|score|candidate|mangohud|frametime'; then
    printf '%s\n' ${CONTEXT_PACK_TUNE:-}
  fi
}

extract_task_line_refs() {
  local task_file="${1:?task file required}"
  # Matches bullets like:
  # - stutter/src/main.rs:825: fn cleanup_stale_tune_run_dirs(...)
  # Emits: path<TAB>line
  grep -Eo '[[:alnum:]_./-]+\.(rs|toml|md|sh):[0-9]+' "$task_file" 2>/dev/null \
    | awk -F: '!seen[$1":"$2]++ { print $1 "\t" $2 }'
}

extract_required_source_locations() {
  local task_file="${1:?task file required}"
  # Matches bullets like:
  # - cleanup_stale_tune_run_dirs: stutter/src/main.rs
  # - stutter/src/main.rs
  # Emits: path<TAB>symbol-or-empty
  awk '
    BEGIN { in_section=0 }
    /^Required source locations:/ { in_section=1; next }
    /^Allowed files:/ { in_section=0 }
    in_section && /^-/ { print }
  ' "$task_file" 2>/dev/null \
    | sed -E 's/^-[[:space:]]*//' \
    | awk '
        /^[^:]+:[[:space:]]*[[:alnum:]_./-]+\.(rs|toml|md|sh)$/ {
          symbol=$0; sub(/:.*/, "", symbol);
          path=$0; sub(/^[^:]+:[[:space:]]*/, "", path);
          print path "\t" symbol;
          next;
        }
        /^[[:alnum:]_./-]+\.(rs|toml|md|sh)$/ {
          print $0 "\t";
        }
      ' \
    | awk '!seen[$1":"$2]++'
}

print_line_window() {
  local file="${1:?file required}"
  local line="${2:?line required}"
  local context="${3:-8}"
  local start=$((line - context))
  local end=$((line + context))
  [ "$start" -lt 1 ] && start=1
  sed -n "${start},${end}p" "$file" | nl -ba -v "$start"
}

print_symbol_context() {
  local file="${1:?file required}"
  local symbol="${2:?symbol required}"
  local context="${3:-8}"
  local first_line
  first_line="$(grep -n -E "(^|[^[:alnum:]_])${symbol}([^[:alnum:]_]|$)" "$file" 2>/dev/null | head -1 | cut -d: -f1 || true)"
  if [ -n "$first_line" ]; then
    print_line_window "$file" "$first_line" "$context"
  else
    echo "<!-- symbol not found in $file: $symbol -->"
  fi
}

pack_required_source_context() {
  local repo="$1"
  local task_file="${2:-}"
  local context="${3:-8}"
  local emitted=0
  local seen=" "

  [ -n "$task_file" ] || return 0
  [ -f "$task_file" ] || return 0
  cd "$repo"

  while IFS=$'\t' read -r path line; do
    [ -n "$path" ] || continue
    [ -f "$path" ] || continue
    local key="line:$path:$line"
    [[ "$seen" == *" $key "* ]] && continue
    seen="$seen$key "
    emitted=1
    echo
    echo "## REQUIRED SOURCE LINE: $path:$line"
    echo '```'
    print_line_window "$path" "$line" "$context"
    echo '```'
  done < <(extract_task_line_refs "$task_file")

  while IFS=$'\t' read -r path symbol; do
    [ -n "$path" ] || continue
    [ -f "$path" ] || continue
    if [ -n "$symbol" ]; then
      local key="symbol:$path:$symbol"
      [[ "$seen" == *" $key "* ]] && continue
      seen="$seen$key "
      emitted=1
      echo
      echo "## REQUIRED SOURCE SYMBOL: $symbol in $path"
      echo '```'
      print_symbol_context "$path" "$symbol" "$context"
      echo '```'
    else
      local key="file:$path"
      [[ "$seen" == *" $key "* ]] && continue
      seen="$seen$key "
      emitted=1
      echo
      echo "## REQUIRED SOURCE FILE HEAD: $path"
      echo '```'
      head -n $((context * 4)) "$path" | nl -ba
      echo '```'
    fi
  done < <(extract_required_source_locations "$task_file")

  if [ "$emitted" -eq 0 ]; then
    echo "(no exact required source snippets found in task prompt)"
  fi
}

pack_project_context_packs() {
  local repo="$1"
  local task_file="${2:-}"
  local max_bytes="${3:-80000}"
  local used=0
  local seen=" "

  [ -n "$task_file" ] || return 0
  cd "$repo"

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [[ "$seen" == *" $file "* ]] && continue
    seen="$seen$file "
    [ -f "$file" ] || continue
    local size
    size=$(wc -c < "$file" | tr -d ' ')
    if [ $((used + size)) -gt "$max_bytes" ]; then
      echo "<!-- project context pack budget reached at $used / $max_bytes bytes; skipped $file -->"
      break
    fi
    echo
    echo "## PROJECT CONTEXT FILE: $file"
    echo '```'
    print_numbered_file "$file"
    echo '```'
    used=$((used + size))
  done < <(context_pack_files_for_task "$task_file")
}

pack_repo_sources() {
  local repo="$1"
  local max_files="${2:-80}"
  local max_bytes="${3:-160000}"
  local used=0
  local count=0
  cd "$repo"
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    count=$((count + 1))
    [ "$count" -gt "$max_files" ] && break
    local size
    size=$(wc -c < "$file" | tr -d ' ')
    if [ $((used + size)) -gt "$max_bytes" ]; then
      echo
      echo "<!-- source context budget reached at $used / $max_bytes bytes; skipped $file and later files -->"
      break
    fi
    echo
    echo "## FILE: $file"
    echo '```'
    print_numbered_file "$file"
    echo '```'
    used=$((used + size))
  done < <(git ls-files '*.rs' 'Cargo.toml' 2>/dev/null | sort)
}

pack_touched_files() {
  local repo="$1"
  local diff_file="$2"
  local max_bytes="${3:-160000}"
  local used=0
  cd "$repo"
  if [ ! -s "$diff_file" ]; then
    echo "(no diff available)"
    return 0
  fi
  git diff --name-only | while IFS= read -r file; do
    [ -f "$file" ] || continue
    case "$file" in
      *.rs|Cargo.toml|Cargo.lock|*.md|*.toml|*.sh) ;;
      *) continue ;;
    esac
    local size
    size=$(wc -c < "$file" | tr -d ' ')
    if [ $((used + size)) -gt "$max_bytes" ]; then
      echo "<!-- touched-file context budget reached -->"
      break
    fi
    echo
    echo "## TOUCHED FILE: $file"
    echo '```'
    print_numbered_file "$file"
    echo '```'
    used=$((used + size))
  done
}

write_context_manifest() {
  local run_dir="$1"
  local repo="$2"
  local out="$run_dir/00-repo-map.md"
  {
    echo "# Repository Map"
    echo
    echo "Generated: $(date -Iseconds)"
    echo "Repository: $repo"
    echo "Project profile: ${PROJECT_PROFILE_NAME:-generic}"
    echo
    echo "## Git status"
    cd "$repo"
    git status --short || true
    echo
    echo "## Current branch and commit"
    echo "branch=$(git branch --show-current 2>/dev/null || true)"
    echo "commit=$(git rev-parse HEAD 2>/dev/null || true)"
    echo
    echo "## Tracked Rust/Cargo/shell/markdown files"
    git ls-files '*.rs' 'Cargo.toml' 'Cargo.lock' '*.sh' '*.md' '*.toml' 2>/dev/null | sort
  } > "$out"
}
