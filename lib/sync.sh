#!/usr/bin/env bash
# dotfriend — Sync command for incremental maintenance
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=gum.sh
source "${SCRIPT_DIR}/gum.sh"
# shellcheck source=api.sh
source "${SCRIPT_DIR}/api.sh"
# shellcheck source=manifest.sh
source "${SCRIPT_DIR}/manifest.sh"
# shellcheck source=discovery.sh
if [[ -f "${SCRIPT_DIR}/discovery.sh" ]]; then
  source "${SCRIPT_DIR}/discovery.sh"
fi

# ─────────────────────────────────────────────────────────────
# State / flags
# ─────────────────────────────────────────────────────────────

DRY_RUN=false
NO_COMMIT=false
QUICK=false
REPO_DIR=""
SYNC_EVENTS="${DOTFRIEND_API_EVENTS:-false}"
SYNC_DRIFT_JSON="[]"
SYNC_WARNING_COUNT=0
SYNC_CHANGE_COUNT=0

# ─────────────────────────────────────────────────────────────
# Repo resolution
# ─────────────────────────────────────────────────────────────

_find_repo() {
  local repo
  # If inside a git repo, use it
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    repo="$(git rev-parse --show-toplevel)"
    printf '%s' "$repo"
    return 0
  fi
  # Fallback to cached repo path
  local cache_file="${DOTFRIEND_CACHE_DIR}/last-sync.json"
  if [[ -f "$cache_file" ]] && command -v jq >/dev/null 2>&1; then
    repo="$(jq -r '.repo_dir // empty' "$cache_file" 2>/dev/null || true)"
    if [[ -n "$repo" && -d "$repo" ]]; then
      printf '%s' "$repo"
      return 0
    fi
  fi
  # Final fallback
  if [[ -d "${HOME}/dotfiles" ]]; then
    printf '%s' "${HOME}/dotfiles"
    return 0
  fi
  return 1
}

_save_repo_cache() {
  ensure_dir "$DOTFRIEND_CACHE_DIR"
  local cache_file="${DOTFRIEND_CACHE_DIR}/last-sync.json"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg repo_dir "$REPO_DIR" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{repo_dir: $repo_dir, last_sync: $timestamp}' > "$cache_file"
  else
    printf '{"repo_dir":"%s","last_sync":"%s"}\n' "$(json_escape "$REPO_DIR")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$cache_file"
  fi
}

_sync_log() {
  printf '%s\n' "$*" >&2
}

_sync_emit_event() {
  local event="$1" payload="${2:-}"
  [[ -n "$payload" ]] || payload="{}"
  if [[ "$SYNC_EVENTS" == "true" ]]; then
    api_event "$event" "$payload"
  fi
}

_sync_warning() {
  local code="$1" message="$2" details="${3:-}"
  [[ -n "$details" ]] || details="{}"
  ((SYNC_WARNING_COUNT++)) || true
  if [[ "$SYNC_EVENTS" == "true" ]]; then
    api_event "warning" "$(jq -cn --arg code "$code" --arg message "$message" --argjson details "$details" '{code:$code,message:$message,details:$details}')"
  else
    log_warn "$message"
  fi
}

_sync_item_changed() {
  local item_id="$1" change="$2" repo_path="$3" target_path="$4" code="$5"
  ((SYNC_CHANGE_COUNT++)) || true
  if [[ "$SYNC_EVENTS" == "true" ]]; then
    api_event "item_changed" "$(jq -cn \
      --arg item_id "$item_id" \
      --arg change "$change" \
      --arg repo_path "$repo_path" \
      --arg target_path "$target_path" \
      --arg code "$code" \
      '{item_id:$item_id,change:$change,repo_path:$repo_path,target_path:$target_path,code:$code}')"
  fi
}

_sync_add_drift() {
  local code="$1" item_id="$2" repo_path="$3" target_path="$4" message="$5"
  local drift_item
  drift_item="$(jq -cn \
    --arg code "$code" \
    --arg item_id "$item_id" \
    --arg repo_path "$repo_path" \
    --arg target_path "$target_path" \
    --arg message "$message" \
    '{code:$code,item_id:$item_id,repo_path:$repo_path,target_path:$target_path,message:$message}')"
  SYNC_DRIFT_JSON="$(jq -c --argjson item "$drift_item" '. + [$item]' <<< "$SYNC_DRIFT_JSON")"
}

_expand_home_path() {
  local path="$1"
  path="${path/#\~/$HOME}"
  path="${path/#\$HOME/$HOME}"
  printf '%s' "$path"
}

_sync_now_seconds() {
  date +%s
}

_sync_file_size() {
  local path="$1"
  stat -f '%z' "$path" 2>/dev/null || stat -c '%s' "$path" 2>/dev/null || wc -c < "$path" | tr -d ' '
}

_sync_files_differ() {
  local repo_file="$1" live_file="$2"

  if [[ ! "$repo_file" -nt "$live_file" && ! "$live_file" -nt "$repo_file" ]]; then
    if [[ "$(_sync_file_size "$repo_file")" == "$(_sync_file_size "$live_file")" ]]; then
      return 1
    fi
  fi

  ! cmp -s "$repo_file" "$live_file" >/dev/null 2>&1
}

_sync_manifest_item_finished() {
  local item_id="$1" item_type="$2" repo_path="$3" target_path="$4" started_at="$5" changes_before="$6" drift_before="$7"
  local finished_at elapsed_seconds drift_count drift_delta change_delta
  finished_at="$(_sync_now_seconds)"
  elapsed_seconds=$((finished_at - started_at))
  drift_count="$(jq -r 'length' <<< "$SYNC_DRIFT_JSON")"
  drift_delta=$((drift_count - drift_before))
  change_delta=$((SYNC_CHANGE_COUNT - changes_before))

  if [[ "$SYNC_EVENTS" == "true" ]]; then
    _sync_log "manifest item ${item_id} finished in ${elapsed_seconds}s (${change_delta} changes, ${drift_delta} drift)"
  else
    log_info "Manifest item ${item_id} finished in ${elapsed_seconds}s (${change_delta} changes, ${drift_delta} drift)"
  fi

  _sync_emit_event "item_finished" "$(jq -cn \
    --arg item_id "$item_id" \
    --arg item_type "$item_type" \
    --arg repo_path "$repo_path" \
    --arg target_path "$target_path" \
    --argjson elapsed_seconds "$elapsed_seconds" \
    --argjson changes "$change_delta" \
    --argjson drift "$drift_delta" \
    '{item_id:$item_id,item_type:$item_type,repo_path:$repo_path,target_path:$target_path,elapsed_seconds:$elapsed_seconds,counts:{changes:$changes,drift:$drift}}')"
}

_load_restore_manifest() {
  local manifest_file="${REPO_DIR}/.dotfriend/restore-manifest.json"
  if [[ ! -f "$manifest_file" ]]; then
    return 1
  fi
  if ! manifest_validate "$manifest_file" >/dev/null 2>&1; then
    _sync_add_drift "manifest_schema_error" "" ".dotfriend/restore-manifest.json" "" "Restore manifest failed validation."
    _sync_warning "manifest_schema_error" "Restore manifest failed validation." '{"path":".dotfriend/restore-manifest.json"}'
    _sync_emit_event "error" '{"code":"manifest_schema_error","message":"Restore manifest failed validation."}'
    return 2
  fi
  printf '%s' "$manifest_file"
  return 0
}

_sync_manifest_file_item() {
  local item_id="$1" repo_path="$2" target_path="$3"
  local repo_source="${REPO_DIR}/${repo_path}"
  local live_target
  live_target="$(_expand_home_path "$target_path")"

  if [[ ! -e "$live_target" ]]; then
    _sync_add_drift "missing_live_target" "$item_id" "$repo_path" "$target_path" "Live target is missing."
    _sync_item_changed "$item_id" "missing_live_target" "$repo_path" "$target_path" "missing_live_target"
    return 0
  fi

  if [[ -d "$live_target" ]]; then
    return 0
  fi

  if [[ ! -e "$repo_source" ]]; then
    _sync_add_drift "missing_repo_source" "$item_id" "$repo_path" "$target_path" "Managed repo source is missing."
    _sync_item_changed "$item_id" "add" "$repo_path" "$target_path" "missing_repo_source"
    if [[ "$DRY_RUN" != true ]]; then
      ensure_dir "$(dirname "$repo_source")"
      cp -a "$live_target" "$repo_source"
    fi
    return 0
  fi

  if _sync_files_differ "$repo_source" "$live_target"; then
    _sync_add_drift "changed_live_file" "$item_id" "$repo_path" "$target_path" "Live file differs from repo source."
    _sync_item_changed "$item_id" "update" "$repo_path" "$target_path" "changed_live_file"
    if [[ "$DRY_RUN" != true ]]; then
      ensure_dir "$(dirname "$repo_source")"
      cp -a "$live_target" "$repo_source"
    fi
  fi
}

_sync_manifest_dir_item() {
  local item_id="$1" repo_path="$2" target_path="$3"
  local filter_profile="${4:-config}"
  local repo_source="${REPO_DIR}/${repo_path}"
  local live_target
  live_target="$(_expand_home_path "$target_path")"

  if [[ ! -d "$live_target" ]]; then
    _sync_add_drift "missing_live_target" "$item_id" "$repo_path" "$target_path" "Live target is missing."
    _sync_item_changed "$item_id" "missing_live_target" "$repo_path" "$target_path" "missing_live_target"
    return 0
  fi

  if [[ ! -d "$repo_source" ]]; then
    _sync_add_drift "missing_repo_source" "$item_id" "$repo_path" "$target_path" "Managed repo source is missing."
    _sync_item_changed "$item_id" "add" "$repo_path" "$target_path" "missing_repo_source"
    if [[ "$DRY_RUN" != true ]]; then
      ensure_dir "$repo_source"
    fi
  fi

  while IFS= read -r -d '' live_file; do
    local rel_path="${live_file#${live_target}/}"
    local repo_file="${repo_source}/${rel_path}"
    local event_repo_path="${repo_path}/${rel_path}"
    local event_target_path="${target_path}/${rel_path}"

    if [[ ! -e "$repo_file" ]]; then
      _sync_add_drift "missing_repo_source" "$item_id" "$event_repo_path" "$event_target_path" "Managed repo source is missing."
      _sync_item_changed "$item_id" "add" "$event_repo_path" "$event_target_path" "missing_repo_source"
      if [[ "$DRY_RUN" != true ]]; then
        ensure_dir "$(dirname "$repo_file")"
        cp -a "$live_file" "$repo_file"
      fi
      continue
    fi

    if _sync_files_differ "$repo_file" "$live_file"; then
      _sync_add_drift "changed_live_file" "$item_id" "$event_repo_path" "$event_target_path" "Live file differs from repo source."
      _sync_item_changed "$item_id" "update" "$event_repo_path" "$event_target_path" "changed_live_file"
      if [[ "$DRY_RUN" != true ]]; then
        cp -a "$live_file" "$repo_file"
      fi
    fi
  done < <(_sync_find_files_filtered "$live_target" "$filter_profile")

  if [[ -d "$repo_source" ]]; then
    while IFS= read -r -d '' repo_file; do
      local rel_path="${repo_file#${repo_source}/}"
      local live_file="${live_target}/${rel_path}"
      if [[ ! -e "$live_file" ]]; then
        _sync_add_drift "changed_repo_file" "$item_id" "${repo_path}/${rel_path}" "${target_path}/${rel_path}" "Repo file has no live counterpart."
        _sync_item_changed "$item_id" "repo_only" "${repo_path}/${rel_path}" "${target_path}/${rel_path}" "changed_repo_file"
      fi
    done < <(_sync_find_files_filtered "$repo_source" "$filter_profile")
  fi
}

_sync_find_files_filtered() {
  local root="$1" filter_profile="${2:-config}"
  if [[ "$filter_profile" == "config" ]]; then
    find "$root" \
      \( -name '.git' -o -name 'node_modules' -o -name 'bower_components' -o -name 'jspm_packages' -o -name '.next' -o -name 'dist' -o -name 'build' -o -name '.build' -o -name 'coverage' -o -name 'vendor' -o -name 'Pods' -o -name '.gradle' -o -name '__pycache__' -o -name '.pytest_cache' -o -name '.mypy_cache' -o -name '.ruff_cache' -o -name '.tox' -o -name 'virtenv' -o -name 'venv' -o -name '.venv' -o -name 'virtualenv' -o -name 'gcloud' -o -name '.gcloud' -o -name '.cache' -o -name 'cache' -o -name 'Cache' -o -name 'Caches' -o -name '.npm' -o -name '.pnpm-store' -o -name '.yarn' -o -name 'tmp' -o -name 'temp' -o -name 'logs' -o -name 'log' -o -name 'marketplace' -o -name 'marketplaces' -o -name 'plugin-marketplace' -o -name 'plugin-marketplaces' -o -name 'sessions' -o -name 'archived_sessions' -o -name 'generated' -o -name '.generated' -o -name 'generated_images' -o -name 'sqlite' -o -name '.turbo' -o -name '.parcel-cache' -o -name '.vite' -o -name '.nuxt' -o -name '.svelte-kit' -o -name '.astro' -o -name 'extensions' \) \
      -prune -o -type f -print0 2>/dev/null || true
  else
    find "$root" \
      \( -name '.git' -o -name 'node_modules' -o -name 'bower_components' -o -name 'jspm_packages' -o -name '.next' -o -name 'dist' -o -name 'build' -o -name '.build' -o -name 'coverage' -o -name 'vendor' -o -name 'Pods' -o -name '.gradle' -o -name '__pycache__' -o -name '.pytest_cache' -o -name '.mypy_cache' -o -name '.ruff_cache' -o -name '.tox' -o -name 'virtenv' -o -name 'venv' -o -name '.venv' -o -name 'virtualenv' -o -name 'gcloud' -o -name '.gcloud' -o -name '.cache' -o -name 'cache' -o -name 'Cache' -o -name 'Caches' -o -name '.npm' -o -name '.pnpm-store' -o -name '.yarn' -o -name 'tmp' -o -name 'temp' -o -name 'logs' -o -name 'log' -o -name 'marketplace' -o -name 'marketplaces' -o -name 'plugin-marketplace' -o -name 'plugin-marketplaces' -o -name 'sessions' -o -name 'archived_sessions' -o -name 'generated' -o -name '.generated' -o -name 'generated_images' -o -name 'sqlite' -o -name '.turbo' -o -name '.parcel-cache' -o -name '.vite' -o -name '.nuxt' -o -name '.svelte-kit' -o -name '.astro' \) \
      -prune -o -type f -print0 2>/dev/null || true
  fi
}

_sync_manifest_path_is_skipped() {
  local path="$1" skips="$2" skip expanded_skip
  while IFS= read -r skip; do
    [[ -n "$skip" ]] || continue
    expanded_skip="$(_expand_home_path "$skip")"
    if [[ "$path" == "$expanded_skip" || "$path" == "${expanded_skip}/"* ]]; then
      return 0
    fi
  done <<< "$skips"
  return 1
}

_sync_manifest_agent_config_item() {
  local item_id="$1" repo_path="$2" target_path="$3" item_json="$4"
  local live_root
  live_root="$(_expand_home_path "$target_path")"

  if [[ ! -d "$live_root" ]]; then
    _sync_add_drift "missing_live_target" "$item_id" "$repo_path" "$target_path" "Live target is missing."
    _sync_item_changed "$item_id" "missing_live_target" "$repo_path" "$target_path" "missing_live_target"
    return 0
  fi

  local symlinks_to_skip
  symlinks_to_skip="$(jq -r '.metadata.symlinks_to_skip // [] | .[]' <<< "$item_json" 2>/dev/null || true)"

  local rel_path live_path
  while IFS= read -r rel_path; do
    [[ -n "$rel_path" ]] || continue
    live_path="${live_root}/${rel_path}"
    if [[ -L "$live_path" ]] || _sync_manifest_path_is_skipped "$live_path" "$symlinks_to_skip"; then
      continue
    fi
    _sync_manifest_file_item "${item_id}:${rel_path}" "${repo_path}/${rel_path}" "${target_path}/${rel_path}"
  done < <(jq -r '.metadata.important_files // [] | .[]' <<< "$item_json" 2>/dev/null || true)

  while IFS= read -r rel_path; do
    [[ -n "$rel_path" ]] || continue
    live_path="${live_root}/${rel_path}"
    if [[ -L "$live_path" ]] || _sync_manifest_path_is_skipped "$live_path" "$symlinks_to_skip"; then
      continue
    fi
    _sync_manifest_dir_item "${item_id}:${rel_path}" "${repo_path}/${rel_path}" "${target_path}/${rel_path}" "agent"
  done < <(jq -r '.metadata.important_dirs // [] | .[]' <<< "$item_json" 2>/dev/null || true)
}

_sync_manifest_untracked_discovered_configs() {
  local manifest_file="$1"
  local discovery_file="${DOTFRIEND_CACHE_DIR}/discovery.json"
  [[ -f "$discovery_file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local discovered selected config_name
  discovered="$(jq -r '
    if (.schema_version // 1) == 2 then
      .config_dirs[]? | if type == "object" then (.name // empty) else . end
    else
      (.config_dirs // "" | split("\n")[]?)
    end
  ' "$discovery_file" 2>/dev/null || true)"
  selected="$(jq -r '.items[]? | select(.selected != false and .type == "config_dir") | .target_path | sub("^~/.config/"; "")' "$manifest_file" 2>/dev/null || true)"

  while IFS= read -r config_name; do
    [[ -n "$config_name" ]] || continue
    if ! printf '%s\n' "$selected" | grep -qxF "$config_name"; then
      _sync_add_drift "untracked_discovered_config" "config_dir:${config_name}" "config/${config_name}" "~/.config/${config_name}" "Discovered config is not selected in the restore manifest."
      _sync_item_changed "config_dir:${config_name}" "untracked" "config/${config_name}" "~/.config/${config_name}" "untracked_discovered_config"
    fi
  done <<< "$discovered"
}

sync_manifest_owned_paths() {
  local manifest_file="$1"
  local item_json item_id item_type repo_path target_path restore_mode

  _sync_emit_event "step_started" '{"step":"manifest_sync","label":"Syncing manifest-owned paths"}'

  while IFS= read -r item_json; do
    [[ -n "$item_json" ]] || continue
    item_id="$(jq -r '.id' <<< "$item_json")"
    item_type="$(jq -r '.type // empty' <<< "$item_json")"
    repo_path="$(jq -r '.repo_path // empty' <<< "$item_json")"
    target_path="$(jq -r '.target_path // empty' <<< "$item_json")"
    restore_mode="$(jq -r '.restore_mode // empty' <<< "$item_json")"

    [[ -n "$repo_path" && -n "$target_path" ]] || continue
    local item_started_at item_changes_before item_drift_before
    item_started_at="$(_sync_now_seconds)"
    item_changes_before="$SYNC_CHANGE_COUNT"
    item_drift_before="$(jq -r 'length' <<< "$SYNC_DRIFT_JSON")"
    _sync_emit_event "item_started" "$(jq -cn \
      --arg item_id "$item_id" \
      --arg item_type "$item_type" \
      --arg repo_path "$repo_path" \
      --arg target_path "$target_path" \
      '{item_id:$item_id,item_type:$item_type,repo_path:$repo_path,target_path:$target_path}')"

    if [[ "$item_type" == "agent_config" ]]; then
      _sync_manifest_agent_config_item "$item_id" "$repo_path" "$target_path" "$item_json"
      _sync_manifest_item_finished "$item_id" "$item_type" "$repo_path" "$target_path" "$item_started_at" "$item_changes_before" "$item_drift_before"
      continue
    fi

    case "$restore_mode" in
      copy|rsync)
        _sync_manifest_dir_item "$item_id" "$repo_path" "$target_path"
        ;;
      symlink|managed_json_merge|managed_markdown_block|defaults_import)
        _sync_manifest_file_item "$item_id" "$repo_path" "$target_path"
        ;;
      *)
        ;;
    esac
    _sync_manifest_item_finished "$item_id" "$item_type" "$repo_path" "$target_path" "$item_started_at" "$item_changes_before" "$item_drift_before"
  done < <(jq -c '.items[]? | select(.selected != false)' "$manifest_file")

  _sync_manifest_untracked_discovered_configs "$manifest_file"

  _sync_emit_event "step_finished" "$(jq -cn --arg step "manifest_sync" --arg status "ok" --argjson counts "$(jq -cn --argjson drift "$SYNC_DRIFT_JSON" --argjson changes "$SYNC_CHANGE_COUNT" '{drift:($drift|length),changes:$changes}')" '{step:$step,status:$status,counts:$counts}')"

  if [[ "$SYNC_EVENTS" != "true" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      gum_style --foreground "#8BE9FD" "  Manifest sync: ${SYNC_CHANGE_COUNT} changes, $(jq -r 'length' <<< "$SYNC_DRIFT_JSON") drift items (dry-run)"
    else
      gum_style --foreground "#8BE9FD" "  Manifest sync: ${SYNC_CHANGE_COUNT} changes"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────
# Config sync
# ─────────────────────────────────────────────────────────────

sync_configs() {
  log_step "Config Sync"

  local config_repo_dir="${REPO_DIR}/config"
  if [[ ! -d "$config_repo_dir" ]]; then
    log_info "No config/ directory tracked in repo. Skipping config sync."
    return 0
  fi

  local changed_count=0
  local added_count=0
  local removed_count=0

  # Iterate over each tracked config directory in the repo
  while IFS= read -r -d '' tracked_dir; do
    local app_name
    app_name="$(basename "$tracked_dir")"
    local live_dir="${HOME}/.config/${app_name}"

    if [[ ! -d "$live_dir" ]]; then
      log_warn "Live config missing for ${app_name}: ${live_dir}"
      ((removed_count++)) || true
      continue
    fi

    # Compare files in repo vs live using find
    while IFS= read -r -d '' repo_file; do
      local rel_path="${repo_file#${tracked_dir}/}"
      local live_file="${live_dir}/${rel_path}"

      if [[ ! -e "$live_file" ]]; then
        log_warn "Live file removed: ${app_name}/${rel_path}"
        ((removed_count++)) || true
        continue
      fi

      if _sync_files_differ "$repo_file" "$live_file"; then
        if [[ "$DRY_RUN" == true ]]; then
          gum_style --foreground "#F1FA8C" "  [dry-run] Would update ${app_name}/${rel_path}"
        else
          cp -a "$live_file" "$repo_file"
          log_ok "Updated ${app_name}/${rel_path}"
        fi
        ((changed_count++)) || true
      fi
    done < <(find "$tracked_dir" -type f -print0 2>/dev/null || true)

    # Detect new files in live dir not in repo
    while IFS= read -r -d '' live_file; do
      local rel_path="${live_file#${live_dir}/}"
      local repo_file="${tracked_dir}/${rel_path}"
      if [[ ! -e "$repo_file" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
          gum_style --foreground "#50FA7B" "  [dry-run] Would add ${app_name}/${rel_path}"
        else
          ensure_dir "$(dirname "$repo_file")"
          cp -a "$live_file" "$repo_file"
          log_ok "Added ${app_name}/${rel_path}"
        fi
        ((added_count++)) || true
      fi
    done < <(find "$live_dir" -type f -print0 2>/dev/null || true)

  done < <(find "$config_repo_dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null || true)

  if [[ "$DRY_RUN" == true ]]; then
    gum_style --foreground "#8BE9FD" "  Configs: ${changed_count} changed, ${added_count} new, ${removed_count} removed (dry-run)"
  else
    gum_style --foreground "#8BE9FD" "  Configs: ${changed_count} updated, ${added_count} added, ${removed_count} removed"
  fi
}

# ─────────────────────────────────────────────────────────────
# Brewfile sync
# ─────────────────────────────────────────────────────────────

_brewfile_path() {
  printf '%s/Brewfile' "$REPO_DIR"
}

_brewfile_section_items() {
  local file="$1" section="$2"
  local in_section=false
  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Detect section header (e.g., "tap \"...\"" or "tap do ... end")
    if [[ "$line" =~ ^[[:space:]]*${section}[[:space:]] ]]; then
      in_section=true
      # Extract quoted item if on same line
      local item
      item="$(printf '%s' "$line" | grep -oE '"[^"]+"' | head -n1 | tr -d '"' || true)"
      if [[ -n "$item" ]]; then
        printf '%s\n' "$item"
      fi
      continue
    fi

    # Simple heuristic: if line starts with a known section keyword, we're leaving this section
    if [[ "$line" =~ ^[[:space:]]*(tap|brew|cask|mas|go)[[:space:]] ]]; then
      in_section=false
      continue
    fi

    if [[ "$in_section" == true ]]; then
      local item
      item="$(printf '%s' "$line" | grep -oE '"[^"]+"' | head -n1 | tr -d '"' || true)"
      if [[ -n "$item" ]]; then
        printf '%s\n' "$item"
      fi
    fi
  done < "$file"
}

_brewfile_add_to_section() {
  local file="$1" section="$2" item="$3"

  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi

  if ! grep -q "^${section} \"${item}\"" "$file" 2>/dev/null; then
    # Find the line of the section and append after its last entry
    local tmpfile="${file}.tmp"
    local awk_script='
      BEGIN { in_section=0 }
      /^[[:space:]]*sect[[:space:]]/ { in_section=1; print; next }
      in_section && /^[[:space:]]*(tap|brew|cask|mas|go)[[:space:]]/ { in_section=0 }
      in_section && /^[[:space:]]*end/ { print "  \"" item "\""; in_section=0 }
      { print }
    '
    # For simple one-line format: tap "foo", brew "bar", etc.
    # We will append before the next section or at EOF
    awk -v sect="$section" -v it="$item" '
      BEGIN { found=0 }
      /^[[:space:]]*sect[[:space:]]/ { found=1 }
      found && /^[[:space:]]*(tap|brew|cask|mas|go)[[:space:]]/ && $0 !~ /^[[:space:]]*sect[[:space:]]/ {
        print sect " \"" it "\""
        found=0
      }
      { print }
      END { if (found) print sect " \"" it "\"" }
    ' "$file" > "$tmpfile" && mv "$tmpfile" "$file"
  fi
}

sync_brewfile() {
  log_step "Brew Sync"

  local brewfile
  brewfile="$(_brewfile_path)"

  if [[ ! -f "$brewfile" ]]; then
    log_info "No Brewfile found in repo. Skipping brew sync."
    return 0
  fi

  if ! has_brew; then
    log_warn "Homebrew not found. Skipping brew sync."
    return 0
  fi

  local new_taps=()
  local new_brews=()
  local new_casks=()
  local new_mas=()

  # Taps
  local current_taps tracked_taps tap
  current_taps="$(brew tap 2>/dev/null || true)"
  tracked_taps="$(_brewfile_section_items "$brewfile" tap)"
  while IFS= read -r tap; do
    [[ -z "$tap" ]] && continue
    if ! printf '%s\n' "$tracked_taps" | grep -qxF "$tap"; then
      new_taps+=("$tap")
    fi
  done <<< "$current_taps"

  # Formulae
  local current_formulae tracked_formulae formula
  current_formulae="$(brew list --formula 2>/dev/null || true)"
  tracked_formulae="$(_brewfile_section_items "$brewfile" brew)"
  while IFS= read -r formula; do
    [[ -z "$formula" ]] && continue
    if ! printf '%s\n' "$tracked_formulae" | grep -qxF "$formula"; then
      new_brews+=("$formula")
    fi
  done <<< "$current_formulae"

  # Casks
  local current_casks tracked_casks cask
  current_casks="$(brew list --cask 2>/dev/null || true)"
  tracked_casks="$(_brewfile_section_items "$brewfile" cask)"
  while IFS= read -r cask; do
    [[ -z "$cask" ]] && continue
    if ! printf '%s\n' "$tracked_casks" | grep -qxF "$cask"; then
      new_casks+=("$cask")
    fi
  done <<< "$current_casks"

  # MAS apps
  local current_mas tracked_mas mas_line mas_id mas_name
  if command -v mas >/dev/null 2>&1; then
    current_mas="$(mas list 2>/dev/null || true)"
    tracked_mas="$(_brewfile_section_items "$brewfile" mas)"
    while IFS= read -r mas_line; do
      [[ -z "$mas_line" ]] && continue
      # mas list format: "123456789 App Name  (1.0)"
      mas_id="$(printf '%s' "$mas_line" | awk '{print $1}')"
      [[ -z "$mas_id" ]] && continue
      if ! printf '%s\n' "$tracked_mas" | grep -qxF "$mas_id"; then
        new_mas+=("$mas_id")
      fi
    done <<< "$current_mas"
  fi

  local total_new=$(( ${#new_taps[@]} + ${#new_brews[@]} + ${#new_casks[@]} + ${#new_mas[@]} ))

  if [[ "$total_new" -eq 0 ]]; then
    log_ok "Brewfile is up to date."
    return 0
  fi

  if [[ "$QUICK" == true ]]; then
    for tap in "${new_taps[@]}"; do
      _brewfile_add_to_section "$brewfile" tap "$tap"
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] Would add tap ${tap}"
      else
        log_ok "Added tap ${tap}"
      fi
    done
    for formula in "${new_brews[@]}"; do
      _brewfile_add_to_section "$brewfile" brew "$formula"
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] Would add brew ${formula}"
      else
        log_ok "Added brew ${formula}"
      fi
    done
    for cask in "${new_casks[@]}"; do
      _brewfile_add_to_section "$brewfile" cask "$cask"
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] Would add cask ${cask}"
      else
        log_ok "Added cask ${cask}"
      fi
    done
    for mas_id in "${new_mas[@]}"; do
      _brewfile_add_to_section "$brewfile" mas "$mas_id"
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] Would add mas ${mas_id}"
      else
        log_ok "Added mas ${mas_id}"
      fi
    done
    return 0
  fi

  # Interactive: offer to add each category
  local to_add=()

  if [[ ${#new_taps[@]} -gt 0 ]]; then
    gum_style --foreground "#FFB86C" "New taps detected:"
    printf '  %s\n' "${new_taps[@]}"
    if gum_confirm --prompt "Add all new taps to Brewfile?"; then
      to_add+=("tap:${new_taps[*]}")
    fi
  fi

  if [[ ${#new_brews[@]} -gt 0 ]]; then
    gum_style --foreground "#FFB86C" "New formulae detected:"
    printf '  %s\n' "${new_brews[@]}"
    if gum_confirm --prompt "Add all new formulae to Brewfile?"; then
      to_add+=("brew:${new_brews[*]}")
    fi
  fi

  if [[ ${#new_casks[@]} -gt 0 ]]; then
    gum_style --foreground "#FFB86C" "New casks detected:"
    printf '  %s\n' "${new_casks[@]}"
    if gum_confirm --prompt "Add all new casks to Brewfile?"; then
      to_add+=("cask:${new_casks[*]}")
    fi
  fi

  if [[ ${#new_mas[@]} -gt 0 ]]; then
    gum_style --foreground "#FFB86C" "New Mac App Store apps detected:"
    printf '  %s\n' "${new_mas[@]}"
    if gum_confirm --prompt "Add all new MAS apps to Brewfile?"; then
      to_add+=("mas:${new_mas[*]}")
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log_info "Dry-run: would add ${#to_add[@]} categories to Brewfile."
    return 0
  fi

  local entry
  for entry in "${to_add[@]}"; do
    local section="${entry%%:*}"
    local items="${entry#*:}"
    local item
    for item in $items; do
      _brewfile_add_to_section "$brewfile" "$section" "$item"
      log_ok "Added ${section} ${item}"
    done
  done
}

# ─────────────────────────────────────────────────────────────
# npm sync
# ─────────────────────────────────────────────────────────────

sync_npm() {
  log_step "npm Global Sync"

  if ! command -v npm >/dev/null 2>&1; then
    log_info "npm not found. Skipping npm sync."
    return 0
  fi

  local tracked_file="${REPO_DIR}/npm-globals.txt"
  local tracked=()
  if [[ -f "$tracked_file" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      tracked+=("$line")
    done < "$tracked_file"
  fi

  local current current_name new_packages=()
  current="$(npm list -g --depth=0 --json 2>/dev/null | node -e '
    const data = JSON.parse(require("fs").readFileSync(0, "utf-8"));
    const deps = data.dependencies || {};
    Object.keys(deps).forEach(k => console.log(k + "@" + (deps[k].version || "")));
  ' 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Parse package name from lines like "@openai/codex@1.2.3"
    current_name="$(printf '%s' "$line" | sed -E 's/@[^@]+$//')"
    [[ -z "$current_name" ]] && continue
    local found=false
    local t
    for t in "${tracked[@]}"; do
      if [[ "$t" == "$current_name" ]]; then
        found=true
        break
      fi
    done
    if [[ "$found" == false ]]; then
      new_packages+=("$current_name")
    fi
  done <<< "$current"

  if [[ ${#new_packages[@]} -eq 0 ]]; then
    log_ok "No new global npm packages detected."
    return 0
  fi

  gum_style --foreground "#FFB86C" "New global npm packages detected:"
  printf '  %s\n' "${new_packages[@]}"

  if [[ "$QUICK" == true ]]; then
    for pkg in "${new_packages[@]}"; do
      if [[ "$DRY_RUN" == true ]]; then
        gum_style --foreground "#50FA7B" "  [dry-run] Would add ${pkg}"
      else
        printf '%s\n' "$pkg" >> "$tracked_file"
        log_ok "Added ${pkg}"
      fi
    done
    return 0
  fi

  if gum_confirm --prompt "Add new global npm packages to tracked list?"; then
    for pkg in "${new_packages[@]}"; do
      if [[ "$DRY_RUN" == true ]]; then
        gum_style --foreground "#50FA7B" "  [dry-run] Would add ${pkg}"
      else
        printf '%s\n' "$pkg" >> "$tracked_file"
        log_ok "Added ${pkg}"
      fi
    done
  fi
}

# ─────────────────────────────────────────────────────────────
# Editor extension sync
# ─────────────────────────────────────────────────────────────

sync_editor_extensions() {
  log_step "Editor Extension Sync"

  local synced_any=false
  local target_file tmpfile

  if [[ -d "${REPO_DIR}/vscode" ]]; then
    synced_any=true
    if command -v code >/dev/null 2>&1; then
      target_file="${REPO_DIR}/vscode/extensions.txt"
      tmpfile="$(mktemp)"
      code --list-extensions 2>/dev/null | sort > "$tmpfile"

      if [[ "$DRY_RUN" == true ]]; then
        if [[ ! -f "$target_file" ]] || _sync_files_differ "$target_file" "$tmpfile"; then
          gum_style --foreground "#F1FA8C" "  [dry-run] Would update vscode/extensions.txt"
        else
          log_ok "VS Code extensions are up to date."
        fi
      else
        ensure_dir "$(dirname "$target_file")"
        if [[ ! -f "$target_file" ]] || _sync_files_differ "$target_file" "$tmpfile"; then
          mv "$tmpfile" "$target_file"
          tmpfile=""
          log_ok "Updated vscode/extensions.txt"
        else
          log_ok "VS Code extensions are up to date."
        fi
      fi

      [[ -n "${tmpfile:-}" ]] && rm -f "$tmpfile"
    else
      log_warn "VS Code CLI not found. Skipping vscode/extensions.txt sync."
    fi
  fi

  if [[ -d "${REPO_DIR}/cursor" ]]; then
    synced_any=true
    if command -v cursor >/dev/null 2>&1; then
      target_file="${REPO_DIR}/cursor/extensions.txt"
      tmpfile="$(mktemp)"
      cursor --list-extensions 2>/dev/null | sort > "$tmpfile"

      if [[ "$DRY_RUN" == true ]]; then
        if [[ ! -f "$target_file" ]] || _sync_files_differ "$target_file" "$tmpfile"; then
          gum_style --foreground "#F1FA8C" "  [dry-run] Would update cursor/extensions.txt"
        else
          log_ok "Cursor extensions are up to date."
        fi
      else
        ensure_dir "$(dirname "$target_file")"
        if [[ ! -f "$target_file" ]] || _sync_files_differ "$target_file" "$tmpfile"; then
          mv "$tmpfile" "$target_file"
          tmpfile=""
          log_ok "Updated cursor/extensions.txt"
        else
          log_ok "Cursor extensions are up to date."
        fi
      fi

      [[ -n "${tmpfile:-}" ]] && rm -f "$tmpfile"
    else
      log_warn "Cursor CLI not found. Skipping cursor/extensions.txt sync."
    fi
  fi

  if [[ "$synced_any" == false ]]; then
    log_info "No editor extension manifests tracked in repo. Skipping editor extension sync."
  fi
}

# ─────────────────────────────────────────────────────────────
# Agent sync
# ─────────────────────────────────────────────────────────────

sync_agents() {
  log_step "Agent Config Sync"

  local selections_file="${DOTFRIEND_CACHE_DIR}/selections.json"
  if [[ ! -f "$selections_file" ]]; then
    log_info "No agent selections found (run dotfriend start first). Skipping agent sync."
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log_warn "jq is required for agent sync. Skipping."
    return 0
  fi

  local selected_agents
  selected_agents="$(jq -r '.agents // empty | .[] | .id' "$selections_file" 2>/dev/null || true)"
  if [[ -z "$selected_agents" ]]; then
    log_info "No agents selected for backup. Skipping agent sync."
    return 0
  fi

  local agent_id changed_count=0
  while IFS= read -r agent_id; do
    [[ -z "$agent_id" ]] && continue

    local canonical_dir
    canonical_dir="$(jq -r --arg id "$agent_id" '.agentic_tools[] | select(.id == $id) | .canonical_dir' "${SCRIPT_DIR}/agent-tools.json" 2>/dev/null || true)"
    if [[ -z "$canonical_dir" || "$canonical_dir" == "null" ]]; then
      log_warn "Unknown agent: $agent_id"
      continue
    fi
    canonical_dir="${canonical_dir/#\~/${HOME}}"

    local live_dir="$canonical_dir"
    local repo_dir="${REPO_DIR}/${agent_id}"

    if [[ ! -d "$live_dir" ]]; then
      log_warn "Agent config directory not found: ${live_dir}"
      continue
    fi

    ensure_dir "$repo_dir"

    # Read important files, dirs, and symlinks to skip from agent-tools.json
    local important_files important_dirs symlinks_to_skip
    important_files="$(jq -r --arg id "$agent_id" '.agentic_tools[] | select(.id == $id) | .important_files // [] | .[]' "${SCRIPT_DIR}/agent-tools.json" 2>/dev/null || true)"
    important_dirs="$(jq -r --arg id "$agent_id" '.agentic_tools[] | select(.id == $id) | .important_dirs // [] | .[]' "${SCRIPT_DIR}/agent-tools.json" 2>/dev/null || true)"
    symlinks_to_skip="$(jq -r --arg id "$agent_id" '.agentic_tools[] | select(.id == $id) | .symlinks_to_skip // [] | .[]' "${SCRIPT_DIR}/agent-tools.json" 2>/dev/null || true)"

    # Build a list of live files to sync from important_files and important_dirs
    local -a files_to_sync=()

    # Add individual files
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local src="${live_dir}/${f}"
      if [[ -e "$src" && ! -L "$src" ]]; then
        files_to_sync+=("$src")
      elif [[ -L "$src" ]]; then
        log_info "Skipping symlink: ${src}"
      fi
    done <<< "$important_files"

    # Add files from important directories
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      local src="${live_dir}/${d}"
      if [[ -d "$src" && ! -L "$src" ]]; then
        while IFS= read -r -d '' live_file; do
          files_to_sync+=("$live_file")
        done < <(find "$src" -type f -print0 2>/dev/null || true)
      elif [[ -L "$src" ]]; then
        log_info "Skipping symlinked dir: ${src}"
      fi
    done <<< "$important_dirs"

    # Sync each file
    local live_file
    for live_file in "${files_to_sync[@]}"; do
      local rel_path="${live_file#${live_dir}/}"
      local repo_file="${repo_dir}/${rel_path}"

      # Skip if path matches any symlinks_to_skip prefix
      local skip_path skip=false
      while IFS= read -r skip_path; do
        [[ -z "$skip_path" ]] && continue
        skip_path="${skip_path/#\~/${HOME}}"
        if [[ "$live_file" == "${skip_path}"* || "$live_file" == "$skip_path" ]]; then
          skip=true
          break
        fi
      done <<< "$symlinks_to_skip"
      [[ "$skip" == true ]] && continue

      # Skip actual symlinks
      if is_symlink "$live_file"; then
        continue
      fi

      if [[ ! -e "$repo_file" ]] || _sync_files_differ "$repo_file" "$live_file"; then
        if [[ "$DRY_RUN" == true ]]; then
          if [[ ! -e "$repo_file" ]]; then
            gum_style --foreground "#50FA7B" "  [dry-run] Would add ${agent_id}/${rel_path}"
          else
            gum_style --foreground "#F1FA8C" "  [dry-run] Would update ${agent_id}/${rel_path}"
          fi
        else
          ensure_dir "$(dirname "$repo_file")"
          cp -a "$live_file" "$repo_file"
          log_ok "Synced ${agent_id}/${rel_path}"
        fi
        ((changed_count++)) || true
      fi
    done

  done <<< "$selected_agents"

  if [[ "$DRY_RUN" == true ]]; then
    gum_style --foreground "#8BE9FD" "  Agents: ${changed_count} changes (dry-run)"
  else
    gum_style --foreground "#8BE9FD" "  Agents: ${changed_count} files synced"
  fi
}

# ─────────────────────────────────────────────────────────────
# Diff summary
# ─────────────────────────────────────────────────────────────

show_diff_summary() {
  log_step "Diff Summary"

  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    log_warn "Not a git repository. Skipping diff summary."
    return 0
  fi

  local diff_output
  diff_output="$(cd "$REPO_DIR" && git diff --stat 2>/dev/null || true)"
  if [[ -z "$diff_output" ]]; then
    log_info "No changes to show"
    return 0
  fi
  printf '%s\n' "$diff_output" | gum_pager
}

# ─────────────────────────────────────────────────────────────
# Commit & push
# ─────────────────────────────────────────────────────────────

prompt_commit() {
  if [[ "$NO_COMMIT" == true ]]; then
    log_info "--no-commit set. Skipping commit."
    return 0
  fi

  log_step "Commit"

  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    log_warn "Not a git repository. Skipping commit."
    return 0
  fi

  local diff_count
  diff_count="$(cd "$REPO_DIR" && git diff --numstat 2>/dev/null | wc -l | tr -d ' ' || true)"
  if [[ "$diff_count" -eq 0 ]]; then
    log_info "No changes to commit."
    return 0
  fi

  local default_msg
  default_msg="sync: update dotfiles ($(date +%Y-%m-%d))"

  local msg
  if [[ "$QUICK" == true ]]; then
    msg="$default_msg"
  else
    msg="$(gum_input --placeholder "Commit message" --value "$default_msg")"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    gum_style --foreground "#F1FA8C" "[dry-run] Would commit with message: ${msg}"
    return 0
  fi

  (cd "$REPO_DIR" && git add -A && git commit -m "$msg") || {
    log_warn "Commit failed or nothing to commit."
    return 0
  }

  if gum_confirm --prompt "Push to remote?"; then
    local branch
    branch="$(cd "$REPO_DIR" && git branch --show-current 2>/dev/null || printf 'main')"
    (cd "$REPO_DIR" && git push origin "$branch") || log_warn "Push failed."
  fi
}

# ─────────────────────────────────────────────────────────────
# Main command
# ─────────────────────────────────────────────────────────────

cmd_sync() {
  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --no-commit) NO_COMMIT=true; shift ;;
      --quick) QUICK=true; shift ;;
      --) shift; break ;;
      -*)
        log_error "Unknown flag: $1"
        printf 'Usage: dotfriend sync [--dry-run] [--no-commit] [--quick]\n' >&2
        return 1
        ;;
      *) break ;;
    esac
  done

  if [[ "$DRY_RUN" == true ]]; then
    if [[ "$SYNC_EVENTS" == "true" ]]; then
      _sync_log "Dry-run mode: no files will be modified."
    else
      gum_style --foreground "#F1FA8C" "🛡  Dry-run mode: no files will be modified."
    fi
  fi

  _sync_emit_event "job_started" '{"job":"sync"}'

  # Resolve repo directory
  REPO_DIR="$(_find_repo)" || true
  if [[ -z "$REPO_DIR" ]]; then
    _sync_emit_event "error" '{"code":"managed_repo_missing","message":"Could not find dotfiles repo."}'
    _sync_emit_event "job_finished" '{"job":"sync","status":"failed"}'
    log_error "Could not find dotfiles repo. Are you inside it?"
    return 1
  fi
  _save_repo_cache

  if [[ "$SYNC_EVENTS" == "true" ]]; then
    _sync_log "Syncing repo: ${REPO_DIR}"
  else
    log_info "Syncing repo: ${REPO_DIR}"
  fi

  local manifest_file manifest_status
  manifest_file="$(_load_restore_manifest)" || manifest_status=$?
  manifest_status="${manifest_status:-0}"

  if [[ "$manifest_status" == "0" && -n "$manifest_file" ]]; then
    if [[ "$QUICK" == true ]]; then
      if [[ "$SYNC_EVENTS" == "true" ]]; then
        _sync_log "Quick mode: skipping full discovery drill-down."
      else
        log_info "Quick mode: skipping full discovery drill-down."
      fi
    else
      _sync_emit_event "step_started" '{"step":"discovery","label":"Scanning system"}'
      if type run_discovery >/dev/null 2>&1; then
        if run_discovery >&2; then
          _sync_emit_event "step_finished" '{"step":"discovery","status":"ok"}'
        else
          _sync_warning "discovery_failed" "Discovery returned errors; continuing." "{}"
          _sync_emit_event "step_finished" '{"step":"discovery","status":"warning"}'
        fi
      else
        _sync_warning "discovery_unavailable" "Discovery module not available. Using cached state." "{}"
        _sync_emit_event "step_finished" '{"step":"discovery","status":"warning"}'
      fi
    fi

    sync_manifest_owned_paths "$manifest_file"
    if [[ "$DRY_RUN" != true ]]; then
      if [[ "$SYNC_EVENTS" != "true" ]]; then
        show_diff_summary
      fi
      if [[ "$SYNC_EVENTS" == "true" ]]; then
        prompt_commit >&2
      else
        prompt_commit
      fi
    elif [[ "$SYNC_EVENTS" != "true" ]]; then
      show_diff_summary
    fi

    local final_status="ok"
    if [[ "$SYNC_WARNING_COUNT" -gt 0 ]]; then
      final_status="warning"
    fi
    _sync_emit_event "job_finished" "$(jq -cn --arg job "sync" --arg status "$final_status" --argjson counts "$(jq -cn --argjson drift "$SYNC_DRIFT_JSON" --argjson changes "$SYNC_CHANGE_COUNT" --argjson warnings "$SYNC_WARNING_COUNT" '{drift:($drift|length),changes:$changes,warnings:$warnings}')" '{job:$job,status:$status,counts:$counts}')"
    if [[ "$SYNC_EVENTS" != "true" ]]; then
      log_ok "Sync complete."
    fi
    return 0
  fi

  if [[ "$manifest_status" == "2" ]]; then
    _sync_emit_event "job_finished" '{"job":"sync","status":"failed"}'
    return 1
  fi

  _sync_warning "manifest_missing" "Generated repo has no restore manifest; legacy sync behavior applies." "{}"

  # 1. Re-run discovery (or use cached state with --quick)
  if [[ "$QUICK" == true ]]; then
    if [[ "$SYNC_EVENTS" == "true" ]]; then
      _sync_log "Quick mode: skipping full discovery drill-down."
    else
      log_info "Quick mode: skipping full discovery drill-down."
    fi
  else
    if [[ "$SYNC_EVENTS" == "true" ]]; then
      _sync_emit_event "step_started" '{"step":"discovery","label":"Scanning system"}'
    else
      log_step "Discovery"
    fi
    if type run_discovery >/dev/null 2>&1; then
      if run_discovery >&2; then
        _sync_emit_event "step_finished" '{"step":"discovery","status":"ok"}'
      else
        _sync_warning "discovery_failed" "Discovery returned errors; continuing." "{}"
        _sync_emit_event "step_finished" '{"step":"discovery","status":"warning"}'
      fi
    else
      _sync_warning "discovery_unavailable" "Discovery module not available. Using cached state." "{}"
      _sync_emit_event "step_finished" '{"step":"discovery","status":"warning"}'
    fi
  fi

  # 2. Config sync
  if [[ "$SYNC_EVENTS" == "true" ]]; then sync_configs >&2; else sync_configs; fi

  # 3. Brew sync
  if [[ "$SYNC_EVENTS" == "true" ]]; then sync_brewfile >&2; else sync_brewfile; fi

  # 4. npm sync
  if [[ "$SYNC_EVENTS" == "true" ]]; then sync_npm >&2; else sync_npm; fi

  # 5. Editor extension sync
  if [[ "$SYNC_EVENTS" == "true" ]]; then sync_editor_extensions >&2; else sync_editor_extensions; fi

  # 6. Agent sync
  if [[ "$SYNC_EVENTS" == "true" ]]; then sync_agents >&2; else sync_agents; fi

  # 7. Show diff summary
  if [[ "$SYNC_EVENTS" != "true" ]]; then show_diff_summary; fi

  # 8. Optional commit
  if [[ "$SYNC_EVENTS" == "true" ]]; then prompt_commit >&2; else prompt_commit; fi

  _sync_emit_event "job_finished" "$(jq -cn --arg job "sync" --arg status "warning" --argjson counts "$(jq -cn --argjson warnings "$SYNC_WARNING_COUNT" '{warnings:$warnings}')" '{job:$job,status:$status,counts:$counts}')"
  if [[ "$SYNC_EVENTS" == "true" ]]; then
    _sync_log "Sync complete."
  else
    log_ok "Sync complete."
  fi
}

# If sourced, do nothing. If executed directly, run cmd_sync.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd_sync "$@"
fi
