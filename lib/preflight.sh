#!/usr/bin/env bash
# dotfriend — non-mutating runtime preflight checks
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=api.sh
source "$(dirname "${BASH_SOURCE[0]}")/api.sh"

preflight_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

preflight_add_check() {
  local checks_file="$1" id="$2" status="$3" action="${4:-}" package="${5:-}"
  local object
  object="{\"id\":\"$(api_json_escape "$id")\",\"status\":\"$(api_json_escape "$status")\""
  if [[ -n "$action" ]]; then
    object+=",\"action\":\"$(api_json_escape "$action")\""
  fi
  if [[ -n "$package" ]]; then
    object+=",\"package\":\"$(api_json_escape "$package")\""
  fi
  object+="}"
  printf '%s\n' "$object" >> "$checks_file"
}

preflight_join_json_lines() {
  local file="$1"
  local first=true
  printf '['
  if [[ -f "$file" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$first" == "true" ]]; then
        first=false
      else
        printf ','
      fi
      printf '%s' "$line"
    done < "$file"
  fi
  printf ']'
}

preflight_run_json() {
  local tmp_dir checks_file commands_file warnings_file
  tmp_dir="$(mktemp -d)"
  checks_file="${tmp_dir}/checks.jsonl"
  commands_file="${tmp_dir}/commands.jsonl"
  warnings_file="${tmp_dir}/warnings.jsonl"

  local ready=true
  local requires_approval=false
  local os_name
  os_name="$(uname -s 2>/dev/null || printf unknown)"

  if [[ "$os_name" == "Darwin" ]]; then
    preflight_add_check "$checks_file" "os" "ok"
  else
    ready=false
    preflight_add_check "$checks_file" "os" "blocked"
    local os_details
    os_details="{\"os\":\"$(api_json_escape "$os_name")\"}"
    api_warning "unsupported_os" "dotfriend currently supports macOS." "$os_details" >> "$warnings_file"
  fi

  if preflight_command_exists xcode-select; then
    preflight_add_check "$checks_file" "xcode-select" "ok"
    if xcode-select -p >/dev/null 2>&1; then
      preflight_add_check "$checks_file" "xcode_cli_tools" "ok"
    else
      ready=false
      requires_approval=true
      preflight_add_check "$checks_file" "xcode_cli_tools" "missing" "install_xcode_cli_tools"
      printf '{"label":"Install Xcode Command Line Tools","command":["xcode-select","--install"]}\n' >> "$commands_file"
    fi
  else
    ready=false
    requires_approval=true
    preflight_add_check "$checks_file" "xcode-select" "missing" "install_xcode_cli_tools"
  fi

  local brew_available=false
  if preflight_command_exists brew; then
    brew_available=true
    preflight_add_check "$checks_file" "homebrew" "ok"
  else
    ready=false
    requires_approval=true
    preflight_add_check "$checks_file" "homebrew" "missing" "install_homebrew"
    printf '{"label":"Install Homebrew","command":["/bin/bash","-c","$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"]}\n' >> "$commands_file"
  fi

  local formula
  for formula in git jq gum gh mas node; do
    if [[ "$brew_available" == "true" ]] && brew list --versions "$formula" >/dev/null 2>&1; then
      preflight_add_check "$checks_file" "$formula" "ok"
    else
      ready=false
      requires_approval=true
      preflight_add_check "$checks_file" "$formula" "needs_install" "brew_install" "$formula"
      printf '{"label":"Install %s","command":["brew","install","%s"]}\n' \
        "$(api_json_escape "$formula")" "$(api_json_escape "$formula")" >> "$commands_file"
    fi
  done

  local cmd
  for cmd in brew git jq gum gh mas npm; do
    if preflight_command_exists "$cmd"; then
      preflight_add_check "$checks_file" "command:${cmd}" "ok"
    else
      ready=false
      requires_approval=true
      preflight_add_check "$checks_file" "command:${cmd}" "missing"
    fi
  done

  local checks_json planned_commands_json warnings_json data_json status
  checks_json="$(preflight_join_json_lines "$checks_file")"
  planned_commands_json="$(preflight_join_json_lines "$commands_file")"
  warnings_json="$(preflight_join_json_lines "$warnings_file")"
  if command -v jq >/dev/null 2>&1; then
    data_json="$(jq -cn \
      --argjson ready "$ready" \
      --argjson requires_approval "$requires_approval" \
      --argjson checks "$checks_json" \
      --argjson planned_commands "$planned_commands_json" \
      '{ready:$ready,requires_approval:$requires_approval,checks:$checks,planned_commands:$planned_commands}')"
  else
    data_json="{\"ready\":${ready},\"requires_approval\":${requires_approval},\"checks\":${checks_json},\"planned_commands\":${planned_commands_json}}"
  fi
  status="ok"
  if [[ "$ready" != "true" && "$requires_approval" == "true" ]]; then
    status="needs_approval"
  elif [[ "$ready" != "true" ]]; then
    status="blocked"
  fi

  api_print_envelope "$status" "preflight" "$data_json" "$warnings_json" "[]"
  rm -rf "$tmp_dir"
}
