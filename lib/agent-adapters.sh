#!/usr/bin/env bash
# dotfriend — agent artifact adapter dispatch
# shellcheck shell=bash

set -euo pipefail

AGENT_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=merge-json.sh
source "${AGENT_ADAPTER_DIR}/merge-json.sh"
# shellcheck source=merge-markdown.sh
source "${AGENT_ADAPTER_DIR}/merge-markdown.sh"

agent_expand_home_path() {
  local path="$1"
  path="${path/#\~/$HOME}"
  path="${path/#\$HOME/$HOME}"
  printf '%s' "$path"
}

agent_adapter_apply_artifact() {
  local repo_dir="$1" artifact_json="$2" dry_run="${3:-false}" approved="${4:-false}"
  local id strategy source_type repo_path ownership target_json target_path json_path source_file

  id="$(jq -r '.id' <<< "$artifact_json")"
  strategy="$(jq -r '.install.strategy' <<< "$artifact_json")"
  source_type="$(jq -r '.source.type // empty' <<< "$artifact_json")"
  repo_path="$(jq -r '.source.repo_path // empty' <<< "$artifact_json")"
  ownership="$(jq -r '.ownership // "managed_partial"' <<< "$artifact_json")"
  source_file="${repo_dir}/${repo_path}"

  case "$strategy" in
    managed_json_merge)
      [[ "$source_type" == "inline_json" || "$source_type" == "repo_file" ]] || return 1
      while IFS= read -r target_json; do
        [[ -n "$target_json" ]] || continue
        target_path="$(agent_expand_home_path "$(jq -r '.path' <<< "$target_json")")"
        json_path="$(jq -r '.json_path' <<< "$target_json")"
        merge_json_apply --source "$source_file" --target "$target_path" --json-path "$json_path" --artifact-id "$id" --ownership "$ownership" $([[ "$dry_run" == true ]] && printf -- '--dry-run ') $([[ "$approved" == true ]] && printf -- '--approved ')
      done < <(jq -c '.targets[]?' <<< "$artifact_json")
      ;;
    managed_markdown_block)
      while IFS= read -r target_json; do
        [[ -n "$target_json" ]] || continue
        target_path="$(agent_expand_home_path "$(jq -r '.path' <<< "$target_json")")"
        merge_markdown_apply --source "$source_file" --target "$target_path" --artifact-id "$id" $([[ "$dry_run" == true ]] && printf -- '--dry-run ') $([[ "$approved" == true ]] && printf -- '--approved ')
      done < <(jq -c '.targets[]?' <<< "$artifact_json")
      ;;
    copy_managed_file)
      while IFS= read -r target_json; do
        target_path="$(agent_expand_home_path "$(jq -r '.path' <<< "$target_json")")"
        if [[ "$dry_run" == true ]]; then
          jq -cn --arg action "copy_file" --arg target_path "$target_path" --arg artifact_id "$id" '{action:$action,target_path:$target_path,artifact_id:$artifact_id}'
        else
          mkdir -p "$(dirname "$target_path")"
          cp "$source_file" "$target_path"
        fi
      done < <(jq -c '.targets[]?' <<< "$artifact_json")
      ;;
    rsync_managed_dir|symlink_shared_store|manual_followup)
      if [[ "$dry_run" == true ]]; then
        jq -cn --arg action "$strategy" --arg artifact_id "$id" '{action:$action,artifact_id:$artifact_id}'
      fi
      ;;
    *)
      printf 'unknown artifact install strategy: %s\n' "$strategy" >&2
      return 1
      ;;
  esac
}
