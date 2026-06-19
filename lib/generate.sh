#!/usr/bin/env bash
# dotfriend — Code generation: create dotfiles repo from selections
# shellcheck shell=bash

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# shellcheck source=gum.sh
source "$(dirname "${BASH_SOURCE[0]}")/gum.sh"

# shellcheck source=manifest.sh
source "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"

# shellcheck source=api.sh
source "$(dirname "${BASH_SOURCE[0]}")/api.sh"

# shellcheck source=agent-artifacts.sh
source "$(dirname "${BASH_SOURCE[0]}")/agent-artifacts.sh"

# shellcheck source=prune.sh
source "$(dirname "${BASH_SOURCE[0]}")/prune.sh"

# ─────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates"
SELECTIONS_FILE="${DOTFRIEND_CACHE_DIR}/selections.json"

# ─────────────────────────────────────────────────────────────
# State
# ─────────────────────────────────────────────────────────────

GEN_DIR=""
GEN_BACKUP_ROOT=""
GEN_DRY_RUN="false"
GEN_GITHUB_BACKED_UP="false"
GEN_GITHUB_URL=""
GEN_GITHUB_STATUS_MESSAGE=""
GEN_EVENTS="${DOTFRIEND_GENERATE_EVENTS:-false}"
GEN_EVENT_FD="${DOTFRIEND_GENERATE_EVENT_FD:-1}"
GEN_FORCE="${DOTFRIEND_GENERATE_FORCE:-false}"
GEN_NO_PUSH="${DOTFRIEND_GENERATE_NO_PUSH:-false}"

_generate_emit_event() {
  local event="$1" payload="${2:-}"
  [[ "$GEN_EVENTS" == "true" ]] || return 0
  [[ -n "$payload" ]] || payload="{}"
  api_event "$event" "$payload" >&"$GEN_EVENT_FD"
}

_generation_state_file() {
  printf '%s/.dotfriend/generation-state.json' "$GEN_DIR"
}

_generation_fingerprint_input_files() {
  printf '%s\n' "${SCRIPT_DIR}/generate.sh"
  if [[ -d "$TEMPLATES_DIR" ]]; then
    find "$TEMPLATES_DIR" -type f ! -name '*.bak' -print | sort
  fi
}

_generation_section_fingerprint() {
  local section="$1"
  if command -v shasum >/dev/null 2>&1; then
    {
      printf '%s\n' "fingerprint_version=2"
      printf '%s\n' "$section"
      if command -v jq >/dev/null 2>&1 && [[ -f "$SELECTIONS_FILE" ]]; then
        jq -S -c '.' "$SELECTIONS_FILE" 2>/dev/null || cat "$SELECTIONS_FILE"
      elif [[ -f "$SELECTIONS_FILE" ]]; then
        cat "$SELECTIONS_FILE"
      fi
      while IFS= read -r input_file; do
        [[ -f "$input_file" ]] || continue
        printf '%s\n' "input:${input_file}"
        shasum -a 256 "$input_file"
      done < <(_generation_fingerprint_input_files)
    } | shasum -a 256 | awk '{print $1}'
  else
    printf '%s:%s\n' "$section" "$(date +%s)"
  fi
}

_generation_section_is_current() {
  local section="$1" fingerprint="$2" state_file
  state_file="$(_generation_state_file)"
  [[ -f "$state_file" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e --arg section "$section" --arg fingerprint "$fingerprint" \
    '.sections[$section].fingerprint == $fingerprint' "$state_file" >/dev/null 2>&1
}

_generation_mark_section() {
  local section="$1" fingerprint="$2" state_file tmpfile
  command -v jq >/dev/null 2>&1 || return 0
  state_file="$(_generation_state_file)"
  ensure_dir "$(dirname "$state_file")"
  tmpfile="$(mktemp)"
  if [[ -f "$state_file" ]]; then
    jq --arg section "$section" \
      --arg fingerprint "$fingerprint" \
      --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '.schema_version = 1
       | .generated_by = "dotfriend"
       | .sections[$section] = {fingerprint:$fingerprint, generated_at:$generated_at}' \
      "$state_file" > "$tmpfile"
  else
    jq -n --arg section "$section" \
      --arg fingerprint "$fingerprint" \
      --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{schema_version:1,generated_by:"dotfriend",sections:{($section):{fingerprint:$fingerprint,generated_at:$generated_at}}}' \
      > "$tmpfile"
  fi
  mv "$tmpfile" "$state_file"
}

_generation_run_section() {
  local section="$1" label="$2"
  shift 2
  local fingerprint
  fingerprint="$(_generation_section_fingerprint "$section")"

  _generate_emit_event "step_started" "$(jq -cn --arg step "$section" --arg label "$label" '{step:$step,label:$label}')"
  if _generation_section_is_current "$section" "$fingerprint"; then
    log_info "Skipping ${label}; unchanged."
    _generate_emit_event "step_finished" "$(jq -cn --arg step "$section" --arg status "skipped" '{step:$step,status:$status}')"
    return 0
  fi

  "$@"
  _generation_mark_section "$section" "$fingerprint"
  _generate_emit_event "step_finished" "$(jq -cn --arg step "$section" --arg status "ok" '{step:$step,status:$status}')"
}

# ─────────────────────────────────────────────────────────────
# JSON reading (jq preferred, naive fallback)
# ─────────────────────────────────────────────────────────────

_jq_or_fallback() {
  local file="$1" query="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$query" "$file" 2>/dev/null || true
  else
    # Very naive fallback for simple array extraction
    grep -oP '"'"$query"'"\s*:\s*\[\K[^\]]*' "$file" 2>/dev/null || true
  fi
}

_jq_str() {
  local file="$1" query="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$query // empty" "$file" 2>/dev/null || true
  else
    true
  fi
}

_selected_repo_name() {
  local repo_name
  repo_name="$(_jq_str "$SELECTIONS_FILE" '.github.repo_name')"
  if [[ -z "$repo_name" || "$repo_name" == "null" ]]; then
    repo_name="dotfiles"
  fi
  printf '%s' "$repo_name"
}

_selected_agent_ids() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.agents[]? | .id' "$SELECTIONS_FILE" 2>/dev/null || true
  fi
}

_repo_path_for_dotfile() {
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

_copy_tree_filtered() {
  local src="$1" dest="$2"
  local filter_profile="${3:-config}"
  ensure_dir "$dest"

  if command -v rsync >/dev/null 2>&1; then
    local -a exclude_args=()
    local pattern
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] || continue
      exclude_args+=(--exclude "$pattern")
    done < <(dotfriend_prune_rsync_patterns "$filter_profile")

    rsync -a "${exclude_args[@]}" "$src/" "$dest/"
    return 0
  fi

  cp -a "$src/." "$dest/"
  dotfriend_remove_pruned_paths "$dest" "$filter_profile"
}

_sanitize_agent_file_copy() {
  local agent_id="$1" dest="$2"

  if [[ "$agent_id" != "claude" || "$(basename "$dest")" != "settings.json" ]]; then
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    local tmpfile
    tmpfile="$(mktemp)"
    if jq 'del(.hooks)' "$dest" > "$tmpfile" 2>/dev/null; then
      mv "$tmpfile" "$dest"
      log_info "Removed active Claude hooks from copied settings.json"
      return 0
    fi
    rm -f "$tmpfile"
  fi

  if command -v python3 >/dev/null 2>&1; then
    if python3 - "$dest" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

data.pop("hooks", None)

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
    then
      log_info "Removed active Claude hooks from copied settings.json"
      return 0
    fi
  fi

  log_warn "Could not sanitize copied Claude settings.json; hooks remain active in backup"
}

_print_command_failure_log() {
  local logfile="$1"
  [[ -s "$logfile" ]] || return 0

  while IFS= read -r line; do
    printf '   %s\n' "$line" >&2
  done < "$logfile"
}

_brew_entry_is_banned() {
  local kind="$1" item="$2"
  case "${kind}:${item}" in
    tap:jordond/tap|brew:jolt)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_npm_package_name_from_spec() {
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

_npm_package_spec_is_valid() {
  _npm_package_name_from_spec "$1" >/dev/null
}

_line_set_contains() {
  local lines="$1" needle="$2"
  printf '%s' "$lines" | grep -Fxq -- "$needle"
}

# ─────────────────────────────────────────────────────────────
# File generation helpers
# ─────────────────────────────────────────────────────────────

_generate_brewfile() {
  local out="${GEN_DIR}/Brewfile"
  log_info "Generating Brewfile..."

  {
    printf "# Brewfile — generated by dotfriend\\n"
    printf "# Edit with care.\\n\\n"

    # Taps
    local taps; taps="$(_jq_str "$SELECTIONS_FILE" '.taps | if . then join("\n") else "" end')"
    if [[ -n "$taps" ]]; then
      printf "# Taps\\n"
      local seen_taps=""
      while IFS= read -r tap; do
        [[ -z "$tap" ]] && continue
        _brew_entry_is_banned tap "$tap" && continue
        _line_set_contains "$seen_taps" "$tap" && continue
        seen_taps="${seen_taps}${tap}"$'\n'
        printf 'tap "%s"\n' "$tap"
      done <<< "$taps"
      printf "\\n"
    fi

    # Formulae
    local formulae; formulae="$(_jq_str "$SELECTIONS_FILE" '.formulae | if . then join("\n") else "" end')"
    if [[ -n "$formulae" ]]; then
      printf "# Formulae\\n"
      local seen_formulae=""
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        _brew_entry_is_banned brew "$f" && continue
        _line_set_contains "$seen_formulae" "$f" && continue
        seen_formulae="${seen_formulae}${f}"$'\n'
        printf 'brew "%s"\n' "$f"
      done <<< "$formulae"
      printf "\\n"
    fi

    # Casks (from apps)
    local apps_json; apps_json="$(_jq_str "$SELECTIONS_FILE" '.apps[]?')"
    if [[ -n "$apps_json" ]]; then
      printf "# Casks\\n"
      local seen_casks=""
      while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        # app format from wizard: "App Name|cask:token|cask" or "App Name|mas:token,id:123|mas"
        if [[ "$app" == *"|cask:"* ]]; then
          local cask; cask="${app#*|cask:}"
          cask="${cask%%|*}"
          [[ -z "$cask" ]] && continue
          _brew_entry_is_banned cask "$cask" && continue
          _line_set_contains "$seen_casks" "$cask" && continue
          seen_casks="${seen_casks}${cask}"$'\n'
          printf 'cask "%s"\n' "$cask"
        fi
      done <<< "$apps_json"
      printf "\\n"
    fi

    # MAS apps
    if [[ -n "$apps_json" ]]; then
      printf "# Mac App Store\\n"
      local seen_mas=""
      while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        if [[ "$app" == *"|mas:"* ]]; then
          local mas_part; mas_part="${app#*|mas:}"
          mas_part="${mas_part%%|*}"
          local mas_name mas_id
          mas_name="${mas_part%%,*}"
          mas_id="${mas_part##*id:}"
          [[ -z "$mas_name" || -z "$mas_id" ]] && continue
          _line_set_contains "$seen_mas" "$mas_id" && continue
          seen_mas="${seen_mas}${mas_id}"$'\n'
          printf 'mas "%s", id: %s\n' "$mas_name" "$mas_id"
        fi
      done <<< "$apps_json"
      printf "\\n"
    fi

    # npm globals (not in Brewfile, but note: we may want node in Brewfile)
    # We handle npm in install.sh, not Brewfile
  } > "$out"

  log_ok "Brewfile generated"
}

_generate_npm_globals_file() {
  local out="${GEN_DIR}/npm-global.txt"
  local npm; npm="$(_jq_str "$SELECTIONS_FILE" '.npm_globals | if . then join("\n") else "" end')"

  if [[ -z "$npm" ]]; then
    rm -f "$out"
    return 0
  fi

  log_info "Generating npm globals..."
  local seen_npm=""
  : > "$out"
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    if ! _npm_package_spec_is_valid "$pkg"; then
      log_warn "Skipping malformed npm package: $pkg"
      continue
    fi
    _line_set_contains "$seen_npm" "$pkg" && continue
    seen_npm="${seen_npm}${pkg}"$'\n'
    printf '%s\n' "$pkg" >> "$out"
  done <<< "$npm"

  if [[ ! -s "$out" ]]; then
    rm -f "$out"
  fi
  log_ok "npm globals generated"
}

_replace_placeholder() {
  local file="$1" placeholder="$2" content_file="$3"
  local temp; temp="$(mktemp)"
  awk -v ph="$placeholder" -v cf="$content_file" '
    index($0, ph) > 0 {
      while ((getline line < cf) > 0) {
        print line
      }
      close(cf)
      next
    }
    { print }
  ' "$file" > "$temp"
  mv "$temp" "$file"
}

_generate_install_sh() {
  local template="${TEMPLATES_DIR}/install.sh"
  local out="${GEN_DIR}/install.sh"
  log_info "Generating install.sh..."

  cp "$template" "$out"

  # Substitute basic placeholders
  sed -i.bak 's|{{INSTALL_MAS:-true}}|${INSTALL_MAS:-true}|g' "$out"
  sed -i.bak 's|{{BREW_UPGRADE:-true}}|${BREW_UPGRADE:-true}|g' "$out"
  sed -i.bak 's|{{INSTALL_DOTFRIEND:-true}}|${INSTALL_DOTFRIEND:-true}|g' "$out"
  sed -i.bak 's|{{INSTALL_VALIDATE:-false}}|${INSTALL_VALIDATE:-false}|g' "$out"
  sed -i.bak 's|{{DRY_RUN:-false}}|${DRY_RUN:-false}|g' "$out"
  rm -f "${out}.bak"

  # Build blocks into temp files and replace placeholders inline
  local tmpfile; tmpfile="$(mktemp)"

  _build_xcode_block > "$tmpfile"
  _replace_placeholder "$out" "{{XCODE_BLOCK}}" "$tmpfile"

  _build_symlinks_block > "$tmpfile"
  _replace_placeholder "$out" "{{SYMLINKS_BLOCK}}" "$tmpfile"

  _build_copies_block > "$tmpfile"
  _replace_placeholder "$out" "{{COPIES_BLOCK}}" "$tmpfile"

  _build_agent_rsync_block > "$tmpfile"
  _replace_placeholder "$out" "{{AGENT_RSYNC_BLOCK}}" "$tmpfile"

  _build_npm_block > "$tmpfile"
  _replace_placeholder "$out" "{{NPM_BLOCK}}" "$tmpfile"

  _build_vscode_block > "$tmpfile"
  _replace_placeholder "$out" "{{VSCODE_BLOCK}}" "$tmpfile"

  _build_cursor_block > "$tmpfile"
  _replace_placeholder "$out" "{{CURSOR_BLOCK}}" "$tmpfile"

  _build_dock_block > "$tmpfile"
  _replace_placeholder "$out" "{{DOCK_BLOCK}}" "$tmpfile"

  _build_macos_defaults_block > "$tmpfile"
  _replace_placeholder "$out" "{{MACOS_DEFAULTS_BLOCK}}" "$tmpfile"

  _build_duti_block > "$tmpfile"
  _replace_placeholder "$out" "{{DUTI_BLOCK}}" "$tmpfile"

  _build_telemetry_block > "$tmpfile"
  _replace_placeholder "$out" "{{TELEMETRY_BLOCK}}" "$tmpfile"

  rm -f "$tmpfile"

  chmod +x "$out"
  log_ok "install.sh generated"
}

_generate_bootstrap_sh() {
  local template="${TEMPLATES_DIR}/bootstrap.sh"
  local out="${GEN_DIR}/bootstrap.sh"
  log_info "Generating bootstrap.sh..."

  cp "$template" "$out"

  local repo_name; repo_name="$(_selected_repo_name)"
  local repo_url="https://github.com/$(gh api user -q '.login' 2>/dev/null || echo 'YOUR_USERNAME')/${repo_name}.git"

  sed -i.bak "s|{{REPO_URL}}|${repo_url}|g" "$out"
  sed -i.bak "s|{{DOTFILES_DIR}}|\${HOME}/${repo_name}|g" "$out"
  sed -i.bak "s|{{RUN_DOTFILES_INSTALL:-true}}|true|g" "$out"
  rm -f "${out}.bak"

  chmod +x "$out"
  log_ok "bootstrap.sh generated"
}

_generate_gitignore() {
  local out="${GEN_DIR}/.gitignore"
  log_info "Generating .gitignore..."
  cat > "$out" <<'GITIGNORE_EOF'
### Secrets and keys ###
secrets/
secrets/*.key
secrets/*.pem
secrets/*.p12
secrets/*.enc
*.env
.env.*
.ssh/id_*
.ssh/*_rsa
.ssh/*_ed25519
.config/sops/

### Caches ###
__pycache__/
*.pyc
*.pyo
*.egg-info/
.pytest_cache/
.mypy_cache/
.ruff_cache/
.tox/
*.cache
.cache/
cache/
Caches/
node_modules/
bower_components/
jspm_packages/
vendor/
Pods/
.gradle/
.npm/
.pnpm-store/
.yarn/
.venv/
venv/
virtenv/
virtualenv/
gcloud/
.gcloud/
.next/cache/
.turbo/
.parcel-cache/
.vite/
.nuxt/
.svelte-kit/
.astro/
marketplace/
marketplaces/
plugin-marketplace/
plugin-marketplaces/
generated/
.generated/
generated_images/
sqlite/

### OS files ###
.DS_Store
.AppleDouble
.LSOverride
Thumbs.db

### Editor files ###
.vscode/
.idea/
*.swp
*.swo
*~

### Logs ###
*.log
logs/
log/

### Temporary files ###
tmp/
temp/
*.tmp
*.bak
*.backup

### Build artifacts ###
dist/
build/
.next/
out/
target/
GITIGNORE_EOF
  log_ok ".gitignore generated"
}

_generate_locations_md() {
  local out="${GEN_DIR}/locations.md"
  log_info "Generating locations.md..."

  {
    printf "# Config Location Reference\\n\\n"
    printf "Auto-generated by dotfriend.\\n\\n"
    printf "## Agent Tools\\n\\n"
    local agents; agents="$(_jq_str "$SELECTIONS_FILE" '.agents | if . then join("\n") else "" end')"
    if [[ -n "$agents" ]]; then
      while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue
        local agent_id; agent_id="${agent%%|*}"
        printf -- "- **%s**: see agent-tools.json for canonical paths\\n" "$agent_id"
      done <<< "$agents"
    fi
    printf "\\n## Dotfiles\\n\\n"
    local dotfiles; dotfiles="$(_jq_str "$SELECTIONS_FILE" '.dotfiles | if . then join("\n") else "" end')"
    if [[ -n "$dotfiles" ]]; then
      while IFS= read -r df; do
        [[ -z "$df" ]] && continue
        printf -- "- \`~/%s\` → symlinked to repo\\n" "$df"
      done <<< "$dotfiles"
    fi
  } > "$out"

  log_ok "locations.md generated"
}

_generate_repo_metadata() {
  local metadata_dir="${GEN_DIR}/.dotfriend"
  log_info "Generating repo metadata..."

  ensure_dir "$metadata_dir"
  cp "${SCRIPT_DIR}/agent-tools.json" "${metadata_dir}/agent-tools.json"
  if command -v jq >/dev/null 2>&1; then
    jq '
      def uniq_order: reduce .[] as $x ([]; if index($x) then . else . + [$x] end);
      .taps = ((.taps // []) | map(select(. != "jordond/tap")) | uniq_order)
      | .formulae = ((.formulae // []) | map(select(. != "jolt")) | uniq_order)
      | .npm_globals = ((.npm_globals // []) | uniq_order)
    ' "$SELECTIONS_FILE" > "${metadata_dir}/selections.json"
  else
    cp "$SELECTIONS_FILE" "${metadata_dir}/selections.json"
  fi

  log_ok "Repo metadata generated"
}

_generate_restore_manifest() {
  log_info "Generating restore manifest..."
  manifest_write_for_generated_repo "$GEN_DIR" "$SELECTIONS_FILE" "${SCRIPT_DIR}/agent-tools.json"
  log_ok "Restore manifest generated"
}

_generate_macos_defaults() {
  if ! command -v jq >/dev/null 2>&1; then
    log_warn "jq is required to generate Mac settings"
    return 0
  fi

  local selected_count out tmpfile catalog_version
  selected_count="$(jq -r '(.macos_defaults // []) | length' "$SELECTIONS_FILE" 2>/dev/null || printf '0')"
  out="${GEN_DIR}/macos/defaults.json"

  if [[ "$selected_count" == "0" ]]; then
    rm -f "$out"
    return 0
  fi

  log_info "Generating Mac settings..."
  ensure_dir "$(dirname "$out")"
  tmpfile="$(mktemp)"
  catalog_version=""
  if [[ -f "${SCRIPT_DIR}/macos-defaults.json" ]]; then
    catalog_version="$(jq -r '.catalog_version // ""' "${SCRIPT_DIR}/macos-defaults.json" 2>/dev/null || true)"
  fi

  jq -n \
    --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg catalog_version "$catalog_version" \
    --slurpfile selections_file "$SELECTIONS_FILE" \
    '
    ($selections_file[0].macos_defaults // []) as $entries |
    {
      schema_version: 1,
      generated_by: "dotfriend",
      generated_at: $generated_at,
      catalog_version: $catalog_version,
      entries: $entries
    }' > "$tmpfile"

  mv "$tmpfile" "$out"
  log_ok "Mac settings generated"
}

_generate_agent_artifacts_manifest() {
  log_info "Generating agent artifact manifest..."
  agent_artifacts_write_for_generated_repo "$GEN_DIR" "$SELECTIONS_FILE" "${SCRIPT_DIR}/agent-tools.json"
  log_ok "Agent artifact manifest generated"
}

_generate_dotfriend_readme_md() {
  local out="${GEN_DIR}/.dotfriend/README.md"
  log_info "Generating .dotfriend/README.md..."

  cat > "$out" <<'EOF'
# dotfriend metadata

This directory is generated by dotfriend and describes what the repo owns.

- `restore-manifest.json` is the restore and sync contract for files, directories, packages, and selected app state.
- `agent-artifacts.json` is the agent configuration contract for managed MCPs, instructions, rules, skills, and shared stores.
- `selections.json` is the captured wizard choice set used to generate this repo.
- `agent-tools.json` records canonical agent config locations.

When selected Mac settings are present, `../macos/defaults.json` contains the reviewed values that install and sync are allowed to manage.

dotfriend preserves personal config outside managed entries. Managed JSON entries carry `_managed_by: "dotfriend"` and `_dotfriend_artifact_id`. Managed Markdown uses `<!-- dotfriend:start id="..." -->` / `<!-- dotfriend:end id="..." -->` blocks. Whole-file overwrite is only allowed when an item explicitly declares `ownership: "dotfriend_full_file"`.

Useful checks:

```bash
dotfriend status --json
dotfriend plan --json
dotfriend agent status --json
dotfriend agent check --json
dotfriend agent sync --dry-run --json
./scripts/validate.sh --all
```
EOF

  log_ok ".dotfriend/README.md generated"
}

_generate_readme_md() {
  local out="${GEN_DIR}/README.md"
  local repo_name
  repo_name="$(_selected_repo_name)"

  log_info "Generating README.md..."

  {
    printf "# %s\n\n" "$repo_name"
    printf '%s\n\n' "Generated by dotfriend. This repo is meant to be both your restore source on a new Mac and your day-to-day backup target on your current machine."
    printf '%s\n\n' "## New Machine Setup"
    printf '%s\n\n' "If this repo is already cloned locally, run:"
    printf '```bash\n'
    printf './install.sh\n'
    printf '```\n\n'
    printf '%s\n\n' "For a safer preview first:"
    printf '```bash\n'
    printf 'DRY_RUN=true ./install.sh\n'
    printf '```\n\n'
    printf '%s\n\n' "Run validation after install if you want a quick sanity check:"
    printf '```bash\n'
    printf './scripts/validate.sh --all\n'
    printf '```\n\n'
    printf '%s\n\n' '`install.sh` also installs the `dotfriend` CLI when needed and registers this clone as the repo that `dotfriend sync` should maintain.'
    printf '%s\n\n' '`bootstrap.sh` is the first-run helper for a brand-new Mac when you want Homebrew/Xcode setup and repo cloning handled before `install.sh` runs.'
    printf '%s\n\n' "## Sync Back Into This Repo"
    printf '%s\n\n' "Use dotfriend as the normal orchestrator for ongoing sync:"
    printf '```bash\n'
    printf 'dotfriend sync\n'
    printf '```\n\n'
    printf '%s\n\n' "If dotfriend is unavailable, this repo also includes a portable fallback sync script. Preview changes from your current machine:"
    printf '```bash\n'
    printf './scripts/backup.sh --dry-run\n'
    printf '```\n\n'
    printf '%s\n\n' "Sync and auto-commit tracked changes locally:"
    printf '```bash\n'
    printf './scripts/backup.sh --commit\n'
    printf '```\n\n'
    printf '%s\n\n' "These sync flows update the generated repo content that dotfriend tracks, including your Brewfile, npm globals, tracked dotfiles/configs, selected Mac settings, selected agent configs, and VS Code/Cursor extension ID lists."
    printf '%s\n\n' "## What Gets Restored"
    printf '%s\n' '- Homebrew taps, formulae, casks, and Mac App Store apps from `Brewfile`'
    printf '%s\n' '- Global npm packages from `npm-global.txt`'
    printf '%s\n' '- Tracked shell dotfiles and app config directories'
    printf '%s\n' '- Selected Mac settings from `macos/defaults.json`'
    printf '%s\n' '- Selected agent config files and managed subdirectories'
    printf '%s\n\n' '- VS Code and Cursor extensions from `vscode/extensions.txt` and `cursor/extensions.txt`'
    printf '%s\n\n' 'Only Mac settings selected during review are included. `install.sh` applies them through `scripts/apply-macos-defaults.sh`; use `DRY_RUN=true ./install.sh` for a preview.'
    printf '%s\n\n' "## dotfriend Metadata"
    printf '%s\n\n' '`.dotfriend/restore-manifest.json` describes every path dotfriend may restore or sync. It uses relative repo paths and approved target paths so backend callers can inspect changes before writes.'
    printf '%s\n\n' '`.dotfriend/agent-artifacts.json` describes managed agent config artifacts such as MCP entries, instructions, skills, rules, and shared stores.'
    printf '%s\n\n' '`.dotfriend/selections.json` records the choices used to generate this repo.'
    printf '%s\n\n' 'dotfriend owns generated files and marked managed entries only. Personal JSON entries are preserved unless they carry `_managed_by: "dotfriend"` for the same artifact. Markdown outside dotfriend block markers is preserved. Whole-file overwrite requires explicit `ownership: "dotfriend_full_file"` in the manifest or artifact.'
    printf '%s\n\n' "## Backend-safe Checks"
    printf '```bash\n'
    printf 'dotfriend status --json\n'
    printf 'dotfriend plan --json\n'
    printf 'dotfriend sync --dry-run --quick --events\n'
    printf 'dotfriend agent status --json\n'
    printf 'dotfriend agent check --json\n'
    printf 'dotfriend agent sync --dry-run --json\n'
    printf './scripts/validate.sh --all\n'
    printf '```\n\n'
    printf '%s\n\n' "## Useful Commands"
    printf '```bash\n'
    printf './install.sh\n'
    printf 'DRY_RUN=true ./install.sh\n'
    printf 'dotfriend sync\n'
    printf './scripts/backup.sh --dry-run\n'
    printf './scripts/backup.sh --commit\n'
    printf './scripts/validate.sh --all\n'
    printf '```\n'
  } > "$out"

  log_ok "README.md generated"
}

# ─────────────────────────────────────────────────────────────
# Block builders (output bash code that gets appended to install.sh)
# ─────────────────────────────────────────────────────────────

_build_xcode_block() {
  local xcode; xcode="$(_jq_str "$SELECTIONS_FILE" '.xcode // false')"
  if [[ "$xcode" == "true" ]]; then
    printf "  if xcode-select -p >/dev/null 2>&1; then\n"
    printf "    log_ok \"Xcode CLI tools already installed\"\n"
    printf "  else\n"
    printf '    if [[ "$DRY_RUN" == "true" ]]; then\n'
    printf '      log_info "[dry-run] Would install Xcode CLI tools"\n'
    printf '    else\n'
    printf '      log_info "Installing Xcode Command Line Tools..."\n'
    printf '      xcode-select --install 2>/dev/null || true\n'
    printf '      until xcode-select -p >/dev/null 2>&1; do sleep 5; done\n'
    printf '      log_ok "Xcode CLI tools installed"\n'
    printf '    fi\n'
    printf '  fi\n'
  else
    printf "  # Xcode CLI tools skipped by user\n"
  fi
}

_build_symlinks_block() {
  local dotfiles; dotfiles="$(_jq_str "$SELECTIONS_FILE" '.dotfiles | if . then join("\n") else "" end')"
  printf "\n  # Dotfile symlinks\n"
  if [[ -n "$dotfiles" ]]; then
    while IFS= read -r df; do
      [[ -z "$df" ]] && continue
      local repo_path; repo_path="$(_repo_path_for_dotfile "$df")"
      printf '  _symlink "$DOTFILES_DIR/%s" "$HOME/%s"\n' "$repo_path" "$df"
    done <<< "$dotfiles"
  fi
}

_build_copies_block() {
  printf "\n  # App-managed files (copied, not symlinked)\n"
  local configs; configs="$(_jq_str "$SELECTIONS_FILE" '.config_dirs | if . then join("\n") else "" end')"
  if [[ -n "$configs" ]]; then
    while IFS= read -r cfg; do
      [[ -z "$cfg" ]] && continue
      printf '  _copy "$DOTFILES_DIR/config/%s" "$HOME/.config/%s"\n' "$cfg" "$cfg"
    done <<< "$configs"
  fi
  if [[ -d "${HOME}/Library/Preferences/com.choosyosx.Choosy.plist" ]]; then
    printf "  # Choosy preferences are plist-managed; skipping symlink\n"
  fi
}

_build_agent_rsync_block() {
  printf "\n  # Agent config restore\n"
  while IFS= read -r agent_id; do
    [[ -z "$agent_id" ]] && continue
    local canonical_dir
    canonical_dir="$(jq -r --arg id "$agent_id" '.agentic_tools[] | select(.id == $id) | .canonical_dir' "${SCRIPT_DIR}/agent-tools.json" 2>/dev/null || true)"
    if [[ -n "$canonical_dir" && "$canonical_dir" != "null" ]]; then
      local runtime_dir
      runtime_dir="${canonical_dir/#\~/\$HOME}"

      local important_files important_dirs
      important_files="$(jq -r --arg id "$agent_id" '.agentic_tools[] | select(.id == $id) | .important_files // [] | .[]' "${SCRIPT_DIR}/agent-tools.json" 2>/dev/null || true)"
      important_dirs="$(jq -r --arg id "$agent_id" '.agentic_tools[] | select(.id == $id) | .important_dirs // [] | .[]' "${SCRIPT_DIR}/agent-tools.json" 2>/dev/null || true)"

      while IFS= read -r file_path; do
        [[ -z "$file_path" ]] && continue
        printf '  if [[ -e "$DOTFILES_DIR/%s/%s" ]]; then\n' "$agent_id" "$file_path"
        printf '    _copy "$DOTFILES_DIR/%s/%s" "%s/%s"\n' "$agent_id" "$file_path" "$runtime_dir" "$file_path"
        printf "  fi\n"
      done <<< "$important_files"

      while IFS= read -r dir_path; do
        [[ -z "$dir_path" ]] && continue
        printf '  if [[ -d "$DOTFILES_DIR/%s/%s" ]]; then\n' "$agent_id" "$dir_path"
        printf '    _rsync_agent "$DOTFILES_DIR/%s/%s" "%s/%s"\n' "$agent_id" "$dir_path" "$runtime_dir" "$dir_path"
        printf "  fi\n"
      done <<< "$important_dirs"
    fi
  done < <(_selected_agent_ids)

  if [[ -d "${GEN_DIR}/agents/skills" ]]; then
    printf '  _rsync_agent "$DOTFILES_DIR/agents/skills" "$HOME/.agents/skills"\n'
  fi
  if [[ -d "${GEN_DIR}/agents/agent-docs" ]]; then
    printf '  _rsync_agent "$DOTFILES_DIR/agents/agent-docs" "$HOME/.agents/agent-docs"\n'
  fi
}

_build_npm_block() {
  local npm; npm="$(_jq_str "$SELECTIONS_FILE" '.npm_globals | if . then join("\n") else "" end')"
  printf "\n  # npm global packages\n"
  if [[ -n "$npm" ]]; then
    printf '  ensure_brew_package npm node "npm global packages"\n'
    printf '  if [[ "$DRY_RUN" == "true" || "$(command -v npm || true)" != "" ]]; then\n'
    local seen_npm=""
    while IFS= read -r pkg; do
      [[ -z "$pkg" ]] && continue
      if ! _npm_package_spec_is_valid "$pkg"; then
        continue
      fi
      _line_set_contains "$seen_npm" "$pkg" && continue
      seen_npm="${seen_npm}${pkg}"$'\n'
      printf "    soft_run npm install -g %s || true\n" "$pkg"
    done <<< "$npm"
    printf "  else\n"
    printf "    log_warn \"npm not found; skipping npm global installs\"\n"
    printf "  fi\n"
  fi
}

_build_vscode_block() {
  local editors; editors="$(_jq_str "$SELECTIONS_FILE" '.editors')"
  if [[ -n "$editors" ]] && command -v jq >/dev/null 2>&1; then
    local vscode; vscode="$(jq -r '.vscode // false' <<< "$editors" 2>/dev/null || true)"
    if [[ "$vscode" == "true" ]]; then
      printf "\n  # VS Code extensions\n"
      printf '  if command -v code >/dev/null 2>&1 && [[ -f "$DOTFILES_DIR/vscode/extensions.txt" ]]; then\n'
      printf "    while IFS= read -r ext; do\n"
      printf '      [[ -z "$ext" ]] && continue\n'
      printf '      soft_run code --install-extension "$ext" || true\n'
      printf '    done < "$DOTFILES_DIR/vscode/extensions.txt"\n'
      printf "  fi\n"
    fi
  fi
}

_build_cursor_block() {
  local editors; editors="$(_jq_str "$SELECTIONS_FILE" '.editors')"
  if [[ -n "$editors" ]] && command -v jq >/dev/null 2>&1; then
    local cursor; cursor="$(jq -r '.cursor // false' <<< "$editors" 2>/dev/null || true)"
    if [[ "$cursor" == "true" ]]; then
      printf "\n  # Cursor extensions\n"
      printf '  if command -v cursor >/dev/null 2>&1 && [[ -f "$DOTFILES_DIR/cursor/extensions.txt" ]]; then\n'
      printf "    while IFS= read -r ext; do\n"
      printf '      [[ -z "$ext" ]] && continue\n'
      printf '      soft_run cursor --install-extension "$ext" || true\n'
      printf '    done < "$DOTFILES_DIR/cursor/extensions.txt"\n'
      printf "  fi\n"
    fi
  fi
}

_build_dock_block() {
  local dock; dock="$(_jq_str "$SELECTIONS_FILE" '.dock')"
  printf "\n  # Dock restore\n"
  if [[ -n "$dock" ]] && command -v jq >/dev/null 2>&1; then
    local backup; backup="$(jq -r '.backup // false' <<< "$dock" 2>/dev/null || true)"
    if [[ "$backup" == "true" ]]; then
      printf '  if [[ -f "$DOTFILES_DIR/dock/dock-apps.txt" ]]; then\n'
      printf '    ensure_brew_package dockutil dockutil "Dock restore"\n'
      printf '    if [[ "$DRY_RUN" == "true" || "$(command -v dockutil || true)" != "" ]]; then\n'
      printf "      log_info \"Restoring Dock layout...\"\n"
      printf "      # Clear existing dock\n"
      printf "      soft_run dockutil --remove all --no-restart || true\n"
      printf "      while IFS= read -r app; do\n"
      printf '        [[ -z "$app" ]] && continue\n'
      printf '        soft_run dockutil --add "$app" --no-restart || true\n'
      printf '      done < "$DOTFILES_DIR/dock/dock-apps.txt"\n'
      printf "      killall Dock 2>/dev/null || true\n"
      printf "    else\n"
      printf "      log_warn \"dockutil not available; skipping dock restore\"\n"
      printf "    fi\n"
      printf "  else\n"
      printf "    log_info \"No Dock layout found; skipping Dock restore\"\n"
      printf "  fi\n"
    fi
  fi
}

_build_macos_defaults_block() {
  local count
  count="$(_jq_str "$SELECTIONS_FILE" '(.macos_defaults // []) | length')"
  printf "\n  # Mac settings\n"
  if [[ "${count:-0}" != "0" ]]; then
    printf '  if [[ -x "$DOTFILES_DIR/scripts/apply-macos-defaults.sh" && -f "$DOTFILES_DIR/macos/defaults.json" ]]; then\n'
    printf '    soft_run "$DOTFILES_DIR/scripts/apply-macos-defaults.sh" || true\n'
    printf '  fi\n'
  else
    printf '  # Mac settings skipped by user\n'
  fi
}

_build_duti_block() {
  local dock; dock="$(_jq_str "$SELECTIONS_FILE" '.dock')"
  printf "\n  # Default app associations\n"
  if [[ -n "$dock" ]] && command -v jq >/dev/null 2>&1; then
    local defaults; defaults="$(jq -r '.defaults // false' <<< "$dock" 2>/dev/null || true)"
    if [[ "$defaults" == "true" ]]; then
      printf "  if command -v duti >/dev/null 2>&1; then\n"
      printf "    log_info \"Setting default app associations...\"\n"
      printf "    # Add duti rules here as needed\n"
      printf "    # soft_run duti -s com.choosyosx.Choosy http all || true\n"
      printf "  else\n"
      printf "    log_warn \"duti not available; skipping default app associations\"\n"
      printf "  fi\n"
    fi
  fi
}

_build_telemetry_block() {
  local telemetry; telemetry="$(_jq_str "$SELECTIONS_FILE" '.telemetry // false')"
  printf "\n  # Telemetry disabling\n"
  if [[ "$telemetry" == "true" ]]; then
    printf '  if [[ "$DRY_RUN" == "true" ]]; then\n'
    printf '    log_info "[dry-run] Would disable telemetry"\n'
    printf '  else\n'
    printf '    log_info "Disabling telemetry..."\n'
    printf '    brew analytics off 2>/dev/null || true\n'
    printf '    go telemetry off 2>/dev/null || true\n'
    printf '    gh telemetry off 2>/dev/null || true\n'
    printf '    npm config set update-notifier false 2>/dev/null || true\n'
    printf '    # Bun telemetry\n'
    printf '    if [[ -f "%s/.bunfig.toml" ]]; then\n' "$HOME"
    printf '      grep -q telemetry "%s/.bunfig.toml" || printf "\\n[install]\\ntelemetry = false\\n" >> "%s/.bunfig.toml"\n' "$HOME" "$HOME"
    printf '    fi\n'
    printf '  fi\n'
  fi
}

# ─────────────────────────────────────────────────────────────
# Config copying
# ─────────────────────────────────────────────────────────────

_copy_configs() {
  local dotfiles; dotfiles="$(_jq_str "$SELECTIONS_FILE" '.dotfiles | if . then join("\n") else "" end')"
  if [[ -n "$dotfiles" ]]; then
    log_info "Copying dotfiles..."
    while IFS= read -r df; do
      [[ -z "$df" ]] && continue
      local src="${HOME}/${df}"
      local dest="${GEN_DIR}/$(_repo_path_for_dotfile "$df")"
      if [[ -f "$src" ]]; then
        ensure_dir "$(dirname "$dest")"
        cp "$src" "$dest"
        log_ok "Copied ~/${df}"
      fi
    done <<< "$dotfiles"
  fi

  # ~/.config directories
  local configs; configs="$(_jq_str "$SELECTIONS_FILE" '.config_dirs | if . then join("\n") else "" end')"
  if [[ -n "$configs" ]]; then
    log_info "Copying config directories..."
    while IFS= read -r cfg; do
      [[ -z "$cfg" ]] && continue
      local src="${HOME}/.config/${cfg}"
      local dest="${GEN_DIR}/config/${cfg}"
      if [[ -d "$src" ]]; then
        _copy_tree_filtered "$src" "$dest"
        log_ok "Copied ~/.config/${cfg}"
      fi
    done <<< "$configs"
  fi
}

_copy_editor_configs() {
  local editors; editors="$(_jq_str "$SELECTIONS_FILE" '.editors')"
  if [[ -z "$editors" ]]; then
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    local vscode; vscode="$(jq -r '.vscode // false' <<< "$editors" 2>/dev/null || true)"
    if [[ "$vscode" == "true" ]]; then
      log_info "Copying VS Code settings..."
      local vscode_dir="${HOME}/Library/Application Support/Code/User"
      local dest="${GEN_DIR}/vscode"
      ensure_dir "$dest"
      if [[ -f "${vscode_dir}/settings.json" ]]; then
        cp "${vscode_dir}/settings.json" "${dest}/settings.json"
      fi
      if [[ -f "${vscode_dir}/keybindings.json" ]]; then
        cp "${vscode_dir}/keybindings.json" "${dest}/keybindings.json"
      fi
      local vscode_extensions
      vscode_extensions="$(dotfriend_cached_editor_extensions vscode || true)"
      if [[ -n "$vscode_extensions" ]]; then
        printf '%s\n' "$vscode_extensions" | sort -u > "${dest}/extensions.txt"
      elif command -v code >/dev/null 2>&1; then
        dotfriend_run_optional_command code --list-extensions | sort -u > "${dest}/extensions.txt" || true
      fi
      log_ok "VS Code settings backed up"
    fi

    local cursor; cursor="$(jq -r '.cursor // false' <<< "$editors" 2>/dev/null || true)"
    if [[ "$cursor" == "true" ]]; then
      log_info "Copying Cursor settings..."
      local cursor_dir="${HOME}/Library/Application Support/Cursor/User"
      local dest="${GEN_DIR}/cursor"
      ensure_dir "$dest"
      if [[ -f "${cursor_dir}/settings.json" ]]; then
        cp "${cursor_dir}/settings.json" "${dest}/settings.json"
      fi
      if [[ -f "${cursor_dir}/keybindings.json" ]]; then
        cp "${cursor_dir}/keybindings.json" "${dest}/keybindings.json"
      fi
      local cursor_extensions
      cursor_extensions="$(dotfriend_cached_editor_extensions cursor || true)"
      if [[ -n "$cursor_extensions" ]]; then
        printf '%s\n' "$cursor_extensions" | sort -u > "${dest}/extensions.txt"
      elif command -v cursor >/dev/null 2>&1; then
        dotfriend_run_optional_command cursor --list-extensions | sort -u > "${dest}/extensions.txt" || true
      fi
      log_ok "Cursor settings backed up"
    fi
  fi
}

_copy_agent_configs() {
  log_info "Copying agent tool configs..."
  while IFS= read -r agent_id; do
    [[ -z "$agent_id" ]] && continue

    # Look up canonical dir in agent-tools.json
    local canonical_dir
    canonical_dir="$(jq -r --arg id "$agent_id" '.agentic_tools[] | select(.id == $id) | .canonical_dir' "${SCRIPT_DIR}/agent-tools.json" 2>/dev/null || true)"
    if [[ -z "$canonical_dir" || "$canonical_dir" == "null" ]]; then
      log_warn "Unknown agent: $agent_id"
      continue
    fi

    canonical_dir="${canonical_dir/#\~/${HOME}}"
    if [[ ! -d "$canonical_dir" ]]; then
      log_warn "Agent dir not found: $canonical_dir"
      continue
    fi

    local dest="${GEN_DIR}/${agent_id}"
    ensure_dir "$dest"

    # Read important files and dirs
    local important_files important_dirs
    important_files="$(jq -r --arg id "$agent_id" '.agentic_tools[] | select(.id == $id) | .important_files // [] | .[]' "${SCRIPT_DIR}/agent-tools.json" 2>/dev/null || true)"
    important_dirs="$(jq -r --arg id "$agent_id" '.agentic_tools[] | select(.id == $id) | .important_dirs // [] | .[]' "${SCRIPT_DIR}/agent-tools.json" 2>/dev/null || true)"

    # Copy files
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local src="${canonical_dir}/${f}"
      if [[ -e "$src" && ! -L "$src" ]]; then
        cp -a "$src" "${dest}/"
        _sanitize_agent_file_copy "$agent_id" "${dest}/$(basename "$f")"
        log_ok "Copied ${f} for ${agent_id}"
      elif [[ -L "$src" ]]; then
        log_info "Skipping symlink: ${src}"
      fi
    done <<< "$important_files"

    # Copy dirs
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      local src="${canonical_dir}/${d}"
      if [[ -d "$src" && ! -L "$src" ]]; then
        _copy_tree_filtered "$src" "${dest}/${d}" "agent"
        log_ok "Copied ${d}/ for ${agent_id}"
      elif [[ -L "$src" ]]; then
        log_info "Skipping symlinked dir: ${src}"
      fi
    done <<< "$important_dirs"
  done < <(_selected_agent_ids)

  if [[ -d "${HOME}/.agents/skills" ]]; then
    _copy_tree_filtered "${HOME}/.agents/skills" "${GEN_DIR}/agents/skills" "agent"
    log_ok "Copied ~/.agents/skills"
  fi
  if [[ -d "${HOME}/.agents/agent-docs" ]]; then
    _copy_tree_filtered "${HOME}/.agents/agent-docs" "${GEN_DIR}/agents/agent-docs" "agent"
    log_ok "Copied ~/.agents/agent-docs"
  fi
}

_copy_dock() {
  local dock; dock="$(_jq_str "$SELECTIONS_FILE" '.dock')"
  if [[ -z "$dock" ]]; then
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    local backup; backup="$(jq -r '.backup // false' <<< "$dock" 2>/dev/null || true)"
    if [[ "$backup" == "true" ]]; then
      log_info "Backing up Dock layout..."
      local dest="${GEN_DIR}/dock"
      ensure_dir "$dest"
      if command -v dockutil >/dev/null 2>&1; then
        dockutil --list > "${dest}/dock-apps.txt" 2>/dev/null || true
        log_ok "Dock layout saved"
      else
        log_warn "dockutil not installed; skipping dock backup"
      fi
    fi
  fi
}

# ─────────────────────────────────────────────────────────────
# Scripts copying
# ─────────────────────────────────────────────────────────────

_copy_scripts() {
  log_info "Copying scripts..."
  local src_dir="${TEMPLATES_DIR}/scripts"
  local dest_dir="${GEN_DIR}/scripts"
  ensure_dir "$dest_dir"

  if [[ -d "$src_dir" ]]; then
    cp -a "${src_dir}/"* "$dest_dir/" 2>/dev/null || true
  fi

  # Also ensure lib dir exists
  ensure_dir "${dest_dir}/lib"

  chmod -R +x "${dest_dir}"/*.sh 2>/dev/null || true
  log_ok "Scripts copied"
}

# ─────────────────────────────────────────────────────────────
# Git operations
# ─────────────────────────────────────────────────────────────

_init_git() {
  log_info "Initializing git repository..."
  if [[ -d "${GEN_DIR}/.git" ]]; then
    log_warn "Local git repo already exists at ${GEN_DIR}"
    return 0
  fi

  local git_log
  git_log="$(mktemp)"

  if ! (
    cd "$GEN_DIR"
    git init
    git add .
    git commit -m "Initial dotfiles — generated by dotfriend"
  ) >"$git_log" 2>&1; then
    log_error "Could not initialize the local git repository"
    _print_command_failure_log "$git_log"
    rm -f "$git_log"
    return 1
  fi

  rm -f "$git_log"
  log_ok "Git repo initialized"
}

# ─────────────────────────────────────────────────────────────
# GitHub push
# ─────────────────────────────────────────────────────────────

_github_push() {
  local repo_name; repo_name="$(_selected_repo_name)"
  GEN_GITHUB_BACKED_UP="false"
  GEN_GITHUB_URL=""
  GEN_GITHUB_STATUS_MESSAGE=""
  if [[ "$GEN_NO_PUSH" == "true" ]]; then
    GEN_GITHUB_STATUS_MESSAGE="GitHub backup was skipped because --no-push was set."
    log_info "--no-push set; skipping GitHub push"
    return 0
  fi
  if [[ -z "$repo_name" || "$repo_name" == "null" ]]; then
    GEN_GITHUB_STATUS_MESSAGE="GitHub backup was skipped because no repository name was configured."
    log_info "No GitHub repo configured; skipping push"
    return 0
  fi

  log_step "GitHub Backup"

  if ! command -v gh >/dev/null 2>&1; then
    GEN_GITHUB_STATUS_MESSAGE="GitHub backup was skipped because the gh CLI is not installed."
    log_warn "gh CLI not found; skipping GitHub push"
    return 0
  fi

  if ! gh auth status >/dev/null 2>&1; then
    GEN_GITHUB_STATUS_MESSAGE="GitHub backup was skipped because gh is not authenticated."
    log_warn "gh CLI not authenticated; run 'gh auth login' and try again"
    return 0
  fi

  local username
  username="$(gh api user -q '.login' 2>/dev/null || true)"
  if [[ -z "$username" || "$username" == "null" ]]; then
    GEN_GITHUB_STATUS_MESSAGE="GitHub backup was skipped because dotfriend could not determine your GitHub username."
    log_warn "Could not determine GitHub username"
    return 0
  fi

  if [[ "$GEN_DRY_RUN" == "true" ]]; then
    GEN_GITHUB_STATUS_MESSAGE="[dry-run] Would create GitHub repo ${username}/${repo_name}"
    log_info "[dry-run] Would create GitHub repo ${username}/${repo_name}"
    return 0
  fi

  GEN_GITHUB_URL="https://github.com/${username}/${repo_name}"

  if gh repo view "${username}/${repo_name}" >/dev/null 2>&1; then
    local push_log
    push_log="$(mktemp)"

    log_warn "GitHub repo already exists: ${username}/${repo_name}"
    if ! (
      cd "$GEN_DIR"
      git remote add origin "https://github.com/${username}/${repo_name}.git" 2>/dev/null || true
      git branch -M main 2>/dev/null || true
      git push -u origin main || git push -u origin master
    ) >"$push_log" 2>&1; then
      GEN_GITHUB_STATUS_MESSAGE="The local repo was generated, but dotfriend could not push it to ${GEN_GITHUB_URL}."
      log_warn "Could not push to ${GEN_GITHUB_URL}"
      _print_command_failure_log "$push_log"
      rm -f "$push_log"
      return 0
    fi

    rm -f "$push_log"
    GEN_GITHUB_BACKED_UP="true"
    GEN_GITHUB_STATUS_MESSAGE="Backed up to ${GEN_GITHUB_URL}"
    log_ok "Pushed to ${GEN_GITHUB_URL}"
    return 0
  fi

  local create_title="Creating private GitHub repo: ${username}/${repo_name}"
  local gh_create_log
  gh_create_log="$(mktemp)"
  if [[ "$GUM_AVAILABLE" == true ]]; then
    if ! (
      cd "$GEN_DIR"
      gum_spin --title "$create_title" --show-error -- \
        gh repo create "$repo_name" --private --source=. --push
    ); then
      GEN_GITHUB_STATUS_MESSAGE="The local repo was generated, but dotfriend could not create ${GEN_GITHUB_URL}."
      log_warn "GitHub repo creation failed for ${username}/${repo_name}"
      rm -f "$gh_create_log"
      return 1
    fi
  else
    log_info "$create_title"
    if ! (
      cd "$GEN_DIR"
      gh repo create "$repo_name" --private --source=. --push
    ) >"$gh_create_log" 2>&1; then
      GEN_GITHUB_STATUS_MESSAGE="The local repo was generated, but dotfriend could not create ${GEN_GITHUB_URL}."
      log_warn "GitHub repo creation failed for ${username}/${repo_name}"
      _print_command_failure_log "$gh_create_log"
      rm -f "$gh_create_log"
      return 1
    fi
  fi

  rm -f "$gh_create_log"
  GEN_GITHUB_BACKED_UP="true"
  GEN_GITHUB_STATUS_MESSAGE="Backed up to ${GEN_GITHUB_URL}"
  log_ok "Pushed to ${GEN_GITHUB_URL}"
}

# ─────────────────────────────────────────────────────────────
# Main generator entry point
# ─────────────────────────────────────────────────────────────

generate_repo() {
  local target_dir="${1-}"
  local dry_run="${2:-false}"
  local repo_name; repo_name="$(_selected_repo_name)"

  # Ensure we always use an absolute path
  if [[ -z "$target_dir" ]]; then
    target_dir="${HOME}/${repo_name}"
  fi

  GEN_DIR="$target_dir"
  GEN_BACKUP_ROOT="${HOME}/.dotfiles-backup"
  GEN_DRY_RUN="$dry_run"
  GEN_GITHUB_BACKED_UP="false"
  GEN_GITHUB_URL=""
  GEN_GITHUB_STATUS_MESSAGE=""

  if [[ "$dry_run" == "true" ]]; then
    log_info "[dry-run] Would generate repo at ${GEN_DIR}"
    return 0
  fi

  if [[ -d "$GEN_DIR" && -n "$(ls -A "$GEN_DIR" 2>/dev/null)" && "$GEN_FORCE" != "true" ]]; then
    if ! gum_confirm "${GEN_DIR} already exists and is not empty. Overwrite?"; then
      log_error "Aborting"
      return 1
    fi
  fi

  ensure_dir "$GEN_DIR"
  ensure_dir "${GEN_DIR}/scripts/lib"
  ensure_dir "${GEN_DIR}/config"
  ensure_dir "${GEN_DIR}/config/git"
  ensure_dir "${GEN_DIR}/zsh"
  ensure_dir "${GEN_DIR}/vscode"
  ensure_dir "${GEN_DIR}/cursor"
  ensure_dir "${GEN_DIR}/claude"
  ensure_dir "${GEN_DIR}/codex"
  ensure_dir "${GEN_DIR}/agents/skills"
  ensure_dir "${GEN_DIR}/agents/agent-docs"
  ensure_dir "${GEN_DIR}/dock"
  ensure_dir "${GEN_DIR}/macos"

  log_step "Generating dotfiles repository"
  log_info "Target directory: ${GEN_DIR}"

  _generation_run_section "brewfile" "Generating package list" _generate_brewfile
  _generation_run_section "npm_globals" "Generating npm package list" _generate_npm_globals_file
  _generation_run_section "install_script" "Generating install script" _generate_install_sh
  _generation_run_section "bootstrap_script" "Generating bootstrap script" _generate_bootstrap_sh
  _generation_run_section "gitignore" "Generating ignore rules" _generate_gitignore
  _generation_run_section "locations" "Generating location reference" _generate_locations_md
  _generation_run_section "repo_metadata" "Generating sync metadata" _generate_repo_metadata
  _generation_run_section "readme" "Generating README" _generate_readme_md
  _generation_run_section "dotfriend_readme" "Generating dotfriend metadata README" _generate_dotfriend_readme_md

  _generation_run_section "configs" "Copying selected config files" _copy_configs
  _generation_run_section "editor_configs" "Copying editor settings" _copy_editor_configs
  _generation_run_section "agent_configs" "Copying agent settings" _copy_agent_configs
  _generation_run_section "dock" "Copying Dock layout" _copy_dock
  _generation_run_section "macos_defaults" "Generating Mac settings" _generate_macos_defaults
  _generation_run_section "scripts" "Copying helper scripts" _copy_scripts
  _generation_run_section "restore_manifest" "Generating restore manifest" _generate_restore_manifest
  _generation_run_section "agent_artifacts" "Generating agent artifact manifest" _generate_agent_artifacts_manifest

  _init_git
  _github_push

  log_step "All set"
  if [[ "$GEN_GITHUB_BACKED_UP" == "true" ]]; then
    log_ok "Your dotfiles repo has been generated and backed up to GitHub."
  else
    log_ok "Your dotfiles repo has been generated."
    if [[ -n "$GEN_GITHUB_STATUS_MESSAGE" ]]; then
      log_info "$GEN_GITHUB_STATUS_MESSAGE"
    fi
  fi
  log_info "Local repo: ${GEN_DIR}"
  if [[ -n "$GEN_GITHUB_URL" ]]; then
    log_info "GitHub: ${GEN_GITHUB_URL}"
  fi
  log_info "To sync future changes from this Mac, run: dotfriend sync"
}
