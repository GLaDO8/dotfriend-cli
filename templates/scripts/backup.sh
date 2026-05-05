#!/usr/bin/env bash
# dotfriend — Reverse-sync: copy machine state back to repo
# Usage: backup.sh [--dry-run] [--commit]
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────

DRY_RUN=false
AUTO_COMMIT=false
CHANGES_MADE=false

# ─────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --commit) AUTO_COMMIT=true ;;
  esac
done

# ─────────────────────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_DIM='\033[2m'
  C_RED='\033[31m'
  C_GREEN='\033[32m'
  C_YELLOW='\033[33m'
  C_BLUE='\033[34m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
fi

log_info()  { printf "${C_BLUE}ℹ${C_RESET}  %s\n" "$*"; }
log_ok()    { printf "${C_GREEN}✔${C_RESET}  %s\n" "$*"; }
log_warn()  { printf "${C_YELLOW}⚠${C_RESET}  %s\n" "$*" >&2; }
log_error() { printf "${C_RED}✖${C_RESET}  %s\n" "$*" >&2; }
log_step()  { printf "\n${C_BOLD}${C_BLUE}→ %s${C_RESET}\n" "$*"; }

dry_warn() {
  if [[ "$DRY_RUN" == true ]]; then
    printf "${C_YELLOW}[DRY-RUN]${C_RESET} %s\n" "$*"
  fi
}

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

has_brew() { command -v brew >/dev/null 2>&1; }
has_npm()  { command -v npm >/dev/null 2>&1; }
has_git()  { command -v git >/dev/null 2>&1; }

agent_tools_file() {
  local agents_file="${REPO_ROOT}/.dotfriend/agent-tools.json"
  if [[ ! -f "$agents_file" ]]; then
    agents_file="${SCRIPT_DIR}/../lib/agent-tools.json"
  fi
  printf '%s' "$agents_file"
}

selected_agent_ids() {
  local selections_file="${REPO_ROOT}/.dotfriend/selections.json"
  if [[ -f "$selections_file" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.agents // [] | .[] | .id' "$selections_file" 2>/dev/null || true
    return 0
  fi

  local agents_file
  agents_file="$(agent_tools_file)"
  if [[ -f "$agents_file" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.agentic_tools[].id' "$agents_file" 2>/dev/null || true
  fi
}

run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    printf "${C_DIM}   would run: %s${C_RESET}\n" "$*"
  else
    "$@"
  fi
}

copy_file() {
  local src="$1" dest="$2"
  if [[ "$DRY_RUN" == true ]]; then
    printf "${C_DIM}   would copy: %s → %s${C_RESET}\n" "$src" "$dest"
    CHANGES_MADE=true
    return
  fi
  mkdir -p "$(dirname "$dest")"
  if cp -a "$src" "$dest"; then
    CHANGES_MADE=true
    log_ok "Copied: $(basename "$src")"
  else
    log_error "Failed to copy: $src"
  fi
}

# ─────────────────────────────────────────────────────────────
# 1. Sync config directories
# ─────────────────────────────────────────────────────────────

sync_configs() {
  log_step "Syncing config directories"

  local config_dir="${REPO_ROOT}/config"
  if [[ ! -d "$config_dir" ]]; then
    log_warn "No config/ directory in repo"
    return
  fi

  local subdir live_path
  while IFS= read -r -d '' subdir; do
    local name
    name="$(basename "$subdir")"
    live_path="${HOME}/.config/${name}"

    if [[ -d "$live_path" ]]; then
      if [[ "$DRY_RUN" == true ]]; then
        printf "${C_DIM}   would rsync: %s → %s${C_RESET}\n" "$live_path/" "${config_dir}/${name}/"
        CHANGES_MADE=true
      else
        mkdir -p "${config_dir}/${name}"
        # Use rsync if available, fallback to cp -R
        if command -v rsync >/dev/null 2>&1; then
          if rsync -a --delete "$live_path/" "${config_dir:?}/${name}/"; then
            CHANGES_MADE=true
          fi
        else
          rm -rf "${config_dir:?}/${name}" || true
          if cp -R "$live_path" "${config_dir:?}/${name}"; then
            CHANGES_MADE=true
          fi
        fi
        log_ok "Synced config: $name"
      fi
    else
      log_warn "Live config not found: $live_path"
    fi
  done < <(find "$config_dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null || true)
}

# ─────────────────────────────────────────────────────────────
# 2. Update Brewfile
# ─────────────────────────────────────────────────────────────

sync_brewfile() {
  if ! has_brew; then
    log_warn "Homebrew not found, skipping Brewfile sync"
    return
  fi

  log_step "Updating Brewfile"

  local brewfile="${REPO_ROOT}/Brewfile"
  local tmpfile
  tmpfile="$(mktemp)"

  # Taps
  {
    echo "# Taps"
    brew tap | while IFS= read -r tap; do
      echo "tap \"${tap}\""
    done
    echo ""
  } >> "$tmpfile"

  # Formulae
  {
    echo "# Formulae"
    brew leaves 2>/dev/null | sort | while IFS= read -r formula; do
      echo "brew \"${formula}\""
    done
    echo ""
  } >> "$tmpfile"

  # Casks
  {
    echo "# Casks"
    brew list --cask 2>/dev/null | sort | while IFS= read -r cask; do
      echo "cask \"${cask}\""
    done
    echo ""
  } >> "$tmpfile"

  # Mac App Store apps (if mas installed)
  if command -v mas >/dev/null 2>&1; then
    {
      echo "# Mac App Store"
      mas list 2>/dev/null | while IFS= read -r line; do
        local id name
        id="$(printf '%s' "$line" | awk '{print $1}')"
        name="$(printf '%s' "$line" | cut -d' ' -f2-)"
        echo "mas \"${name}\", id: ${id}"
      done
      echo ""
    } >> "$tmpfile"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    printf "${C_DIM}   would regenerate: %s${C_RESET}\n" "$brewfile"
    rm -f "$tmpfile"
    CHANGES_MADE=true
    return
  fi

  if [[ -f "$brewfile" ]] && diff -q "$brewfile" "$tmpfile" >/dev/null 2>&1; then
    log_info "Brewfile unchanged"
    rm -f "$tmpfile"
    return
  fi

  mv "$tmpfile" "$brewfile"
  CHANGES_MADE=true
  log_ok "Brewfile updated"
}

# ─────────────────────────────────────────────────────────────
# 3. Update npm globals
# ─────────────────────────────────────────────────────────────

sync_npm() {
  if ! has_npm; then
    log_warn "npm not found, skipping npm sync"
    return
  fi

  log_step "Updating npm global packages"

  local npmfile="${REPO_ROOT}/npm-global.txt"
  local tmpfile
  tmpfile="$(mktemp)"

  npm list -g --depth=0 2>/dev/null | tail -n +2 | sed 's/├─//g; s/└─//g; s/│//g; s/ //g' | \
    grep -v '^$' | sort > "$tmpfile"

  if [[ "$DRY_RUN" == true ]]; then
    printf "${C_DIM}   would regenerate: %s${C_RESET}\n" "$npmfile"
    rm -f "$tmpfile"
    CHANGES_MADE=true
    return
  fi

  if [[ -f "$npmfile" ]] && diff -q "$npmfile" "$tmpfile" >/dev/null 2>&1; then
    log_info "npm-global.txt unchanged"
    rm -f "$tmpfile"
    return
  fi

  mv "$tmpfile" "$npmfile"
  CHANGES_MADE=true
  log_ok "npm-global.txt updated"
}

# ─────────────────────────────────────────────────────────────
# 4. Sync editor extension manifests
# ─────────────────────────────────────────────────────────────

sync_editor_extensions() {
  log_step "Syncing editor extension manifests"

  local target_file tmpfile

  if [[ -d "${REPO_ROOT}/vscode" ]]; then
    if command -v code >/dev/null 2>&1; then
      target_file="${REPO_ROOT}/vscode/extensions.txt"
      tmpfile="$(mktemp)"
      code --list-extensions 2>/dev/null | sort > "$tmpfile"

      if [[ "$DRY_RUN" == true ]]; then
        printf "${C_DIM}   would regenerate: %s${C_RESET}\n" "$target_file"
        rm -f "$tmpfile"
        CHANGES_MADE=true
      elif [[ -f "$target_file" ]] && diff -q "$target_file" "$tmpfile" >/dev/null 2>&1; then
        log_info "vscode/extensions.txt unchanged"
        rm -f "$tmpfile"
      else
        mv "$tmpfile" "$target_file"
        CHANGES_MADE=true
        log_ok "vscode/extensions.txt updated"
      fi
    else
      log_warn "VS Code CLI not found, skipping vscode/extensions.txt sync"
    fi
  fi

  if [[ -d "${REPO_ROOT}/cursor" ]]; then
    if command -v cursor >/dev/null 2>&1; then
      target_file="${REPO_ROOT}/cursor/extensions.txt"
      tmpfile="$(mktemp)"
      cursor --list-extensions 2>/dev/null | sort > "$tmpfile"

      if [[ "$DRY_RUN" == true ]]; then
        printf "${C_DIM}   would regenerate: %s${C_RESET}\n" "$target_file"
        rm -f "$tmpfile"
        CHANGES_MADE=true
      elif [[ -f "$target_file" ]] && diff -q "$target_file" "$tmpfile" >/dev/null 2>&1; then
        log_info "cursor/extensions.txt unchanged"
        rm -f "$tmpfile"
      else
        mv "$tmpfile" "$target_file"
        CHANGES_MADE=true
        log_ok "cursor/extensions.txt updated"
      fi
    else
      log_warn "Cursor CLI not found, skipping cursor/extensions.txt sync"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────
# 5. Sync agent tool configs
# ─────────────────────────────────────────────────────────────

sync_agents() {
  log_step "Syncing agent tool configs"

  local agents_file
  agents_file="$(agent_tools_file)"

  if [[ ! -f "$agents_file" ]]; then
    log_warn "agent-tools.json not found"
    return
  fi

  local id canonical_dir file dir repo_dir
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue

    canonical_dir="$(jq -r --arg id "$id" '.agentic_tools[] | select(.id == $id) | .canonical_dir // empty' "$agents_file" 2>/dev/null || true)"
    [[ -n "$canonical_dir" && "$canonical_dir" != "null" ]] || continue
    canonical_dir="${canonical_dir/#\~/${HOME}}"
    repo_dir="${REPO_ROOT}/${id}"

    if [[ ! -d "$canonical_dir" ]]; then
      continue
    fi

    [[ "$DRY_RUN" == true ]] || mkdir -p "$repo_dir"

    local important_files important_dirs
    important_files="$(jq -r --arg id "$id" '.agentic_tools[] | select(.id == $id) | .important_files[]?' "$agents_file" 2>/dev/null || true)"
    important_dirs="$(jq -r --arg id "$id" '.agentic_tools[] | select(.id == $id) | .important_dirs[]?' "$agents_file" 2>/dev/null || true)"

    if [[ -z "$important_files" && -z "$important_dirs" ]]; then
      if [[ "$DRY_RUN" == true ]]; then
        printf "${C_DIM}   would rsync: %s → %s${C_RESET}\n" "$canonical_dir/" "${repo_dir}/"
        CHANGES_MADE=true
      else
        mkdir -p "$repo_dir"
        if command -v rsync >/dev/null 2>&1; then
          if rsync -a --delete "$canonical_dir/" "${repo_dir}/"; then
            CHANGES_MADE=true
          fi
        else
          rm -rf "${repo_dir:?}" || true
          if cp -R "$canonical_dir" "$repo_dir"; then
            CHANGES_MADE=true
          fi
        fi
      fi
      log_ok "Synced agent: $id"
      continue
    fi

    # Sync important files
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      local src="${canonical_dir}/${file}"
      if [[ -f "$src" && ! -L "$src" ]]; then
        copy_file "$src" "${repo_dir}/${file}"
      elif [[ -L "$src" ]]; then
        log_info "Skipping symlinked agent file: $src"
      fi
    done <<< "$important_files"

    # Sync important dirs
    while IFS= read -r dir; do
      [[ -z "$dir" ]] && continue
      local src="${canonical_dir}/${dir}"
      if [[ -d "$src" && ! -L "$src" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
          printf "${C_DIM}   would rsync: %s → %s${C_RESET}\n" "$src/" "${repo_dir}/${dir}/"
          CHANGES_MADE=true
          continue
        fi
        if command -v rsync >/dev/null 2>&1; then
          if rsync -a --delete "$src/" "${repo_dir:?}/${dir}/"; then
            CHANGES_MADE=true
          fi
        else
          rm -rf "${repo_dir:?}/${dir}" || true
          if cp -R "$src" "${repo_dir:?}/${dir}"; then
            CHANGES_MADE=true
          fi
        fi
      elif [[ -L "$src" ]]; then
        log_info "Skipping symlinked agent dir: $src"
      fi
    done <<< "$important_dirs"

    log_ok "Synced agent: $id"
  done < <(selected_agent_ids)

  local shared_src shared_dest
  shared_src="${HOME}/.agents/skills"
  shared_dest="${REPO_ROOT}/agents/skills"
  if [[ -d "$shared_src" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      printf "${C_DIM}   would rsync: %s → %s${C_RESET}\n" "$shared_src/" "$shared_dest/"
      CHANGES_MADE=true
    else
      mkdir -p "$shared_dest"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$shared_src/" "$shared_dest/" && CHANGES_MADE=true
      else
        rm -rf "${shared_dest:?}" || true
        cp -R "$shared_src" "$shared_dest" && CHANGES_MADE=true
      fi
      log_ok "Synced shared agent skills"
    fi
  fi

  shared_src="${HOME}/.agents/agent-docs"
  shared_dest="${REPO_ROOT}/agents/agent-docs"
  if [[ -d "$shared_src" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      printf "${C_DIM}   would rsync: %s → %s${C_RESET}\n" "$shared_src/" "$shared_dest/"
      CHANGES_MADE=true
    else
      mkdir -p "$shared_dest"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$shared_src/" "$shared_dest/" && CHANGES_MADE=true
      else
        rm -rf "${shared_dest:?}" || true
        cp -R "$shared_src" "$shared_dest" && CHANGES_MADE=true
      fi
      log_ok "Synced shared agent docs"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────
# 6. Sync dotfiles at repo root
# ─────────────────────────────────────────────────────────────

sync_dotfiles() {
  log_step "Syncing dotfiles"

  local file live_path repo_path
  for file in .zshrc .bashrc .bash_profile .gitconfig .tmux.conf .npmrc .ignore; do
    live_path="${HOME}/${file}"
    repo_path="${REPO_ROOT}/zsh/${file}"
    [[ "$file" == ".gitconfig" ]] && repo_path="${REPO_ROOT}/config/git/${file}"

    if [[ -f "$live_path" ]]; then
      if [[ ! -f "$repo_path" ]] || ! diff -q "$live_path" "$repo_path" >/dev/null 2>&1; then
        copy_file "$live_path" "$repo_path"
      fi
    fi
  done
}

# ─────────────────────────────────────────────────────────────
# 6. Diff summary
# ─────────────────────────────────────────────────────────────

show_diff() {
  if ! has_git; then
    log_warn "git not found, skipping diff summary"
    return
  fi

  if [[ ! -d "${REPO_ROOT}/.git" ]]; then
    log_warn "Not a git repository, skipping diff summary"
    return
  fi

  log_step "Diff summary"

  if [[ "$DRY_RUN" == true ]]; then
    log_info "Skipping git diff in dry-run mode"
    return
  fi

  local diff_stat
  diff_stat="$(cd "$REPO_ROOT" && git diff --stat 2>/dev/null || true)"
  if [[ -n "$diff_stat" ]]; then
    printf '%s\n' "$diff_stat"
  else
    log_info "No changes to show"
  fi
}

# ─────────────────────────────────────────────────────────────
# 7. Auto-commit
# ─────────────────────────────────────────────────────────────

auto_commit() {
  if [[ "$AUTO_COMMIT" == false ]]; then
    return
  fi

  if ! has_git; then
    log_warn "git not found, skipping auto-commit"
    return
  fi

  if [[ ! -d "${REPO_ROOT}/.git" ]]; then
    log_warn "Not a git repository, skipping auto-commit"
    return
  fi

  log_step "Auto-committing changes"

  if [[ "$DRY_RUN" == true ]]; then
    dry_warn "Would stage and commit changes"
    return
  fi

  if [[ "$CHANGES_MADE" == false ]]; then
    log_info "No changes to commit"
    return
  fi

  local msg
  msg="backup: sync machine state ($(date +%Y-%m-%d %H:%M))"

  if (cd "$REPO_ROOT" && git add -A && git commit -m "$msg" 2>/dev/null); then
    log_ok "Committed: $msg"
  else
    log_warn "Nothing to commit or commit failed"
  fi
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

log_step "dotfriend backup"
if [[ "$DRY_RUN" == true ]]; then
  log_warn "DRY-RUN mode: no changes will be made"
fi

sync_configs
sync_brewfile
sync_npm
sync_editor_extensions
sync_agents
sync_dotfiles
show_diff
auto_commit

log_step "Done"
if [[ "$CHANGES_MADE" == true ]]; then
  log_ok "Backup complete"
else
  log_info "No changes detected"
fi
