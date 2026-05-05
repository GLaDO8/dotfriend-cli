#!/usr/bin/env bash
# dotfriend — Interactive wizard for `dotfriend start`
# shellcheck shell=bash

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Source dependencies
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=gum.sh
source "$SCRIPT_DIR/gum.sh"
# shellcheck source=discovery.sh
source "$SCRIPT_DIR/discovery.sh"

# ─────────────────────────────────────────────────────────────
# Globals
# ─────────────────────────────────────────────────────────────

DISCOVERY_CACHE="${DOTFRIEND_CACHE_DIR}/discovery.json"
SELECTIONS_FILE="${DOTFRIEND_CACHE_DIR}/selections.json"

# Selection arrays
SELECTED_APPS=()
SELECTED_AGENTS=()
SELECTED_FORMULAE=()
SELECTED_TAPS=()
SELECTED_NPM=()
SELECTED_DOTFILES=()

# Editor selections
EDITOR_VSCODE=false
EDITOR_CURSOR=false

# Other selections
DOCK_BACKUP=false
DOCK_DEFAULTS=false
XCODE=false
TELEMETRY=false
GITHUB_REPO="dotfiles"
GITHUB_PRIVATE=true

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

_require_wizard_runtime() {
  local cmd

  for cmd in jq gum gh mas npm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_error "dotfriend bootstrap should have installed '$cmd', but it is still missing."
      exit 1
    fi
  done
}

_write_selections_json() {
  local file="$1"
  ensure_dir "$(dirname "$file")"

  local json="{"

  # apps
  json+='"apps":['
  local first=true
  for item in "${SELECTED_APPS[@]}"; do
    [[ -z "$item" ]] && continue
    [[ "$first" == true ]] || json+=","
    first=false
    local name="${item%%|*}"
    local rest="${item#*|}"
    local cask="${rest%%|*}"
    local source="${rest##*|}"
    json+="{\"name\":\"$(json_escape "$name")\",\"cask\":\"$(json_escape "$cask")\",\"source\":\"$(json_escape "$source")\"}"
  done
  json+="],"

  # agents
  json+='"agents":['
  first=true
  for item in "${SELECTED_AGENTS[@]}"; do
    [[ -z "$item" ]] && continue
    [[ "$first" == true ]] || json+=","
    first=false
    local id="${item%%|*}"
    local aname="${item#*|}"
    json+="{\"id\":\"$(json_escape "$id")\",\"name\":\"$(json_escape "$aname")\"}"
  done
  json+="],"

  # formulae
  json+='"formulae":['
  first=true
  for item in "${SELECTED_FORMULAE[@]}"; do
    [[ -z "$item" ]] && continue
    [[ "$first" == true ]] || json+=","
    first=false
    json+="\"$(json_escape "$item")\""
  done
  json+="],"

  # taps
  json+='"taps":['
  first=true
  for item in "${SELECTED_TAPS[@]}"; do
    [[ -z "$item" ]] && continue
    [[ "$first" == true ]] || json+=","
    first=false
    json+="\"$(json_escape "$item")\""
  done
  json+="],"

  # npm_globals
  json+='"npm_globals":['
  first=true
  for item in "${SELECTED_NPM[@]}"; do
    [[ -z "$item" ]] && continue
    [[ "$first" == true ]] || json+=","
    first=false
    json+="\"$(json_escape "$item")\""
  done
  json+="],"

  # dotfiles
  json+='"dotfiles":['
  first=true
  for item in "${SELECTED_DOTFILES[@]}"; do
    [[ -z "$item" ]] && continue
    [[ "$first" == true ]] || json+=","
    first=false
    json+="\"$(json_escape "$item")\""
  done
  json+="],"

  # config_dirs (include all discovered)
  json+='"config_dirs":['
  first=true
  if [[ -f "$DISCOVERY_CACHE" ]]; then
    while IFS= read -r cfg; do
      [[ -z "$cfg" ]] && continue
      [[ "$first" == true ]] || json+=","
      first=false
      json+="\"$(json_escape "$cfg")\""
    done < <(discovery_cache_lines config_dirs "$DISCOVERY_CACHE")
  fi
  json+="],"

  # editors
  local vscode_str="false"
  [[ "$EDITOR_VSCODE" == true ]] && vscode_str="true"
  local cursor_str="false"
  [[ "$EDITOR_CURSOR" == true ]] && cursor_str="true"
  json+='"editors":{"vscode":'"$vscode_str"',"cursor":'"$cursor_str"'},'

  # dock
  local dock_backup_str="false"
  [[ "$DOCK_BACKUP" == true ]] && dock_backup_str="true"
  local dock_defaults_str="false"
  [[ "$DOCK_DEFAULTS" == true ]] && dock_defaults_str="true"
  json+='"dock":{"backup":'"$dock_backup_str"',"defaults":'"$dock_defaults_str"'},'

  # xcode
  local xcode_str="false"
  [[ "$XCODE" == true ]] && xcode_str="true"
  json+='"xcode":'"$xcode_str"','

  # telemetry
  local tele_str="false"
  [[ "$TELEMETRY" == true ]] && tele_str="true"
  json+='"telemetry":'"$tele_str"','

  # github
  json+='"github":{"repo_name":"'"$(json_escape "$GITHUB_REPO")"'","private":'
  local gh_private_str="false"
  [[ "$GITHUB_PRIVATE" == true ]] && gh_private_str="true"
  json+=''"$gh_private_str"'}'

  json+="}"

  printf '%s\n' "$json" > "$file"
}

discovery_cache_lines() {
  local field="$1" cache_file="${2:-$DISCOVERY_CACHE}"
  [[ -f "$cache_file" ]] || return 0
  case "$field" in
    apps)
      jq -r '
        if (.schema_version // 1) == 2 then
          .apps[]? | [.name, (.restore_ref // (if .source == "cask" then "cask:\(.cask)" else .source end))] | @tsv | gsub("\t"; "|")
        else
          (.apps // "") | split("\n")[] | select(length > 0)
        end
      ' "$cache_file" 2>/dev/null || true
      ;;
    agents)
      jq -r '
        if (.schema_version // 1) == 2 then
          .agents[]? | [.id, .name, (.config_dir // ""), (.status // "missing"), ((.skill_count // 0) | tostring)] | @tsv | gsub("\t"; "|")
        else
          (.agents // "") | split("\n")[] | select(length > 0)
        end
      ' "$cache_file" 2>/dev/null || true
      ;;
    formulae)
      jq -r '
        if (.schema_version // 1) == 2 then
          .formulae[]? | [.name, (.description // "")] | @tsv | gsub("\t"; "|")
        else
          (.formulae // "") | split("\n")[] | select(length > 0)
        end
      ' "$cache_file" 2>/dev/null || true
      ;;
    taps)
      jq -r 'if (.schema_version // 1) == 2 then .taps[]? | .name // empty else (.taps // "") | split("\n")[] | select(length > 0) end' "$cache_file" 2>/dev/null || true
      ;;
    npm_globals)
      jq -r 'if (.schema_version // 1) == 2 then .npm_globals[]? | if .version then "\(.name)@\(.version)" else .name end else (.npm_globals // "") | split("\n")[] | select(length > 0) end' "$cache_file" 2>/dev/null || true
      ;;
    dotfiles)
      jq -r 'if (.schema_version // 1) == 2 then .dotfiles[]? | .path // empty else (.dotfiles // "") | split("\n")[] | select(length > 0) end' "$cache_file" 2>/dev/null || true
      ;;
    config_dirs)
      jq -r 'if (.schema_version // 1) == 2 then .config_dirs[]? | .name // empty else (.config_dirs // "") | split("\n")[] | select(length > 0) end' "$cache_file" 2>/dev/null || true
      ;;
  esac
}

discovery_editor_settings_path() {
  local editor="$1" cache_file="${2:-$DISCOVERY_CACHE}"
  [[ -f "$cache_file" ]] || return 0
  jq -r --arg editor "$editor" '
    if (.schema_version // 1) == 2 then
      .editors[$editor].settings_path // empty
    else
      .[$editor] // empty
    end
  ' "$cache_file" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────
### Step 0: Welcome & Parallel Discovery
# ─────────────────────────────────────────────────────────────

_step0_welcome_and_discovery() {
  gum_style --foreground 212 --border double --padding "1 2" --align center \
    "Welcome to dotfriend v${DOTFRIEND_VERSION}"
  gum_style --foreground 240 --align center \
    "Dotfriend helps you backup all your apps, configurations, agent settings (Codex, Claude Code etc.) and preferences, and install them on a new Mac with a single script."

  if ! gum_confirm --prompt "Ready to customise your setup and backup settings?"; then
    log_info "Wizard cancelled. No changes were made."
    exit 0
  fi

  log_step "Step 0: Scanning your system..."
  gum_style --foreground 240 \
    "Dotfriend is finding Homebrew Cask IDs for all your apps (Homebrew Cask is a CLI workflow for installing macOS applications.)"

  log_info "Running discovery (this may take a moment)..."
  run_discovery

  if [[ ! -f "$DISCOVERY_CACHE" ]]; then
    log_warn "Discovery did not produce expected cache file at $DISCOVERY_CACHE"
  fi
}

# ─────────────────────────────────────────────────────────────
### Step 1: macOS Apps
# ─────────────────────────────────────────────────────────────

_step1_apps() {
  log_step "Step 1: macOS Apps"

  if [[ ! -f "$DISCOVERY_CACHE" ]]; then
    log_info "No discovery cache found. Skipping app selection."
    return 0
  fi

  local -a displays=()
  local -a names=()
  local -a casks=()
  local -a sources=()

  while IFS='|' read -r name rest; do
    [[ -z "$name" ]] && continue
    names+=("$name")

    local cask="" source="unknown" display="$name"
    if [[ "$rest" == cask:* ]]; then
      local cask_token="${rest#cask:}"
      cask="cask:${cask_token}"
      source="cask"
      display="$name (cask: $cask_token)"
    elif [[ "$rest" == mas:* ]]; then
      local mas_cask_id="${rest#mas:}"
      local mas_cask="${mas_cask_id%%,*}"
      local mas_id="${mas_cask_id##*id:}"
      cask="mas:${mas_cask},id:${mas_id}"
      source="mas"
      display="$name (mas: $mas_cask)"
    elif [[ "$rest" == appstore:* ]]; then
      local appstore_id="${rest#appstore:}"
      cask="appstore:${appstore_id}"
      source="appstore"
      display="$name (App Store detected)"
    elif [[ "$rest" == "manual" ]]; then
      source="manual"
      display="$name (manual)"
    else
      display="$name (unable to backup)"
    fi
    casks+=("$cask")
    sources+=("$source")
    displays+=("$display")
  done < <(discovery_cache_lines apps "$DISCOVERY_CACHE")

  if [[ ${#displays[@]} -eq 0 ]]; then
    log_info "No apps discovered. Skipping."
    return 0
  fi

  local -a choose_args=(--no-limit --header "Select apps to back up:")
  for d in "${displays[@]}"; do
    # Escape commas for gum choose --selected (pflag StringSlice splits on commas)
    choose_args+=(--selected "${d//,/\\,}")
  done
  choose_args+=("${displays[@]}")

  local -a selected_displays=()
  while IFS= read -r line; do
    selected_displays+=("$line")
  done < <(gum_choose "${choose_args[@]}")

  SELECTED_APPS=()
  local -a skipped_apps=()
  for sel in "${selected_displays[@]}"; do
    for i in "${!displays[@]}"; do
      if [[ "${displays[$i]}" == "$sel" ]]; then
        local s_name="${names[$i]}"
        local s_cask="${casks[$i]}"
        local s_source="${sources[$i]}"

        # Skip apps with no cask found — don't prompt for manual entry
        if [[ "$s_source" == "unknown" || -z "$s_cask" || "$s_source" == "manual" || "$s_source" == "appstore" ]]; then
          skipped_apps+=("$s_name")
          continue
        fi

        SELECTED_APPS+=("$s_name|$s_cask|$s_source")
        break
      fi
    done
  done

  if [[ ${#skipped_apps[@]} -gt 0 ]]; then
    log_info "Some apps are not restorable automatically, skipping them: ${skipped_apps[*]}"
  fi
}

# ─────────────────────────────────────────────────────────────
### Step 2: Agentic Tools
# ─────────────────────────────────────────────────────────────

_step2_agents() {
  log_step "Step 2: Agentic Tools"
  gum_style --foreground 240 \
    "Backup all skill files, hooks, plugins and settings"

  if [[ ! -f "$DISCOVERY_CACHE" ]]; then
    log_info "No discovery cache found. Skipping agentic tools."
    return 0
  fi

  local -a displays=()
  local -a ids=()
  local -a anames=()

  while IFS='|' read -r id aname path status skill_count; do
    [[ -z "$id" ]] && continue
    # Only show tools that were found on the system
    [[ "$status" == "found" ]] || continue
    ids+=("$id")
    anames+=("$aname")
    local skill_label="skills"
    [[ "$skill_count" -eq 1 ]] && skill_label="skill"
    displays+=("$aname ($skill_count $skill_label)")
  done < <(discovery_cache_lines agents "$DISCOVERY_CACHE")

  if [[ ${#displays[@]} -eq 0 ]]; then
    log_info "No agentic tools discovered on this Mac. Skipping."
    return 0
  fi

  local -a choose_args=(--no-limit --header "Select agentic tools to back up:")
  for d in "${displays[@]}"; do
    # Escape commas for gum choose --selected (pflag StringSlice splits on commas)
    choose_args+=(--selected "${d//,/\\,}")
  done
  choose_args+=("${displays[@]}")

  local -a selected_displays=()
  while IFS= read -r line; do
    selected_displays+=("$line")
  done < <(gum_choose "${choose_args[@]}")

  SELECTED_AGENTS=()
  for sel in "${selected_displays[@]}"; do
    for i in "${!displays[@]}"; do
      if [[ "${displays[$i]}" == "$sel" ]]; then
        SELECTED_AGENTS+=("${ids[$i]}|${anames[$i]}")
        break
      fi
    done
  done
}

# ─────────────────────────────────────────────────────────────
### Step 3: Brew Formulae
# ─────────────────────────────────────────────────────────────

_step3_formulae() {
  log_step "Step 3: Brew Formulae"

  if [[ ! -f "$DISCOVERY_CACHE" ]]; then
    log_info "No discovery cache found. Skipping formulae."
    return 0
  fi

  local -a displays=()
  local -a fnames=()

  while IFS='|' read -r name desc; do
    [[ -z "$name" ]] && continue
    fnames+=("$name")
    displays+=("$name — ${desc:-No description}")
  done < <(discovery_cache_lines formulae "$DISCOVERY_CACHE")

  if [[ ${#displays[@]} -eq 0 ]]; then
    log_info "No formulae discovered. Skipping."
    return 0
  fi

  local -a choose_args=(--no-limit --header "Select formulae to include in your Brewfile:")
  for d in "${displays[@]}"; do
    # Workaround: gum choose --selected uses pflag StringSlice which splits on
    # commas, so values containing commas fail to match. Escape commas with
    # backslash in --selected arguments so gum matches them correctly.
    local d_safe="${d//,/\\,}"
    choose_args+=(--selected "$d_safe")
  done
  choose_args+=("${displays[@]}")

  local -a selected_displays=()
  while IFS= read -r line; do
    selected_displays+=("$line")
  done < <(gum_choose "${choose_args[@]}")

  SELECTED_FORMULAE=()
  for sel in "${selected_displays[@]}"; do
    for i in "${!displays[@]}"; do
      if [[ "${displays[$i]}" == "$sel" ]]; then
        SELECTED_FORMULAE+=("${fnames[$i]}")
        break
      fi
    done
  done
}

# ─────────────────────────────────────────────────────────────
### Step 4: Homebrew Taps
# ─────────────────────────────────────────────────────────────

_step4_taps() {
  log_step "Step 4: Homebrew Taps"

  if [[ ! -f "$DISCOVERY_CACHE" ]]; then
    log_info "No discovery cache found. Skipping taps."
    return 0
  fi

  local -a taps=()
  while IFS= read -r tap; do
    [[ -z "$tap" ]] && continue
    taps+=("$tap")
  done < <(discovery_cache_lines taps "$DISCOVERY_CACHE")

  if [[ ${#taps[@]} -eq 0 ]]; then
    log_info "No taps discovered. Skipping."
    return 0
  fi

  local -a choose_args=(--no-limit --header "Select Homebrew taps to track:")
  for t in "${taps[@]}"; do
    # Escape commas for gum choose --selected (pflag StringSlice splits on commas)
    choose_args+=(--selected "${t//,/\\,}")
  done
  choose_args+=("${taps[@]}")

  local -a selected=()
  while IFS= read -r line; do
    selected+=("$line")
  done < <(gum_choose "${choose_args[@]}")

  SELECTED_TAPS=()
  for sel in "${selected[@]}"; do
    SELECTED_TAPS+=("$sel")
  done
}

# ─────────────────────────────────────────────────────────────
### Step 5: npm Global Packages
# ─────────────────────────────────────────────────────────────

_step5_npm() {
  log_step "Step 5: npm Global Packages"

  if [[ ! -f "$DISCOVERY_CACHE" ]]; then
    log_info "No discovery cache found. Skipping npm packages."
    return 0
  fi

  local -a packages=()
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    packages+=("$pkg")
  done < <(discovery_cache_lines npm_globals "$DISCOVERY_CACHE")

  if [[ ${#packages[@]} -eq 0 ]]; then
    log_info "No npm global packages discovered. Skipping."
    return 0
  fi

  local -a choose_args=(--no-limit --header "Select npm global packages to track:")
  for p in "${packages[@]}"; do
    # Escape commas for gum choose --selected (pflag StringSlice splits on commas)
    choose_args+=(--selected "${p//,/\\,}")
  done
  choose_args+=("${packages[@]}")

  local -a selected=()
  while IFS= read -r line; do
    selected+=("$line")
  done < <(gum_choose "${choose_args[@]}")

  SELECTED_NPM=()
  for sel in "${selected[@]}"; do
    SELECTED_NPM+=("$sel")
  done
}

# ─────────────────────────────────────────────────────────────
### Step 6: Dotfiles
# ─────────────────────────────────────────────────────────────

_step6_dotfiles() {
  log_step "Step 6: Dotfiles"

  if [[ ! -f "$DISCOVERY_CACHE" ]]; then
    log_info "No discovery cache found. Skipping dotfiles."
    return 0
  fi

  local -a displays=()
  local -a paths=()

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    local category="Misc"
    case "$path" in
      .zshrc|.bashrc) category="Shell" ;;
      .gitconfig|.gitignore) category="Git" ;;
      .tmux.conf|.npmrc|.ignore) category="Tools" ;;
    esac
    paths+=("$path")
    displays+=("${category}: $path")
  done < <(discovery_cache_lines dotfiles "$DISCOVERY_CACHE" | sort -t: -k1,1 -k2,2 || true)

  if [[ ${#displays[@]} -eq 0 ]]; then
    log_info "No dotfiles discovered. Skipping."
    return 0
  fi

  log_warn "Security note: SSH private keys are never backed up. Only ~/.ssh/config is offered."

  local -a choose_args=(--no-limit --header "Select dotfiles to track:")
  for d in "${displays[@]}"; do
    # Escape commas for gum choose --selected (pflag StringSlice splits on commas)
    choose_args+=(--selected "${d//,/\\,}")
  done
  choose_args+=("${displays[@]}")

  local -a selected_displays=()
  while IFS= read -r line; do
    selected_displays+=("$line")
  done < <(gum_choose "${choose_args[@]}")

  SELECTED_DOTFILES=()
  for sel in "${selected_displays[@]}"; do
    for i in "${!displays[@]}"; do
      if [[ "${displays[$i]}" == "$sel" ]]; then
        SELECTED_DOTFILES+=("${paths[$i]}")
        break
      fi
    done
  done
}

# ─────────────────────────────────────────────────────────────
### Step 7: Editors (VS Code & Cursor)
# ─────────────────────────────────────────────────────────────

_step7_editors() {
  log_step "Step 7: Editors"

  local has_vscode=false
  local has_cursor=false

  if [[ -f "$DISCOVERY_CACHE" ]]; then
    local vscode_str cursor_str
    vscode_str="$(discovery_editor_settings_path vscode "$DISCOVERY_CACHE")"
    cursor_str="$(discovery_editor_settings_path cursor "$DISCOVERY_CACHE")"
    [[ -n "$vscode_str" && "$vscode_str" != "settings:missing" ]] && has_vscode=true
    [[ -n "$cursor_str" && "$cursor_str" != "settings:missing" ]] && has_cursor=true
  fi

  local -a editor_options=()
  [[ "$has_vscode" == "true" ]] && editor_options+=("VS Code")
  [[ "$has_cursor" == "true" ]] && editor_options+=("Cursor")

  if [[ ${#editor_options[@]} -eq 0 ]]; then
    log_info "No editors detected. Skipping."
    return 0
  fi

  local -a choose_args=(--no-limit --header "Select editors to back up settings and extensions for:")
  for opt in "${editor_options[@]}"; do
    # Escape commas for gum choose --selected (pflag StringSlice splits on commas)
    choose_args+=(--selected "${opt//,/\\,}")
  done
  choose_args+=("${editor_options[@]}")

  local -a selected=()
  while IFS= read -r line; do
    selected+=("$line")
  done < <(gum_choose "${choose_args[@]}")

  EDITOR_VSCODE=false
  EDITOR_CURSOR=false
  for sel in "${selected[@]}"; do
    [[ "$sel" == "VS Code" ]] && EDITOR_VSCODE=true
    [[ "$sel" == "Cursor" ]] && EDITOR_CURSOR=true
  done
}

# ─────────────────────────────────────────────────────────────
### Step 8: Dock & Default Apps
# ─────────────────────────────────────────────────────────────

_step8_dock() {
  log_step "Step 8: Dock & Default Apps"

  if gum_confirm --prompt "Back up current Dock layout?"; then
    DOCK_BACKUP=true
  fi

  if gum_confirm --prompt "Set default app associations on restore (requires duti)?"; then
    DOCK_DEFAULTS=true
  fi
}

# ─────────────────────────────────────────────────────────────
### Step 9: Xcode Command Line Tools
# ─────────────────────────────────────────────────────────────

_step9_xcode() {
  log_step "Step 9: Xcode Command Line Tools"

  gum_style --foreground 240 \
    "These tools are required for Homebrew, Git, and many developer tools. Recommended for all users."

  if gum_confirm --prompt "Include xcode-select --install in install.sh?"; then
    XCODE=true
  fi
}

# ─────────────────────────────────────────────────────────────
### Step 10: Telemetry & Analytics
# ─────────────────────────────────────────────────────────────

_step10_telemetry() {
  log_step "Step 10: Telemetry & Analytics"

  gum_style --foreground 240 \
    "Disable data collection for Homebrew, Go, GitHub CLI, Bun, npm, pnpm, and Deno. Recommended for privacy."

  if gum_confirm --prompt "Disable telemetry and analytics in generated scripts?"; then
    TELEMETRY=true
  fi
}

# ─────────────────────────────────────────────────────────────
### Step 11: Generate Repository
# ─────────────────────────────────────────────────────────────

_step11_collect() {
  log_step "Step 11: Prepare Repository Generation"

  _write_selections_json "$SELECTIONS_FILE"

  log_ok "Selections saved to $SELECTIONS_FILE"

  gum_style --foreground 240 "Summary:"
  log_info "Apps:      ${#SELECTED_APPS[@]}"
  log_info "Agents:    ${#SELECTED_AGENTS[@]}"
  log_info "Formulae:  ${#SELECTED_FORMULAE[@]}"
  log_info "Taps:      ${#SELECTED_TAPS[@]}"
  log_info "npm:       ${#SELECTED_NPM[@]}"
  log_info "Dotfiles:  ${#SELECTED_DOTFILES[@]}"
  log_info "VS Code:   $EDITOR_VSCODE"
  log_info "Cursor:    $EDITOR_CURSOR"
  log_info "Dock:      backup=$DOCK_BACKUP, defaults=$DOCK_DEFAULTS"
  log_info "Xcode CLI: $XCODE"
  log_info "Telemetry: $TELEMETRY"
}

# ─────────────────────────────────────────────────────────────
### Step 12: GitHub Backup
# ─────────────────────────────────────────────────────────────

_step12_github() {
  log_step "Step 12: GitHub Backup"

  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      log_ok "GitHub CLI authenticated."
    else
      log_warn "GitHub CLI is not authenticated."
      if gum_confirm --prompt "Run gh auth login now?"; then
        gh auth login
      fi
    fi
  else
    log_warn "GitHub CLI (gh) not found. Install it to push to GitHub later."
  fi

  GITHUB_REPO=$(gum_input --placeholder "Repository name" --value "dotfiles" --header "Enter a name for your GitHub dotfiles repository:")

  if gum_confirm --prompt "Create as a private repository?"; then
    GITHUB_PRIVATE=true
  else
    GITHUB_PRIVATE=false
  fi

  # Rewrite selections with updated GitHub config
  _write_selections_json "$SELECTIONS_FILE"

  log_ok "GitHub config saved: $GITHUB_REPO (private=$GITHUB_PRIVATE)"
}

# ─────────────────────────────────────────────────────────────
# Main entry point
# ─────────────────────────────────────────────────────────────

wizard_start() {
  ensure_dir "$DOTFRIEND_CACHE_DIR"
  _require_wizard_runtime
  gum_ensure

  # Reset selections for idempotency
  SELECTED_APPS=()
  SELECTED_AGENTS=()
  SELECTED_FORMULAE=()
  SELECTED_TAPS=()
  SELECTED_NPM=()
  SELECTED_DOTFILES=()
  EDITOR_VSCODE=false
  EDITOR_CURSOR=false
  DOCK_BACKUP=false
  DOCK_DEFAULTS=false
  XCODE=false
  TELEMETRY=false
  GITHUB_REPO="dotfiles"
  GITHUB_PRIVATE=true

  _step0_welcome_and_discovery
  _step1_apps
  _step2_agents
  _step3_formulae
  _step4_taps
  _step5_npm
  _step6_dotfiles
  _step7_editors
  _step8_dock
  _step9_xcode
  _step10_telemetry
  _step11_collect
  _step12_github

  log_ok "Wizard complete!"
  gum_style --foreground 240 "Your selections are ready for code generation."
}
