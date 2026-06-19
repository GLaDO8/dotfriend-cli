#!/usr/bin/env bash
# dotfriend — Post-install validation script
# Usage: validate.sh [--json] [--fix] [--brew|--symlinks|--shell|--git|--agents|--npm|--all]
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────

OUTPUT_JSON=false
FIX_MODE=false
CHECK_BREW=false
CHECK_SYMLINKS=false
CHECK_SHELL=false
CHECK_GIT=false
CHECK_AGENTS=false
CHECK_NPM=false
CHECK_DOTFRIEND=false

# ─────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────

if [[ $# -eq 0 ]]; then
  CHECK_ALL=true
else
  CHECK_ALL=false
  for arg in "$@"; do
    case "$arg" in
      --json) OUTPUT_JSON=true ;;
      --fix) FIX_MODE=true ;;
      --brew) CHECK_BREW=true ;;
      --symlinks) CHECK_SYMLINKS=true ;;
      --shell) CHECK_SHELL=true ;;
      --git) CHECK_GIT=true ;;
      --agents) CHECK_AGENTS=true ;;
      --npm) CHECK_NPM=true ;;
      --dotfriend) CHECK_DOTFRIEND=true ;;
      --all) CHECK_ALL=true ;;
    esac
  done
fi

if [[ "$CHECK_ALL" == true ]]; then
  CHECK_BREW=true
  CHECK_SYMLINKS=true
  CHECK_SHELL=true
  CHECK_GIT=true
  CHECK_AGENTS=true
  CHECK_NPM=true
  CHECK_DOTFRIEND=true
fi

# ─────────────────────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────────────────────

if [[ -t 1 && "$OUTPUT_JSON" == false ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_RED='\033[31m'
  C_GREEN='\033[32m'
  C_YELLOW='\033[33m'
  C_DIM='\033[2m'
  CHECK_PASS="${C_GREEN}✔${C_RESET}"
  CHECK_FAIL="${C_RED}✖${C_RESET}"
  CHECK_WARN="${C_YELLOW}⚠${C_RESET}"
else
  C_RESET=''
  C_BOLD=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_DIM=''
  CHECK_PASS='✔'
  CHECK_FAIL='✖'
  CHECK_WARN='⚠'
fi

# ─────────────────────────────────────────────────────────────
# Result tracking
# ─────────────────────────────────────────────────────────────

declare -a CHECKS_NAME=()
declare -a CHECKS_STATUS=()   # pass / fail / warn
declare -a CHECKS_MESSAGE=()

total_pass=0
total_fail=0
total_warn=0

record() {
  local name="$1" status="$2" message="$3"
  CHECKS_NAME+=("$name")
  CHECKS_STATUS+=("$status")
  CHECKS_MESSAGE+=("$message")
  case "$status" in
    pass) ((total_pass++)) || true ;;
    fail) ((total_fail++)) || true ;;
    warn) ((total_warn++)) || true ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

has_brew() { command -v brew >/dev/null 2>&1; }
has_npm()  { command -v npm >/dev/null 2>&1; }

json_ok() {
  command -v jq >/dev/null 2>&1 && jq -e . "$1" >/dev/null 2>&1
}

is_safe_repo_path() {
  local path="$1"
  [[ -n "$path" && "$path" != /* && "$path" != *..* ]]
}

is_allowed_target_path() {
  local path="$1"
  [[ "$path" == "~/"* || "$path" == "\$HOME/"* || "$path" == "/Applications/"* || "$path" == "/Library/"* ]]
}

brew_is_installed() {
  local name="$1"
  brew list --formula "$name" >/dev/null 2>&1 || \
    brew list --cask "$name" >/dev/null 2>&1
}

npm_package_name_from_spec() {
  local pkg="$1"
  if [[ "$pkg" == @* ]]; then
    if [[ "$pkg" =~ ^(@[^/@[:space:]]+/[^@[:space:]]+)(@[^[:space:]]+)?$ ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  elif [[ "$pkg" =~ ^([^@[:space:]]+)(@[^[:space:]]+)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

line_set_contains() {
  local lines="$1" needle="$2"
  printf '%s' "$lines" | grep -Fxq -- "$needle"
}

read_link() {
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$1" 2>/dev/null || readlink "$1" 2>/dev/null || true
  else
    true
  fi
}

# ─────────────────────────────────────────────────────────────
# Check: Brew
# ─────────────────────────────────────────────────────────────

run_check_brew() {
  if ! has_brew; then
    record "brew available" "fail" "Homebrew is not installed"
    return
  fi
  record "brew available" "pass" "Homebrew is installed"

  local brewfile="${REPO_ROOT}/Brewfile"
  if [[ ! -f "$brewfile" ]]; then
    record "Brewfile exists" "warn" "No Brewfile found in repo"
    return
  fi
  record "Brewfile exists" "pass" "Brewfile found"

  # Parse Brewfile lines
  local line name type
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | xargs 2>/dev/null || true)"
    [[ -z "$line" ]] && continue

    type=""
    name=""
    if [[ "$line" == brew* ]]; then
      type="formula"
      name="${line#brew }"
      name="${name#\\\"}"
      name="${name%\\\"}"
      name="${name#\'}"
      name="${name%\'}"
      name="$(printf '%s' "$name" | awk '{print $1}')"
    elif [[ "$line" == cask* ]]; then
      type="cask"
      name="${line#cask }"
      name="${name#\\\"}"
      name="${name%\\\"}"
      name="${name#\'}"
      name="${name%\'}"
      name="$(printf '%s' "$name" | awk '{print $1}')"
    else
      continue
    fi

    [[ -z "$name" ]] && continue

    if brew_is_installed "$name"; then
      record "brew: $name" "pass" "$type is installed"
    else
      record "brew: $name" "fail" "$type is missing"
      if [[ "$FIX_MODE" == true ]]; then
        if [[ "$type" == "cask" ]]; then
          if brew install --cask "$name" 2>/dev/null; then
            record "brew: $name" "pass" "Reinstalled via --fix"
          else
            record "brew: $name" "fail" "Failed to reinstall"
          fi
        else
          if brew install "$name" 2>/dev/null; then
            record "brew: $name" "pass" "Reinstalled via --fix"
          else
            record "brew: $name" "fail" "Failed to reinstall"
          fi
        fi
      fi
    fi
  done < "$brewfile"
}

# ─────────────────────────────────────────────────────────────
# Check: Symlinks
# ─────────────────────────────────────────────────────────────

run_check_symlinks() {
  local found_any=false
  while IFS= read -r -d '' link; do
    found_any=true
    local target
    target="$(read_link "$link" 2>/dev/null || true)"
    if [[ -z "$target" ]]; then
      record "symlink: $link" "fail" "Broken or unreadable symlink"
      if [[ "$FIX_MODE" == true ]]; then
        # Try to recreate from repo structure
        local rel_path="${link#"$HOME"/}"
        local repo_path="${REPO_ROOT}/${rel_path}"
        if [[ -e "$repo_path" ]]; then
          rm -f "$link"
          ln -s "$repo_path" "$link"
          record "symlink: $link" "pass" "Recreated via --fix"
        else
          record "symlink: $link" "fail" "Cannot fix: no source in repo"
        fi
      fi
      continue
    fi

    # Normalize paths for comparison
    local abs_target
    abs_target="$(cd "$(dirname "$link")" 2>/dev/null && realpath "$target" 2>/dev/null || printf '%s' "$target")"

    if [[ "$abs_target" == "$REPO_ROOT"* ]]; then
      record "symlink: $link" "pass" "Points to repo"
    else
      record "symlink: $link" "warn" "Points outside repo: $target"
    fi
  done < <(find "${REPO_ROOT}/config" "${REPO_ROOT}/zsh" "${REPO_ROOT}/vscode" "${REPO_ROOT}/cursor" "${REPO_ROOT}/claude" "${REPO_ROOT}/codex" -type l -print0 2>/dev/null || true)

  if [[ "$found_any" == false ]]; then
    record "symlinks" "warn" "No symlinks found in repo"
  fi
}

# ─────────────────────────────────────────────────────────────
# Check: Shell
# ─────────────────────────────────────────────────────────────

run_check_shell() {
  local shell_rc=""
  case "${SHELL##*/}" in
    zsh) shell_rc="${HOME}/.zshrc" ;;
    bash) shell_rc="${HOME}/.bashrc" ;;
    *) shell_rc="${HOME}/.profile" ;;
  esac

  if [[ -f "$shell_rc" ]]; then
    record "shell rc file" "pass" "$shell_rc exists"
  else
    record "shell rc file" "warn" "$shell_rc not found"
  fi

  # Check if dotfiles sourcing is present
  if [[ -f "$shell_rc" ]] && grep -q "dotfiles" "$shell_rc" 2>/dev/null; then
    record "shell sourcing" "pass" "dotfiles sourcing detected"
  else
    record "shell sourcing" "warn" "No dotfiles sourcing detected in $shell_rc"
  fi
}

# ─────────────────────────────────────────────────────────────
# Check: Git / SSH
# ─────────────────────────────────────────────────────────────

run_check_git() {
  if [[ -f "${HOME}/.gitconfig" ]]; then
    record "gitconfig" "pass" "${HOME}/.gitconfig exists"
  else
    record "gitconfig" "warn" "${HOME}/.gitconfig not found"
  fi

  if [[ -d "${HOME}/.ssh" ]]; then
    record "ssh dir" "pass" "${HOME}/.ssh exists"
    if [[ -f "${HOME}/.ssh/config" ]]; then
      record "ssh config" "pass" "${HOME}/.ssh/config exists"
    else
      record "ssh config" "warn" "${HOME}/.ssh/config not found"
    fi
  else
    record "ssh dir" "warn" "${HOME}/.ssh not found"
  fi

  if [[ -d "${REPO_ROOT}/.git" ]]; then
    record "repo git" "pass" "Repo is a git repository"
  else
    record "repo git" "warn" "Repo is not initialized with git"
  fi
}

# ─────────────────────────────────────────────────────────────
# Check: Agent tools
# ─────────────────────────────────────────────────────────────

run_check_agents() {
  local agents_file="${REPO_ROOT}/.dotfriend/agent-tools.json"
  if [[ ! -f "$agents_file" ]]; then
    agents_file="${SCRIPT_DIR}/../lib/agent-tools.json"
  fi

  if [[ ! -f "$agents_file" ]]; then
    record "agent tools list" "warn" "agent-tools.json not found"
    return
  fi

  local selected_agents="${REPO_ROOT}/.dotfriend/selections.json"
  local tool canonical has_any=false
  while IFS= read -r tool; do
    [[ -z "$tool" ]] && continue
    canonical="${HOME}/.${tool}"
    if [[ -d "$canonical" ]]; then
      has_any=true
      record "agent: $tool" "pass" "Config directory exists"
    else
      # Check alternative paths from JSON if available
      record "agent: $tool" "warn" "Config directory not found"
    fi
  done < <(
    if [[ -f "$selected_agents" ]]; then
      jq -r '.agents // [] | .[] | .id' "$selected_agents" 2>/dev/null || true
    else
      jq -r '.agentic_tools[].id' "$agents_file" 2>/dev/null || true
    fi
  )

  if [[ "$has_any" == false ]]; then
    record "agent tools" "warn" "No agent tool configs detected"
  fi
}

# ─────────────────────────────────────────────────────────────
# Check: npm globals
# ─────────────────────────────────────────────────────────────

run_check_npm() {
  if ! has_npm; then
    record "npm available" "warn" "npm is not installed"
    return
  fi
  record "npm available" "pass" "npm is installed"

  local npmfile="${REPO_ROOT}/npm-global.txt"
  if [[ ! -f "$npmfile" ]]; then
    record "npm-global.txt" "warn" "No npm-global.txt found in repo"
    return
  fi

  local pkg name version
  while IFS= read -r pkg || [[ -n "$pkg" ]]; do
    pkg="${pkg%%#*}"
    pkg="$(printf '%s' "$pkg" | xargs 2>/dev/null || true)"
    [[ -z "$pkg" ]] && continue
    if ! name="$(npm_package_name_from_spec "$pkg")"; then
      record "npm: $pkg" "fail" "Malformed package spec"
      continue
    fi

    if npm list -g --depth=0 "$name" >/dev/null 2>&1; then
      record "npm: $name" "pass" "Package is installed"
    else
      record "npm: $name" "fail" "Package is missing"
      if [[ "$FIX_MODE" == true ]]; then
        if npm install -g "$pkg" 2>/dev/null; then
          record "npm: $name" "pass" "Reinstalled via --fix"
        else
          record "npm: $name" "fail" "Failed to reinstall"
        fi
      fi
    fi
  done < "$npmfile"
}

# ─────────────────────────────────────────────────────────────
# Check: dotfriend metadata
# ─────────────────────────────────────────────────────────────

run_check_dotfriend_metadata() {
  local manifest="${REPO_ROOT}/.dotfriend/restore-manifest.json"
  local artifacts="${REPO_ROOT}/.dotfriend/agent-artifacts.json"
  local selections="${REPO_ROOT}/.dotfriend/selections.json"

  if [[ ! -f "$manifest" ]]; then
    record "restore manifest" "fail" ".dotfriend/restore-manifest.json is missing"
    return
  fi
  if ! json_ok "$manifest"; then
    record "restore manifest JSON" "fail" "restore-manifest.json is not valid JSON"
    return
  fi
  if [[ "$(jq -r '.schema_version // empty' "$manifest")" != "1" ]]; then
    record "restore manifest schema" "fail" "unsupported restore manifest schema"
  else
    record "restore manifest schema" "pass" "schema version 1"
  fi

  local bad_repo_path bad_target_path
  bad_repo_path="$(jq -r '.items[]? | .repo_path // empty' "$manifest" | while IFS= read -r p; do [[ -z "$p" ]] && continue; is_safe_repo_path "$p" || { printf '%s\n' "$p"; break; }; done)"
  if [[ -n "$bad_repo_path" ]]; then
    record "restore repo paths" "fail" "unsafe repo_path: $bad_repo_path"
  else
    record "restore repo paths" "pass" "all repo paths are relative and safe"
  fi

  bad_target_path="$(jq -r '.items[]? | .target_path // empty' "$manifest" | while IFS= read -r p; do [[ -z "$p" ]] && continue; is_allowed_target_path "$p" || { printf '%s\n' "$p"; break; }; done)"
  if [[ -n "$bad_target_path" ]]; then
    record "restore target paths" "fail" "disallowed target_path: $bad_target_path"
  else
    record "restore target paths" "pass" "all target paths are allowed"
  fi

  local missing_source
  missing_source="$(jq -r '.items[]? | select(.selected != false) | .repo_path // empty' "$manifest" | while IFS= read -r p; do [[ -z "$p" ]] && continue; [[ -e "${REPO_ROOT}/${p}" ]] || { printf '%s\n' "$p"; break; }; done)"
  if [[ -n "$missing_source" ]]; then
    record "manifest source paths" "fail" "missing repo source: $missing_source"
  else
    record "manifest source paths" "pass" "all manifest repo sources exist"
  fi

  if [[ -f "$selections" ]]; then
    if json_ok "$selections"; then
      record "selections JSON" "pass" "selections.json is valid JSON"
    else
      record "selections JSON" "fail" "selections.json is not valid JSON"
    fi
  else
    record "selections JSON" "warn" ".dotfriend/selections.json is missing"
  fi

  local generated_script placeholder_file blank_npm_file
  placeholder_file=""
  blank_npm_file=""
  for generated_script in "${REPO_ROOT}/install.sh" "${REPO_ROOT}/bootstrap.sh" "${REPO_ROOT}"/scripts/*.sh; do
    [[ -f "$generated_script" ]] || continue
    if [[ -z "$placeholder_file" ]] && grep -I -E '\{\{[A-Z0-9_:-]+\}\}' "$generated_script" >/dev/null 2>&1; then
      placeholder_file="${generated_script#${REPO_ROOT}/}"
    fi
    if [[ -z "$blank_npm_file" ]] && grep -I -E 'npm install -g[[:space:]]*($|\|\|)' "$generated_script" >/dev/null 2>&1; then
      blank_npm_file="${generated_script#${REPO_ROOT}/}"
    fi
  done
  if [[ -n "$placeholder_file" ]]; then
    record "generated script placeholders" "fail" "unresolved placeholder in $placeholder_file"
  else
    record "generated script placeholders" "pass" "no unresolved generated placeholders"
  fi
  if [[ -n "$blank_npm_file" ]]; then
    record "blank npm install commands" "fail" "blank npm install in $blank_npm_file"
  else
    record "blank npm install commands" "pass" "no blank npm install commands"
  fi

  local brewfile="${REPO_ROOT}/Brewfile"
  if [[ -f "$brewfile" ]]; then
    local dupes="" banned="" line kind item key
    local seen_brew_entries=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$line" ]] && continue
      case "$line" in
        tap\ *|brew\ *|cask\ *|mas\ *)
          kind="${line%% *}"
          item="$(printf '%s' "$line" | sed 's/^[^"]*"\([^"]*\)".*/\1/')"
          if [[ "$kind" == "mas" ]]; then
            item="$(printf '%s' "$line" | grep -oE 'id:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -n1)"
          fi
          [[ -z "$item" ]] && continue
          key="${kind}:${item}"
          if line_set_contains "$seen_brew_entries" "$key" && [[ -z "$dupes" ]]; then
            dupes="$key"
          fi
          seen_brew_entries="${seen_brew_entries}${key}"$'\n'
          case "$key" in
            tap:jordond/tap|brew:jolt)
              [[ -z "$banned" ]] && banned="$key"
              ;;
          esac
          ;;
      esac
    done < "$brewfile"
    if [[ -n "$dupes" ]]; then
      record "Brewfile duplicates" "fail" "duplicate entry: $dupes"
    else
      record "Brewfile duplicates" "pass" "no duplicate package entries"
    fi
    if [[ -n "$banned" ]]; then
      record "Brewfile banned entries" "fail" "banned stale entry: $banned"
    else
      record "Brewfile banned entries" "pass" "no banned stale package entries"
    fi
    if ! jq -e '.items[]? | select(.id == "packages:homebrew" and .repo_path == "Brewfile")' "$manifest" >/dev/null; then
      record "package manifest: homebrew" "fail" "Brewfile is not covered by restore manifest"
    else
      record "package manifest: homebrew" "pass" "Brewfile is covered by restore manifest"
    fi
  fi

  local npmfile="${REPO_ROOT}/npm-global.txt"
  if [[ -f "$npmfile" ]]; then
    local bad_npm=""
    while IFS= read -r pkg || [[ -n "$pkg" ]]; do
      pkg="${pkg%%#*}"
      pkg="$(printf '%s' "$pkg" | xargs 2>/dev/null || true)"
      [[ -z "$pkg" ]] && continue
      if ! npm_package_name_from_spec "$pkg" >/dev/null; then
        bad_npm="$pkg"
        break
      fi
    done < "$npmfile"
    if [[ -n "$bad_npm" ]]; then
      record "npm package names" "fail" "malformed package spec: $bad_npm"
    else
      record "npm package names" "pass" "npm package specs are valid"
    fi
    if ! jq -e '.items[]? | select(.id == "packages:npm_globals" and .repo_path == "npm-global.txt")' "$manifest" >/dev/null; then
      record "package manifest: npm" "fail" "npm-global.txt is not covered by restore manifest"
    else
      record "package manifest: npm" "pass" "npm-global.txt is covered by restore manifest"
    fi
  fi

  if jq -e '.items[]? | select(.type == "macos_defaults")' "$manifest" >/dev/null; then
    local macos_defaults="${REPO_ROOT}/macos/defaults.json"
    local apply_script="${REPO_ROOT}/scripts/apply-macos-defaults.sh"
    if [[ ! -f "$macos_defaults" ]]; then
      record "Mac settings file" "fail" "macos/defaults.json is missing"
    elif ! json_ok "$macos_defaults"; then
      record "Mac settings JSON" "fail" "macos/defaults.json is not valid JSON"
    elif jq -e '
      .schema_version == 1
      and (.entries | type == "array")
      and all(.entries[]?;
        (.id | type == "string" and length > 0)
        and (.domain | type == "string" and length > 0)
        and (.key | type == "string" and length > 0)
        and (.scope | IN("user","currentHost"))
        and (.value_type | IN("bool","int","float","string"))
        and has("value")
      )
    ' "$macos_defaults" >/dev/null; then
      record "Mac settings schema" "pass" "macos/defaults.json is valid"
    else
      record "Mac settings schema" "fail" "macos/defaults.json failed validation"
    fi

    if [[ -x "$apply_script" ]]; then
      record "Mac settings apply script" "pass" "apply-macos-defaults.sh is executable"
    else
      record "Mac settings apply script" "fail" "apply-macos-defaults.sh is missing or not executable"
    fi
  fi

  if [[ -f "$artifacts" ]]; then
    if ! json_ok "$artifacts"; then
      record "agent artifacts JSON" "fail" "agent-artifacts.json is not valid JSON"
    elif jq -e '
      .schema_version == 1
      and (.artifacts | type == "array")
      and all(.artifacts[]?;
        (.managed_by == "dotfriend")
        and (.install.strategy | IN("managed_json_merge","managed_markdown_block","copy_managed_file","rsync_managed_dir","symlink_shared_store","manual_followup"))
        and ((.source.repo_path // "") | startswith("/") | not)
        and ((.source.repo_path // "") | contains("..") | not)
      )
    ' "$artifacts" >/dev/null; then
      record "agent artifacts schema" "pass" "agent-artifacts.json is valid"
    else
      record "agent artifacts schema" "fail" "agent-artifacts.json failed validation"
    fi
  else
    record "agent artifacts" "warn" ".dotfriend/agent-artifacts.json is missing"
  fi

  if find "$REPO_ROOT" \
    -path "${REPO_ROOT}/.git" -prune -o \
    -path '*/node_modules' -prune -o \
    -path '*/site-packages' -prune -o \
    -type f ! -name '*.dotfriend.bak' -print0 2>/dev/null |
    xargs -0 grep -I -E '(BEGIN (RSA|OPENSSH|DSA|EC) PRIVATE KEY|ghp_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|GITHUB_TOKEN=[A-Za-z0-9_]{10,})' >/dev/null 2>&1; then
    record "plaintext secrets" "fail" "obvious secret-looking value found"
  else
    record "plaintext secrets" "pass" "no obvious secret-looking values found"
  fi
}

# ─────────────────────────────────────────────────────────────
# Run checks
# ─────────────────────────────────────────────────────────────

if [[ "$CHECK_BREW" == true ]]; then
  run_check_brew
fi

if [[ "$CHECK_SYMLINKS" == true ]]; then
  run_check_symlinks
fi

if [[ "$CHECK_SHELL" == true ]]; then
  run_check_shell
fi

if [[ "$CHECK_GIT" == true ]]; then
  run_check_git
fi

if [[ "$CHECK_AGENTS" == true ]]; then
  run_check_agents
fi

if [[ "$CHECK_NPM" == true ]]; then
  run_check_npm
fi

if [[ "$CHECK_DOTFRIEND" == true ]]; then
  run_check_dotfriend_metadata
fi

# ─────────────────────────────────────────────────────────────
# Output
# ─────────────────────────────────────────────────────────────

if [[ "$OUTPUT_JSON" == true ]]; then
  printf '{\n  "summary": {\n'
  printf '    "pass": %d,\n' "$total_pass"
  printf '    "fail": %d,\n' "$total_fail"
  printf '    "warn": %d\n' "$total_warn"
  printf '  },\n  "checks": [\n'

  first=true
  for i in "${!CHECKS_NAME[@]}"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      printf ',\n'
    fi
    n="${CHECKS_NAME[$i]}"
    s="${CHECKS_STATUS[$i]}"
    m="${CHECKS_MESSAGE[$i]}"
    printf '    {\n'
    printf '      "name": "%s",\n' "$(printf '%s' "$n" | sed 's/"/\\"/g')"
    printf '      "status": "%s",\n' "$s"
    printf '      "message": "%s"\n' "$(printf '%s' "$m" | sed 's/"/\\"/g')"
    printf '    }'
  done
  printf '\n  ]\n}\n'
  if [[ "$total_fail" -gt 0 ]]; then
    exit 1
  fi
else
  printf '\n'
  printf '%bValidation Results%b\n' "$C_BOLD" "$C_RESET"
  printf '%b──────────────────%b\n\n' "$C_DIM" "$C_RESET"

  for i in "${!CHECKS_NAME[@]}"; do
    n="${CHECKS_NAME[$i]}"
    s="${CHECKS_STATUS[$i]}"
    m="${CHECKS_MESSAGE[$i]}"
    case "$s" in
      pass) icon="$CHECK_PASS" ;;
      fail) icon="$CHECK_FAIL" ;;
      warn) icon="$CHECK_WARN" ;;
    esac
    printf '  %-8s  %-30s  %s\n' "$icon" "$n" "$m"
  done

  printf '\n'
  printf '%bSummary:%b  %s%d passed%b  %s%d failed%b  %s%d warnings%b\n' \
    "$C_BOLD" "$C_RESET" \
    "$C_GREEN" "$total_pass" "$C_RESET" \
    "$C_RED" "$total_fail" "$C_RESET" \
    "$C_YELLOW" "$total_warn" "$C_RESET"
  printf '\n'

  if [[ "$total_fail" -gt 0 ]]; then
    exit 1
  fi
fi
