#!/usr/bin/env bash
# dotfriend — Shared utilities
# shellcheck shell=bash

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────

DOTFRIEND_VERSION="0.3.0"
DOTFRIEND_CACHE_DIR="${HOME}/.cache/dotfriend"
DOTFRIEND_CONFIG_DIR="${HOME}/.config/dotfriend"

# ─────────────────────────────────────────────────────────────
# Colors (fallback when gum is unavailable)
# ─────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_MAGENTA=''
  C_CYAN=''
fi

# ─────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────

log_info()  { printf "${C_BLUE}ℹ${C_RESET}  %s\n" "$*"; }
log_ok()    { printf "${C_GREEN}✔${C_RESET}  %s\n" "$*"; }
log_warn()  { printf "${C_YELLOW}⚠${C_RESET}  %s\n" "$*" >&2; }
log_error() { printf "${C_RED}✖${C_RESET}  %s\n" "$*" >&2; }
log_step()  { printf "\n${C_BOLD}${C_CYAN}→ %s${C_RESET}\n" "$*"; }

# ─────────────────────────────────────────────────────────────
# JSON helpers (portable, no jq required for simple ops)
# ─────────────────────────────────────────────────────────────

json_escape() {
  local str="$1"
  str="${str//\\/\\\\}"
  str="${str//\"/\\\"}"
  str="${str//$'\n'/\\n}"
  str="${str//$'\r'/}"
  str="${str//$'\t'/\\t}"
  printf '%s' "$str"
}

json_set_key() {
  local file="$1" key="$2" value="$3"
  if [[ -f "$file" ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
      # Naive fallback: replace or append
      if grep -q "\"$key\"" "$file" 2>/dev/null; then
        sed -i.bak "s|\"$key\": *\"[^\"]*\"|\"$key\": \"$value\"|" "$file" && rm -f "$file.bak"
      else
        # Append before closing brace
        sed -i.bak 's/}$/,"KEY":"VALUE"}/' "$file" && rm -f "$file.bak"
        sed -i.bak "s/\"KEY\"/\"$key\"/; s/\"VALUE\"/\"$value\"/" "$file" && rm -f "$file.bak"
      fi
    fi
  else
    printf '{"%s":"%s"}\n' "$key" "$(json_escape "$value")" > "$file"
  fi
}

json_get_key() {
  local file="$1" key="$2"
  if [[ -f "$file" ]] && command -v jq >/dev/null 2>&1; then
    jq -r ".$key // empty" "$file"
  elif [[ -f "$file" ]]; then
    # Naive grep fallback
    grep -oP '"'"$key"'"\s*:\s*"\K[^"]+' "$file" 2>/dev/null || true
  fi
}

# ─────────────────────────────────────────────────────────────
# File / path helpers
# ─────────────────────────────────────────────────────────────

ensure_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
  fi
}

# Backup a file before overwriting, placing it in ~/.dotfiles-backup/
backup_file() {
  local src="$1"
  local backup_root="${BACKUP_ROOT:-${HOME}/.dotfiles-backup}"
  local dest="${backup_root}$(basename "$src")-$(date +%Y%m%d-%H%M%S)"
  ensure_dir "$backup_root"
  cp -a "$src" "$dest"
  printf '%s' "$dest"
}

# Check if a path is a symlink (and optionally what it points to)
is_symlink() {
  [[ -L "$1" ]]
}

# Resolve symlink target
read_link() {
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$1" 2>/dev/null || readlink "$1" 2>/dev/null || true
  else
    true
  fi
}

# ─────────────────────────────────────────────────────────────
# Brew helpers
# ─────────────────────────────────────────────────────────────

brew_prefix() {
  if [[ -d /opt/homebrew/bin ]]; then
    printf '%s' '/opt/homebrew'
  elif [[ -d /usr/local/bin ]]; then
    printf '%s' '/usr/local'
  else
    printf '%s' "$HOME/homebrew"
  fi
}

brew_bin() {
  printf '%s/bin/brew' "$(brew_prefix)"
}

has_brew() {
  command -v brew >/dev/null 2>&1 || [[ -x "$(brew_bin)" ]]
}

# ─────────────────────────────────────────────────────────────
# macOS version helpers
# ─────────────────────────────────────────────────────────────

macos_version() {
  sw_vers -productVersion 2>/dev/null || true
}

is_apple_silicon() {
  [[ "$(uname -m)" == "arm64" ]]
}

# Run an optional discovery/sync command with a short timeout. These commands
# improve fidelity when available, but must not block app-managed sync paths.
dotfriend_run_optional_command() {
  local timeout_seconds="${DOTFRIEND_OPTIONAL_COMMAND_TIMEOUT:-5}"
  if [[ ! "$timeout_seconds" =~ ^[0-9]+$ || "$timeout_seconds" -lt 1 ]]; then
    timeout_seconds=5
  fi

  local stdout_file stderr_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"

  "$@" >"$stdout_file" 2>"$stderr_file" &
  local command_pid=$!

  (
    remaining_ticks=$((timeout_seconds * 10))
    while [[ "$remaining_ticks" -gt 0 ]]; do
      sleep 0.1
      if ! kill -0 "$command_pid" >/dev/null 2>&1; then
        exit 0
      fi
      ((remaining_ticks--)) || true
    done
    kill "$command_pid" >/dev/null 2>&1 || true
  ) &
  local watchdog_pid=$!

  local status=0
  if wait "$command_pid"; then
    status=0
  else
    status=$?
  fi
  kill "$watchdog_pid" >/dev/null 2>&1 || true
  wait "$watchdog_pid" >/dev/null 2>&1 || true

  if [[ "$status" -eq 0 ]]; then
    cat "$stdout_file"
  fi

  rm -f "$stdout_file" "$stderr_file"
  return "$status"
}

dotfriend_cached_editor_extensions() {
  local editor_id="$1"
  local cache_file="${DOTFRIEND_CACHE_DIR}/discovery.json"
  [[ -f "$cache_file" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  jq -r --arg editor_id "$editor_id" '.editors[$editor_id].extensions[]? // empty' "$cache_file" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Prompt helpers (plain bash fallbacks when gum is missing)
# ─────────────────────────────────────────────────────────────

prompt_confirm() {
  local msg="${1:-Continue?}"
  local response
  printf "%s [y/N] " "$msg"
  read -r response
  [[ "$response" =~ ^[Yy]$ ]]
}

prompt_input() {
  local msg="${1:-Enter value:}"
  local default="${2:-}"
  local response
  if [[ -n "$default" ]]; then
    printf "%s [%s]: " "$msg" "$default" >&2
  else
    printf "%s: " "$msg" >&2
  fi
  read -r response
  printf '%s' "${response:-$default}"
}

prompt_choose() {
  local msg="${1:-Choose one:}"
  shift
  printf "%s\n" "$msg"
  local i=1 opt
  for opt in "$@"; do
    printf "  %d) %s\n" "$i" "$opt"
    ((i++))
  done
  local response
  printf "Selection: "
  read -r response
  printf '%s' "${response:-1}"
}
