#!/usr/bin/env bash
# dotfriend - Apply selected Mac settings.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULTS_FILE="${DOTFRIEND_MACOS_DEFAULTS_FILE:-${REPO_ROOT}/macos/defaults.json}"
BACKUP_ROOT="${BACKUP_ROOT:-${HOME}/.dotfiles-backup}"
DRY_RUN="${DRY_RUN:-false}"

log_info() { printf 'info: %s\n' "$*"; }
log_ok() { printf 'ok: %s\n' "$*"; }
log_warn() { printf 'warn: %s\n' "$*" >&2; }

ensure_dir() {
  [[ -d "$1" ]] || mkdir -p "$1"
}

safe_domain_filename() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

defaults_prefix_for_scope() {
  if [[ "$1" == "currentHost" ]]; then
    printf '%s\n' "-currentHost"
  fi
}

backup_domains() {
  local timestamp backup_dir
  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_ROOT}/macos-defaults/${timestamp}"

  jq -r '.entries[]? | [(.scope // "user"), .domain] | @tsv' "$DEFAULTS_FILE" \
    | sort -u \
    | while IFS=$'\t' read -r scope domain; do
      [[ -n "$domain" ]] || continue
      local filename
      filename="$(safe_domain_filename "$domain")"

      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] Would back up ${domain}"
        continue
      fi

      ensure_dir "$backup_dir"
      if [[ "$scope" == "currentHost" ]]; then
        defaults -currentHost export "$domain" "${backup_dir}/${filename}.plist" >/dev/null 2>&1 || log_warn "Could not back up ${domain}"
      else
        defaults export "$domain" "${backup_dir}/${filename}.plist" >/dev/null 2>&1 || log_warn "Could not back up ${domain}"
      fi
    done
}

write_entry() {
  local entry_json="$1"
  local id domain key scope value_type value_arg flag

  id="$(jq -r '.id' <<< "$entry_json")"
  domain="$(jq -r '.domain' <<< "$entry_json")"
  key="$(jq -r '.key' <<< "$entry_json")"
  scope="$(jq -r '.scope // "user"' <<< "$entry_json")"
  value_type="$(jq -r '.value_type' <<< "$entry_json")"
  value_arg="$(jq -r '.value | tostring' <<< "$entry_json")"

  case "$value_type" in
    bool) flag="-bool" ;;
    int) flag="-int" ;;
    float) flag="-float" ;;
    string) flag="-string" ;;
    *)
      log_warn "Skipping ${id}: unsupported value type ${value_type}"
      return 1
      ;;
  esac

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$scope" == "currentHost" ]]; then
      log_info "[dry-run] Would run: defaults -currentHost write ${domain} ${key} ${flag} ${value_arg}"
    else
      log_info "[dry-run] Would run: defaults write ${domain} ${key} ${flag} ${value_arg}"
    fi
    return 0
  fi

  if [[ "$scope" == "currentHost" ]]; then
    defaults -currentHost write "$domain" "$key" "$flag" "$value_arg"
  else
    defaults write "$domain" "$key" "$flag" "$value_arg"
  fi
}

main() {
  if [[ ! -f "$DEFAULTS_FILE" ]]; then
    log_info "No selected Mac settings found."
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log_warn "jq is required to apply selected Mac settings."
    return 0
  fi

  local restart_file
  restart_file="$(mktemp)"
  trap "rm -f '$restart_file'" EXIT

  backup_domains

  while IFS= read -r entry_json; do
    [[ -n "$entry_json" ]] || continue
    if write_entry "$entry_json"; then
      jq -r '.restart[]? // empty' <<< "$entry_json" >> "$restart_file"
    else
      log_warn "Could not apply $(jq -r '.title // .id' <<< "$entry_json")"
    fi
  done < <(jq -c '.entries[]?' "$DEFAULTS_FILE")

  sort -u "$restart_file" | while IFS= read -r process_name; do
    [[ -n "$process_name" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "[dry-run] Would restart ${process_name}"
    else
      killall "$process_name" >/dev/null 2>&1 || true
    fi
  done

  log_ok "Selected Mac settings applied."
}

main "$@"
