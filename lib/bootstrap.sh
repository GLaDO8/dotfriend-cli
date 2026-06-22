#!/usr/bin/env bash
# dotfriend — Runtime bootstrap for the CLI itself.
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DOTFRIEND_RUNTIME_FORMULAE=(
  git
  jq
  gum
  gh
  mas
  duti
  node
)

refresh_homebrew_env() {
  local brew_path
  brew_path="$(brew_bin)"

  if [[ -x "$brew_path" ]]; then
    eval "$("$brew_path" shellenv)"
  fi
}

require_bootstrap_command() {
  local cmd="$1"
  local help_text="${2:-}"

  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  log_error "Missing required command: $cmd"
  if [[ -n "$help_text" ]]; then
    printf '%s\n' "$help_text" >&2
  fi
  exit 1
}

ensure_xcode_cli() {
  require_bootstrap_command "xcode-select" "dotfriend requires macOS Command Line Tools support."

  if xcode-select -p >/dev/null 2>&1; then
    return 0
  fi

  log_step "Installing Xcode Command Line Tools"
  xcode-select --install 2>/dev/null || true
  log_warn "Complete the Xcode Command Line Tools installer if macOS opened a dialog."

  until xcode-select -p >/dev/null 2>&1; do
    sleep 5
  done

  log_ok "Xcode Command Line Tools installed"
}

ensure_homebrew() {
  require_bootstrap_command "curl" "dotfriend uses curl to install Homebrew."

  if has_brew; then
    refresh_homebrew_env
    return 0
  fi

  log_step "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  refresh_homebrew_env

  if command -v brew >/dev/null 2>&1; then
    log_ok "Homebrew installed"
    return 0
  fi

  log_error "Failed to install Homebrew automatically."
  printf 'Install it manually and run dotfriend again:\n' >&2
  printf '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n' >&2
  exit 1
}

brew_formula_installed() {
  local formula="$1"
  brew list --versions "$formula" >/dev/null 2>&1
}

ensure_runtime_formulae() {
  local -a missing=()
  local formula

  for formula in "${DOTFRIEND_RUNTIME_FORMULAE[@]}"; do
    if ! brew_formula_installed "$formula"; then
      missing+=("$formula")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  log_step "Installing dotfriend runtime dependencies"
  for formula in "${missing[@]}"; do
    log_info "Installing ${formula}..."
    brew install "$formula"
  done
}

verify_runtime_dependencies() {
  local cmd

  require_bootstrap_command "brew"
  for cmd in git jq gum gh mas duti npm; do
    require_bootstrap_command "$cmd"
  done
}

bootstrap_runtime() {
  ensure_dir "${DOTFRIEND_CACHE_DIR}"
  ensure_xcode_cli
  ensure_homebrew
  ensure_runtime_formulae
  refresh_homebrew_env
  verify_runtime_dependencies
}
