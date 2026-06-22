#!/usr/bin/env bash
# dotfriend — restore manifest helpers
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MANIFEST_ALLOWED_RESTORE_MODES='["symlink","copy","rsync","managed_json_merge","managed_markdown_block","defaults_import","install_only","generated","manual_followup"]'

manifest_validate() {
  local manifest_file="$1"
  if [[ ! -f "$manifest_file" ]]; then
    printf 'manifest missing: %s\n' "$manifest_file" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is required to validate restore manifests\n' >&2
    return 1
  fi

  jq -e --argjson modes "$MANIFEST_ALLOWED_RESTORE_MODES" '
    .schema_version == 1
    and (.items | type == "array")
    and all(.items[]?;
      (.id | type == "string" and length > 0)
      and (.type | type == "string" and length > 0)
      and (.restore_mode as $mode | $modes | index($mode) != null)
      and ((.repo_path // "") | type == "string")
      and ((.repo_path // "") | startswith("/") | not)
      and ((.repo_path // "") | contains("..") | not)
      and ((.target_path // "") | type == "string")
      and (
        (.target_path | startswith("~/"))
        or (.target_path | startswith("$HOME/"))
        or (.target_path | startswith("/Applications/"))
        or (.target_path | startswith("/Library/"))
      )
      and (
        (.restore_mode as $mode
          | if ($mode == "symlink" or $mode == "copy" or $mode == "rsync" or $mode == "managed_json_merge" or $mode == "managed_markdown_block" or $mode == "defaults_import")
            then ((.repo_path // "") | length > 0)
            else true
            end)
      )
    )
  ' "$manifest_file" >/dev/null
}

manifest_repo_path_has_files() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  [[ -n "$(find "$path" -type f -print -quit 2>/dev/null)" ]]
}

manifest_dotfile_repo_path() {
  local dotfile="$1"
  case "$dotfile" in
    .gitconfig)
      printf '%s' "config/git/${dotfile}"
      ;;
    *)
      printf '%s' "zsh/${dotfile}"
      ;;
  esac
}

manifest_write_for_generated_repo() {
  local repo_dir="$1" selections_file="$2" agent_tools_file="$3"
  local out="${repo_dir}/.dotfriend/restore-manifest.json"

  if ! command -v jq >/dev/null 2>&1; then
    log_warn "jq is required to write restore-manifest.json"
    return 0
  fi

  ensure_dir "$(dirname "$out")"

  local tmp
  tmp="$(mktemp)"
  local generated_dotfiles generated_config_dirs generated_agents
  local generated_dotfiles_json generated_config_dirs_json generated_agents_json
  local include_agent_skills=false include_agent_docs=false
  generated_dotfiles="$(mktemp)"
  generated_config_dirs="$(mktemp)"
  generated_agents="$(mktemp)"

  while IFS= read -r dotfile; do
    [[ -n "$dotfile" ]] || continue
    if [[ -f "${repo_dir}/$(manifest_dotfile_repo_path "$dotfile")" ]]; then
      printf '%s\n' "$dotfile" >> "$generated_dotfiles"
    fi
  done < <(jq -r '.dotfiles[]?' "$selections_file" 2>/dev/null || true)

  while IFS= read -r config_dir; do
    [[ -n "$config_dir" ]] || continue
    if manifest_repo_path_has_files "${repo_dir}/config/${config_dir}"; then
      printf '%s\n' "$config_dir" >> "$generated_config_dirs"
    fi
  done < <(jq -r '.config_dirs[]?' "$selections_file" 2>/dev/null || true)

  while IFS= read -r agent_id; do
    [[ -n "$agent_id" ]] || continue
    if manifest_repo_path_has_files "${repo_dir}/${agent_id}"; then
      printf '%s\n' "$agent_id" >> "$generated_agents"
    fi
  done < <(jq -r '.agents[]? | if type == "object" then (.id // empty) else . end' "$selections_file" 2>/dev/null || true)

  if manifest_repo_path_has_files "${repo_dir}/agents/skills"; then
    include_agent_skills=true
  fi
  if manifest_repo_path_has_files "${repo_dir}/agents/agent-docs"; then
    include_agent_docs=true
  fi

  generated_dotfiles_json="$(jq -Rsc 'split("\n") | map(select(length > 0))' "$generated_dotfiles")"
  generated_config_dirs_json="$(jq -Rsc 'split("\n") | map(select(length > 0))' "$generated_config_dirs")"
  generated_agents_json="$(jq -Rsc 'split("\n") | map(select(length > 0))' "$generated_agents")"

  jq -n \
    --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg hostname "$(hostname 2>/dev/null || printf '')" \
    --arg os "$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || printf unknown)" \
    --argjson generated_dotfiles "$generated_dotfiles_json" \
    --argjson generated_config_dirs "$generated_config_dirs_json" \
    --argjson generated_agents "$generated_agents_json" \
    --argjson include_agent_skills "$include_agent_skills" \
    --argjson include_agent_docs "$include_agent_docs" \
    --slurpfile selections_file "$selections_file" \
    --slurpfile agent_tools_file "$agent_tools_file" \
    '
    ($selections_file[0]) as $selections |
    ($agent_tools_file[0]) as $agent_tools |

    def dotfile_repo_path($path):
      if $path == ".gitconfig" then "config/git/.gitconfig" else "zsh/" + $path end;

    def selected_dotfiles:
      $generated_dotfiles
      | map({
          id: ("dotfile:" + (sub("^\\."; ""))),
          type: "dotfile",
          restore_mode: "symlink",
          repo_path: dotfile_repo_path(.),
          target_path: ("~/" + .),
          selected: true,
          requires_approval: false
        });

    def selected_config_dirs:
      $generated_config_dirs
      | map({
          id: ("config_dir:" + .),
          type: "config_dir",
          restore_mode: "copy",
          repo_path: ("config/" + .),
          target_path: ("~/.config/" + .),
          selected: true,
          requires_approval: false
        });

    def selected_agents:
      $generated_agents
      | map(. as $id
        | ($agent_tools.agentic_tools[]? | select(.id == $id)) as $tool
        | {
            id: ("agent_config:" + $id),
            type: "agent_config",
            restore_mode: "rsync",
            repo_path: $id,
            target_path: ($tool.canonical_dir // ("~/." + $id)),
            selected: true,
            requires_approval: false,
            metadata: {
              important_files: ($tool.important_files // []),
              important_dirs: ($tool.important_dirs // []),
              symlinks_to_skip: ($tool.symlinks_to_skip // [])
            }
          });

    def editor_extensions:
      [
        (if ($selections.editors.vscode // false) then {
          id: "editor_extensions:vscode",
          type: "editor_extensions",
          restore_mode: "install_only",
          repo_path: "vscode/extensions.txt",
          target_path: "~/Library/Application Support/Code/User",
          selected: true,
          requires_approval: false
        } else empty end),
        (if ($selections.editors.cursor // false) then {
          id: "editor_extensions:cursor",
          type: "editor_extensions",
          restore_mode: "install_only",
          repo_path: "cursor/extensions.txt",
          target_path: "~/Library/Application Support/Cursor/User",
          selected: true,
          requires_approval: false
        } else empty end)
      ];

    def selected_macos_defaults:
      if (($selections.macos_defaults // []) | length) > 0 then [
        {
          id: "macos_defaults:selected",
          type: "macos_defaults",
          restore_mode: "defaults_import",
          repo_path: "macos/defaults.json",
          target_path: "~/Library/Preferences",
          selected: true,
          requires_approval: false
        }
      ] else [] end;

    def package_artifacts:
      def uniq_order: reduce .[] as $x ([]; if index($x) then . else . + [$x] end);
      [
        {
          id: "packages:homebrew",
          type: "homebrew_packages",
          restore_mode: "install_only",
          repo_path: "Brewfile",
          target_path: "~/.dotfriend/packages/homebrew",
          selected: true,
          requires_approval: false,
          metadata: {
            taps: (($selections.taps // []) | map(select(. != "jordond/tap")) | uniq_order),
            formulae: (($selections.formulae // []) | map(select(. != "jolt")) | uniq_order),
            casks: (($selections.apps // []) | map(select(contains("|cask:")) | split("|cask:")[1] | split("|")[0]) | uniq_order),
            mas: (($selections.apps // []) | map(select(contains("|mas:")) | split("|mas:")[1] | split("|")[0]) | uniq_order)
          }
        }
      ]
      + (if (($selections.npm_globals // []) | length) > 0 then [
        {
          id: "packages:npm_globals",
          type: "npm_globals",
          restore_mode: "install_only",
          repo_path: "npm-global.txt",
          target_path: "~/.dotfriend/packages/npm",
          selected: true,
          requires_approval: false,
          metadata: {
            packages: ($selections.npm_globals // [])
          }
        }
      ] else [] end);

    {
      schema_version: 1,
      generated_by: "dotfriend",
      generated_at: $generated_at,
      source_machine: {hostname: $hostname, os: $os},
      items: (
        selected_dotfiles
        + selected_config_dirs
        + selected_agents
        + editor_extensions
        + selected_macos_defaults
        + package_artifacts
        + (if $include_agent_skills then [
          {
            id: "agent_shared_store:skills",
            type: "agent_shared_store",
            restore_mode: "rsync",
            repo_path: "agents/skills",
            target_path: "~/.agents/skills",
            selected: true,
            requires_approval: false
          }
        ] else [] end)
        + (if $include_agent_docs then [
          {
            id: "agent_shared_store:agent-docs",
            type: "agent_shared_store",
            restore_mode: "rsync",
            repo_path: "agents/agent-docs",
            target_path: "~/.agents/agent-docs",
            selected: true,
            requires_approval: false
          }
        ] else [] end)
      ),
      manual_followups: []
    }
    ' > "$tmp"

  rm -f "$generated_dotfiles" "$generated_config_dirs" "$generated_agents"
  mv "$tmp" "$out"
  manifest_validate "$out"
}
