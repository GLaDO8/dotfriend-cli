#!/usr/bin/env bash
# dotfriend — agent artifact manifests and backend commands
# shellcheck shell=bash

set -euo pipefail

AGENT_ARTIFACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${AGENT_ARTIFACT_DIR}/common.sh"
# shellcheck source=api.sh
source "${AGENT_ARTIFACT_DIR}/api.sh"
# shellcheck source=status.sh
source "${AGENT_ARTIFACT_DIR}/status.sh"
# shellcheck source=agent-adapters.sh
source "${AGENT_ARTIFACT_DIR}/agent-adapters.sh"

AGENT_ARTIFACT_ALLOWED_KINDS='["mcp","skill","instruction","rule","command","agent","secret_ref"]'
AGENT_ARTIFACT_ALLOWED_SCOPES='["user","project","shared"]'
AGENT_ARTIFACT_ALLOWED_STRATEGIES='["managed_json_merge","managed_markdown_block","copy_managed_file","rsync_managed_dir","symlink_shared_store","manual_followup"]'

agent_artifacts_file_for_repo() {
  printf '%s/.dotfriend/agent-artifacts.json' "$1"
}

agent_artifacts_validate() {
  local artifacts_file="$1"
  [[ -f "$artifacts_file" ]] || { printf 'agent artifacts missing: %s\n' "$artifacts_file" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'jq is required to validate agent artifacts\n' >&2; return 1; }

  jq -e \
    --argjson kinds "$AGENT_ARTIFACT_ALLOWED_KINDS" \
    --argjson scopes "$AGENT_ARTIFACT_ALLOWED_SCOPES" \
    --argjson strategies "$AGENT_ARTIFACT_ALLOWED_STRATEGIES" '
      .schema_version == 1
      and (.artifacts | type == "array")
      and all(.artifacts[]?;
        (.id | type == "string" and length > 0)
        and (.kind as $kind | $kinds | index($kind) != null)
        and (.name | type == "string" and length > 0)
        and (.tools | type == "array")
        and (.scope as $scope | $scopes | index($scope) != null)
        and (.source.type | type == "string")
        and ((.source.repo_path // "") | type == "string")
        and ((.source.repo_path // "") | startswith("/") | not)
        and ((.source.repo_path // "") | contains("..") | not)
        and (.install.strategy as $strategy | $strategies | index($strategy) != null)
        and (.targets | type == "array")
        and (.managed_by == "dotfriend")
        and ((.ownership // "managed_partial") | IN("managed_partial","dotfriend_full_file"))
      )
    ' "$artifacts_file" >/dev/null
}

agent_artifacts_write_for_generated_repo() {
  local repo_dir="$1" selections_file="$2" agent_tools_file="$3"
  local out="${repo_dir}/.dotfriend/agent-artifacts.json"
  command -v jq >/dev/null 2>&1 || return 0
  ensure_dir "$(dirname "$out")"

  jq -n \
    --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --slurpfile selections_file "$selections_file" \
    --slurpfile agent_tools_file "$agent_tools_file" '
    ($selections_file[0]) as $selections |
    ($agent_tools_file[0]) as $agent_tools |

    def artifact_for_file($tool; $file):
      ($tool.id + ":" + ($file | gsub("[^A-Za-z0-9._-]"; "-"))) as $id |
      {
        id: $id,
        kind: (if ($file | test("(^|/)mcp\\.json$")) then "mcp" elif ($file | test("\\.md$")) then "instruction" else "agent" end),
        name: ($tool.name + " " + $file),
        tools: [$tool.id],
        scope: "user",
        source: {type: "repo_file", repo_path: ($tool.id + "/" + $file)},
        install: {
          strategy: (
            if ($file | test("(^|/)mcp\\.json$")) then "managed_json_merge"
            elif ($file | test("\\.md$")) then "managed_markdown_block"
            else "copy_managed_file"
            end
          )
        },
        targets: [
          {
            tool: $tool.id,
            path: (($tool.canonical_dir // ("~/." + $tool.id)) + "/" + $file)
          }
          + (if ($file | test("(^|/)mcp\\.json$")) then {json_path:"mcpServers.dotfriend"} else {} end)
        ],
        ownership: "managed_partial",
        managed_by: "dotfriend",
        secret_refs: []
      };

    def artifact_for_dir($tool; $dir):
      {
        id: ($tool.id + ":" + ($dir | gsub("[^A-Za-z0-9._-]"; "-"))),
        kind: (if $dir == "skills" then "skill" elif $dir == "rules" then "rule" else "agent" end),
        name: ($tool.name + " " + $dir),
        tools: [$tool.id],
        scope: "user",
        source: {type: "repo_dir", repo_path: ($tool.id + "/" + $dir)},
        install: {strategy:"rsync_managed_dir"},
        targets: [{tool:$tool.id,path:(($tool.canonical_dir // ("~/." + $tool.id)) + "/" + $dir)}],
        ownership: "managed_partial",
        managed_by: "dotfriend",
        secret_refs: []
      };

    def selected_agent_artifacts:
      ($selections.agents // [])
      | map(.id as $id | ($agent_tools.agentic_tools[]? | select(.id == $id)) as $tool
        | (($tool.important_files // []) | map(artifact_for_file($tool; .)))
          + (($tool.important_dirs // []) | map(artifact_for_dir($tool; .)))
      )
      | add // [];

    {
      schema_version: 1,
      generated_by: "dotfriend",
      generated_at: $generated_at,
      artifacts: (
        selected_agent_artifacts
        + [
          {
            id:"shared-store:skills",
            kind:"skill",
            name:"Shared agent skills",
            tools:(($selections.agents // []) | map(.id)),
            scope:"shared",
            source:{type:"repo_dir",repo_path:"agents/skills"},
            install:{strategy:"symlink_shared_store"},
            targets:[{tool:"shared",path:"~/.agents/skills"}],
            ownership:"managed_partial",
            managed_by:"dotfriend",
            secret_refs:[]
          },
          {
            id:"shared-store:agent-docs",
            kind:"instruction",
            name:"Shared agent docs",
            tools:(($selections.agents // []) | map(.id)),
            scope:"shared",
            source:{type:"repo_dir",repo_path:"agents/agent-docs"},
            install:{strategy:"symlink_shared_store"},
            targets:[{tool:"shared",path:"~/.agents/agent-docs"}],
            ownership:"managed_partial",
            managed_by:"dotfriend",
            secret_refs:[]
          }
        ]
      )
    }' > "$out"

  agent_artifacts_validate "$out"
}

agent_artifacts_suggest_json() {
  local proposals='[]'
  local candidate target tool kind artifact_id proposal redacted
  while IFS='|' read -r tool candidate kind; do
    [[ -n "$tool" && -f "$candidate" ]] || continue
    target="${candidate/#$HOME/~}"
    artifact_id="${tool}:$(basename "$candidate")"
    redacted="$(jq -cn --arg path "$target" '{type:"repo_file",detected_path:$path}')"
    proposal="$(jq -cn --arg id "$artifact_id" --arg kind "$kind" --arg tool "$tool" --arg path "$target" --argjson source "$redacted" '{
      id:$id, kind:$kind, name:($tool + " " + ($path | split("/")[-1])), tools:[$tool], scope:"user",
      source:$source, install:{strategy:(if $kind == "mcp" then "managed_json_merge" else "managed_markdown_block" end)},
      targets:[{tool:$tool,path:$path}], ownership:"managed_partial", managed_by:"dotfriend", secret_refs:[]
    }')"
    proposals="$(jq -c --argjson item "$proposal" '. + [$item]' <<< "$proposals")"
  done <<EOF
cursor|${HOME}/.cursor/mcp.json|mcp
claude|${HOME}/.claude/CLAUDE.md|instruction
codex|${HOME}/.codex/AGENTS.md|instruction
EOF
  jq -cn --argjson proposals "$proposals" '{proposed_artifacts:$proposals}'
}

agent_artifacts_drift_json() {
  local repo_dir="$1" artifacts_file="$2" drift='[]'
  local artifact_json id target_json path expanded item
  while IFS= read -r artifact_json; do
    id="$(jq -r '.id' <<< "$artifact_json")"
    if [[ -n "$(jq -r '.source.repo_path // empty' <<< "$artifact_json")" && ! -e "${repo_dir}/$(jq -r '.source.repo_path' <<< "$artifact_json")" ]]; then
      item="$(jq -cn --arg code "missing_artifact_source" --arg artifact_id "$id" '{code:$code,artifact_id:$artifact_id,message:"Artifact source is missing."}')"
      drift="$(jq -c --argjson item "$item" '. + [$item]' <<< "$drift")"
    fi
    while IFS= read -r target_json; do
      path="$(jq -r '.path // empty' <<< "$target_json")"
      [[ -n "$path" ]] || continue
      expanded="$(agent_expand_home_path "$path")"
      if [[ ! -e "$expanded" ]]; then
        item="$(jq -cn --arg code "missing_target" --arg artifact_id "$id" --arg path "$path" '{code:$code,artifact_id:$artifact_id,target_path:$path,message:"Artifact target is missing."}')"
        drift="$(jq -c --argjson item "$item" '. + [$item]' <<< "$drift")"
      fi
    done < <(jq -c '.targets[]?' <<< "$artifact_json")
  done < <(jq -c '.artifacts[]?' "$artifacts_file")
  printf '%s\n' "$drift"
}

agent_cmd() {
  local subcmd="${1:-}"
  shift || true
  local dry_run=false
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
    esac
  done

  if [[ "${DOTFRIEND_API_JSON:-false}" != "true" ]]; then
    api_fail "agent" "json_required" "Use dotfriend agent ${subcmd:-status} --json."
    return 2
  fi

  local repo_dir="" artifacts_file="" data warnings='[]' errors='[]' status='ok'
  repo_dir="$(status_find_repo 2>/dev/null || true)"
  artifacts_file="$(agent_artifacts_file_for_repo "$repo_dir")"

  case "$subcmd" in
    status)
      if [[ -z "$repo_dir" ]]; then
        warnings="[$(api_warning "managed_repo_missing" "No generated dotfiles repo could be found." "{}")]"
        data='{"selected_tools":[],"shared_stores":[],"artifact_count":0,"drift":[]}'
        status="warning"
      elif [[ ! -f "$artifacts_file" ]]; then
        warnings="[$(api_warning "agent_artifacts_missing" "Generated repo has no agent artifact manifest." "{}")]"
        data='{"selected_tools":[],"shared_stores":[],"artifact_count":0,"drift":[]}'
        status="warning"
      elif agent_artifacts_validate "$artifacts_file" 2>/dev/null; then
        local drift
        drift="$(agent_artifacts_drift_json "$repo_dir" "$artifacts_file")"
        data="$(jq -cn --arg repo "$repo_dir" --argjson manifest "$(<"$artifacts_file")" --argjson drift "$drift" '{
          managed_repo:$repo,
          selected_tools:($manifest.artifacts | map(.tools[]?) | unique),
          shared_stores:($manifest.artifacts | map(select(.scope == "shared") | .source.repo_path)),
          artifact_count:($manifest.artifacts | length),
          drift:$drift
        }')"
      else
        errors="[$(api_error "agent_artifacts_schema_error" "Agent artifact manifest failed validation." "{}")]"
        data='{"selected_tools":[],"shared_stores":[],"artifact_count":0,"drift":[]}'
        status="failed"
      fi
      api_print_envelope "$status" "agent status" "$data" "$warnings" "$errors"
      ;;
    check)
      if [[ -z "$repo_dir" || ! -f "$artifacts_file" ]]; then
        errors="[$(api_error "agent_artifacts_missing" "Agent artifact manifest was not found." "{}")]"
        api_print_envelope "failed" "agent check" '{"valid":false}' "[]" "$errors"
        return 1
      fi
      if agent_artifacts_validate "$artifacts_file" 2>/dev/null; then
        data="$(jq -cn --arg path "$artifacts_file" --argjson count "$(jq '.artifacts | length' "$artifacts_file")" '{valid:true,path:$path,artifact_count:$count}')"
        api_print_envelope "ok" "agent check" "$data"
      else
        errors="[$(api_error "agent_artifacts_schema_error" "Agent artifact manifest failed validation." "{}")]"
        api_print_envelope "failed" "agent check" '{"valid":false}' "[]" "$errors"
        return 1
      fi
      ;;
    sync)
      if [[ "$dry_run" != true ]]; then
        errors="[$(api_error "dry_run_required" "Use dotfriend agent sync --dry-run --json before applying writes." "{}")]"
        api_print_envelope "needs_approval" "agent sync" '{"planned_writes":[]}' "[]" "$errors"
        return 2
      fi
      if [[ -z "$repo_dir" || ! -f "$artifacts_file" ]]; then
        errors="[$(api_error "agent_artifacts_missing" "Agent artifact manifest was not found." "{}")]"
        api_print_envelope "failed" "agent sync" '{"planned_writes":[]}' "[]" "$errors"
        return 1
      fi
      local planned='[]' artifact_json result
      while IFS= read -r artifact_json; do
        result="$(agent_adapter_apply_artifact "$repo_dir" "$artifact_json" true true 2>/dev/null || true)"
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          planned="$(jq -c --argjson item "$line" '. + [$item]' <<< "$planned")"
        done <<< "$result"
      done < <(jq -c '.artifacts[]?' "$artifacts_file")
      data="$(jq -cn --argjson planned "$planned" '{planned_writes:$planned}')"
      api_print_envelope "ok" "agent sync" "$data"
      ;;
    suggest)
      data="$(agent_artifacts_suggest_json)"
      api_print_envelope "ok" "agent suggest" "$data"
      ;;
    *)
      api_fail "agent" "unknown_agent_command" "Unknown agent command: ${subcmd:-}"
      return 2
      ;;
  esac
}
