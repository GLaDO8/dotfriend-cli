#!/usr/bin/env bash
# dotfriend — managed JSON merge adapter
# shellcheck shell=bash

set -euo pipefail

merge_json_validate_path() {
  local json_path="$1"
  [[ -n "$json_path" ]] || return 1
  [[ "$json_path" != /* ]] || return 1
  [[ "$json_path" != *..* ]] || return 1
}

merge_json_apply() {
  local source_file="" target_file="" json_path="" artifact_id="" dry_run=false approved=false ownership="managed_partial"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source) source_file="$2"; shift 2 ;;
      --target) target_file="$2"; shift 2 ;;
      --json-path) json_path="$2"; shift 2 ;;
      --artifact-id) artifact_id="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      --approved) approved=true; shift ;;
      --ownership) ownership="$2"; shift 2 ;;
      *) printf 'unknown merge-json flag: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  [[ -n "$source_file" && -n "$target_file" && -n "$json_path" && -n "$artifact_id" ]] || return 2
  command -v jq >/dev/null 2>&1 || { printf 'jq is required for managed JSON merge\n' >&2; return 1; }
  merge_json_validate_path "$json_path" || { printf 'unsafe json_path: %s\n' "$json_path" >&2; return 1; }
  [[ -f "$source_file" ]] || { printf 'source JSON missing: %s\n' "$source_file" >&2; return 1; }
  jq -e . "$source_file" >/dev/null || return 1

  local target_exists=false
  if [[ -f "$target_file" ]]; then
    target_exists=true
    jq -e . "$target_file" >/dev/null || return 1
  fi

  if [[ "$ownership" == "dotfriend_full_file" ]]; then
    if [[ "$dry_run" == true ]]; then
      printf '{"action":"replace_file","target_path":"%s","artifact_id":"%s"}\n' "$target_file" "$artifact_id"
      return 0
    fi
    mkdir -p "$(dirname "$target_file")"
    [[ "$target_exists" == true ]] && cp "$target_file" "${target_file}.dotfriend.bak"
    local tmp_full
    tmp_full="$(mktemp)"
    cp "$source_file" "$tmp_full"
    mv "$tmp_full" "$target_file"
    return 0
  fi

  local current="{}"
  [[ "$target_exists" == true ]] && current="$(cat "$target_file")"

  local existing_managed
  existing_managed="$(jq -r --arg p "$json_path" '
    getpath($p | split("."))? |
    if type == "object" then
      ((._managed_by == "dotfriend") and (._dotfriend_artifact_id // "" | length > 0))
    else false end
  ' <<< "$current")"

  if [[ "$target_exists" == true && "$existing_managed" != "true" && "$approved" != true ]]; then
    local path_exists
    path_exists="$(jq -r --arg p "$json_path" 'getpath($p | split("."))? != null' <<< "$current")"
    if [[ "$path_exists" == "true" ]]; then
      printf 'refusing to replace unmanaged JSON entry: %s\n' "$json_path" >&2
      return 1
    fi
  fi

  local managed_entry
  managed_entry="$(jq -c --arg artifact_id "$artifact_id" '. + {_managed_by:"dotfriend", _dotfriend_artifact_id:$artifact_id}' "$source_file")"

  if [[ "$dry_run" == true ]]; then
    local action="add_entry"
    [[ "$existing_managed" == "true" ]] && action="replace_entry"
    printf '{"action":"%s","target_path":"%s","json_path":"%s","artifact_id":"%s"}\n' "$action" "$target_file" "$json_path" "$artifact_id"
    return 0
  fi

  mkdir -p "$(dirname "$target_file")"
  [[ "$target_exists" == true ]] && cp "$target_file" "${target_file}.dotfriend.bak"
  local tmp
  tmp="$(mktemp)"
  jq --arg p "$json_path" --argjson value "$managed_entry" '
    setpath($p | split("."); $value)
  ' <<< "$current" > "$tmp"
  mv "$tmp" "$target_file"
}
