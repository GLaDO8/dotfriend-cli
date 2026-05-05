#!/usr/bin/env bash
# dotfriend — backend status and plan helpers
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=api.sh
source "${SCRIPT_DIR}/api.sh"
# shellcheck source=manifest.sh
source "${SCRIPT_DIR}/manifest.sh"

status_find_repo() {
  local repo=""
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
    return 0
  fi

  local cache_file="${DOTFRIEND_CACHE_DIR}/last-sync.json"
  if [[ -f "$cache_file" ]] && command -v jq >/dev/null 2>&1; then
    repo="$(jq -r '.repo_dir // empty' "$cache_file" 2>/dev/null || true)"
    if [[ -n "$repo" && -d "$repo" ]]; then
      printf '%s\n' "$repo"
      return 0
    fi
  fi

  if [[ -d "${HOME}/dotfiles" ]]; then
    printf '%s\n' "${HOME}/dotfiles"
    return 0
  fi
  return 1
}

status_manifest_drift_json() {
  local repo_dir="$1" manifest_file="$2"
  local drift_json="[]"
  local item_json item_id repo_path target_path repo_source live_target drift_item

  while IFS= read -r item_json; do
    [[ -n "$item_json" ]] || continue
    item_id="$(jq -r '.id' <<< "$item_json")"
    repo_path="$(jq -r '.repo_path // empty' <<< "$item_json")"
    target_path="$(jq -r '.target_path // empty' <<< "$item_json")"

    if [[ -n "$repo_path" ]]; then
      repo_source="${repo_dir}/${repo_path}"
      if [[ ! -e "$repo_source" ]]; then
        drift_item="$(jq -cn --arg code "missing_repo_source" --arg item_id "$item_id" --arg repo_path "$repo_path" --arg message "Managed repo source is missing." '{code:$code,item_id:$item_id,repo_path:$repo_path,message:$message}')"
        drift_json="$(jq -c --argjson item "$drift_item" '. + [$item]' <<< "$drift_json")"
      fi
    fi

    if [[ -n "$target_path" ]]; then
      live_target="${target_path/#\~/$HOME}"
      live_target="${live_target/#\$HOME/$HOME}"
      if [[ ! -e "$live_target" ]]; then
        drift_item="$(jq -cn --arg code "missing_live_target" --arg item_id "$item_id" --arg target_path "$target_path" --arg message "Live target is missing." '{code:$code,item_id:$item_id,target_path:$target_path,message:$message}')"
        drift_json="$(jq -c --argjson item "$drift_item" '. + [$item]' <<< "$drift_json")"
      fi
    fi
  done < <(jq -c '.items[]? | select(.selected != false)' "$manifest_file")

  printf '%s\n' "$drift_json"
}

status_data_json() {
  local mode="${1:-status}"
  local repo_dir=""
  local manifest_file=""
  local manifest_found=false
  local manifest_schema_version=null
  local drift_json="[]"
  local warnings_json="[]"
  local items_count=0
  local last_sync_json="{}"

  if repo_dir="$(status_find_repo 2>/dev/null)"; then
    manifest_file="${repo_dir}/.dotfriend/restore-manifest.json"
  else
    warnings_json="[$(api_warning "managed_repo_missing" "No generated dotfiles repo could be found." "{}")]"
  fi

  if [[ -n "$repo_dir" && -f "$manifest_file" ]]; then
    manifest_found=true
    if manifest_validate "$manifest_file" 2>/dev/null; then
      manifest_schema_version="$(jq -r '.schema_version' "$manifest_file")"
      items_count="$(jq -r '.items | length' "$manifest_file")"
      drift_json="$(status_manifest_drift_json "$repo_dir" "$manifest_file")"
    else
      warnings_json="[$(api_warning "manifest_schema_error" "Restore manifest failed validation." "{}")]"
      drift_json='[{"code":"manifest_schema_error","message":"Restore manifest failed validation."}]'
    fi
  elif [[ -n "$repo_dir" ]]; then
    warnings_json="[$(api_warning "manifest_missing" "Generated repo has no restore manifest; legacy behavior applies." "{}")]"
  fi

  local last_sync_file="${DOTFRIEND_CACHE_DIR}/last-sync.json"
  if [[ -f "$last_sync_file" ]]; then
    last_sync_json="$(jq -c '.' "$last_sync_file" 2>/dev/null || printf '{}')"
  fi

  jq -n \
    --arg mode "$mode" \
    --arg repo_dir "$repo_dir" \
    --argjson manifest_found "$manifest_found" \
    --argjson manifest_schema_version "$manifest_schema_version" \
    --argjson last_sync "$last_sync_json" \
    --argjson warnings "$warnings_json" \
    --argjson drift "$drift_json" \
    --argjson items_count "$items_count" \
    '{
      managed_repo: $repo_dir,
      manifest_found: $manifest_found,
      manifest_schema_version: $manifest_schema_version,
      last_sync: $last_sync,
      counts: {
        items: $items_count,
        warnings: ($warnings | length),
        drift: ($drift | length)
      },
      drift: $drift,
      _warnings: $warnings
    }
    + (if $mode == "plan" then {
      planned_actions: ($drift | map({
        item_id: .item_id,
        action: (if .code == "missing_repo_source" then "backup_live_target" elif .code == "missing_live_target" then "restore_repo_source" else "inspect" end),
        reason: .code
      }))
    } else {} end)'
}

status_print_json() {
  local command="$1"
  local data_json warnings_json status
  data_json="$(status_data_json "$command")"
  warnings_json="$(jq -c '._warnings // []' <<< "$data_json")"
  data_json="$(jq -c 'del(._warnings)' <<< "$data_json")"
  status="ok"
  if [[ "$(jq -r '.counts.warnings' <<< "$data_json")" != "0" ]]; then
    status="warning"
  fi
  api_print_envelope "$status" "$command" "$data_json" "$warnings_json" "[]"
}
