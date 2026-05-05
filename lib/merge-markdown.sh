#!/usr/bin/env bash
# dotfriend — managed Markdown block merge adapter
# shellcheck shell=bash

set -euo pipefail

merge_markdown_apply() {
  local source_file="" target_file="" artifact_id="" dry_run=false approved=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source) source_file="$2"; shift 2 ;;
      --target) target_file="$2"; shift 2 ;;
      --artifact-id) artifact_id="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      --approved) approved=true; shift ;;
      *) printf 'unknown merge-markdown flag: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  [[ -n "$source_file" && -n "$target_file" && -n "$artifact_id" ]] || return 2
  [[ -f "$source_file" ]] || { printf 'source Markdown missing: %s\n' "$source_file" >&2; return 1; }

  local start_marker end_marker count current block
  start_marker="<!-- dotfriend:start id=\"${artifact_id}\" -->"
  end_marker="<!-- dotfriend:end id=\"${artifact_id}\" -->"
  current=""
  [[ -f "$target_file" ]] && current="$(cat "$target_file")"
  count="$(printf '%s\n' "$current" | grep -cF "$start_marker" 2>/dev/null || true)"

  if [[ "$count" -gt 1 ]]; then
    printf 'duplicate managed Markdown block: %s\n' "$artifact_id" >&2
    return 1
  fi
  if [[ "$count" -eq 0 && "$approved" != true ]]; then
    printf 'refusing to append unapproved Markdown block: %s\n' "$artifact_id" >&2
    return 1
  fi

  block="$(mktemp)"
  {
    printf '%s\n' "$start_marker"
    cat "$source_file"
    printf '\n%s\n' "$end_marker"
  } > "$block"

  if [[ "$dry_run" == true ]]; then
    local action="append_block"
    [[ "$count" -eq 1 ]] && action="replace_block"
    printf '{"action":"%s","target_path":"%s","artifact_id":"%s"}\n' "$action" "$target_file" "$artifact_id"
    rm -f "$block"
    return 0
  fi

  mkdir -p "$(dirname "$target_file")"
  local tmp
  tmp="$(mktemp)"
  if [[ "$count" -eq 1 ]]; then
    awk -v start="$start_marker" -v end="$end_marker" -v block_file="$block" '
      $0 == start {
        while ((getline line < block_file) > 0) print line
        close(block_file)
        in_block=1
        next
      }
      in_block && $0 == end { in_block=0; next }
      !in_block { print }
    ' "$target_file" > "$tmp"
  else
    [[ -f "$target_file" ]] && cat "$target_file" > "$tmp"
    [[ -s "$tmp" ]] && printf '\n' >> "$tmp"
    cat "$block" >> "$tmp"
  fi
  mv "$tmp" "$target_file"
  rm -f "$block"
}
