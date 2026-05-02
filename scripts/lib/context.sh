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

repo_file_list() {
  local repo="$1"
  local max_files="${2:-80}"
  cd "$repo"
  git ls-files '*.rs' 'Cargo.toml' 'Cargo.lock' 2>/dev/null | sort | head -"$max_files"
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
    cat "$file"
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
      *.rs|Cargo.toml|Cargo.lock) ;;
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
    cat "$file"
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
    echo
    echo "## Git status"
    cd "$repo"
    git status --short || true
    echo
    echo "## Tracked Rust/Cargo files"
    git ls-files '*.rs' 'Cargo.toml' 'Cargo.lock' 2>/dev/null | sort
  } > "$out"
}
