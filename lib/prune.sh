#!/usr/bin/env bash
# dotfriend — shared generation/sync prune rules
# shellcheck shell=bash

set -euo pipefail

dotfriend_prune_rsync_patterns() {
  local filter_profile="${1:-config}"
  cat <<'EOF'
.git/
.gitignore
node_modules/
bower_components/
jspm_packages/
.next/
dist/
build/
.build/
coverage/
vendor/
Pods/
.gradle/
__pycache__/
.pytest_cache/
.mypy_cache/
.ruff_cache/
.tox/
virtenv/
venv/
.venv/
virtualenv/
gcloud/
.gcloud/
.cache/
cache/
Cache/
Caches/
.npm/
.pnpm-store/
.yarn/
tmp/
temp/
logs/
log/
marketplace/
marketplaces/
plugin-marketplace/
plugin-marketplaces/
sessions/
archived_sessions/
generated/
.generated/
generated_images/
sqlite/
.turbo/
.parcel-cache/
.vite/
.nuxt/
.svelte-kit/
.astro/
EOF
  if [[ "$filter_profile" == "config" ]]; then
    printf '%s\n' 'extensions/'
  fi
}

dotfriend_find_files_filtered() {
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

dotfriend_remove_pruned_paths() {
  local root="$1" filter_profile="${2:-config}"
  if [[ "$filter_profile" == "config" ]]; then
    find "$root" \
      \( -name '.git' -o -name 'node_modules' -o -name 'bower_components' -o -name 'jspm_packages' -o -name '.next' -o -name 'dist' -o -name 'build' -o -name '.build' -o -name 'coverage' -o -name 'vendor' -o -name 'Pods' -o -name '.gradle' -o -name '__pycache__' -o -name '.pytest_cache' -o -name '.mypy_cache' -o -name '.ruff_cache' -o -name '.tox' -o -name 'virtenv' -o -name 'venv' -o -name '.venv' -o -name 'virtualenv' -o -name 'gcloud' -o -name '.gcloud' -o -name '.cache' -o -name 'cache' -o -name 'Cache' -o -name 'Caches' -o -name '.npm' -o -name '.pnpm-store' -o -name '.yarn' -o -name 'tmp' -o -name 'temp' -o -name 'logs' -o -name 'log' -o -name 'marketplace' -o -name 'marketplaces' -o -name 'plugin-marketplace' -o -name 'plugin-marketplaces' -o -name 'sessions' -o -name 'archived_sessions' -o -name 'generated' -o -name '.generated' -o -name 'generated_images' -o -name 'sqlite' -o -name '.turbo' -o -name '.parcel-cache' -o -name '.vite' -o -name '.nuxt' -o -name '.svelte-kit' -o -name '.astro' -o -name 'extensions' \) \
      -prune -exec rm -rf {} + 2>/dev/null || true
  else
    find "$root" \
      \( -name '.git' -o -name 'node_modules' -o -name 'bower_components' -o -name 'jspm_packages' -o -name '.next' -o -name 'dist' -o -name 'build' -o -name '.build' -o -name 'coverage' -o -name 'vendor' -o -name 'Pods' -o -name '.gradle' -o -name '__pycache__' -o -name '.pytest_cache' -o -name '.mypy_cache' -o -name '.ruff_cache' -o -name '.tox' -o -name 'virtenv' -o -name 'venv' -o -name '.venv' -o -name 'virtualenv' -o -name 'gcloud' -o -name '.gcloud' -o -name '.cache' -o -name 'cache' -o -name 'Cache' -o -name 'Caches' -o -name '.npm' -o -name '.pnpm-store' -o -name '.yarn' -o -name 'tmp' -o -name 'temp' -o -name 'logs' -o -name 'log' -o -name 'marketplace' -o -name 'marketplaces' -o -name 'plugin-marketplace' -o -name 'plugin-marketplaces' -o -name 'sessions' -o -name 'archived_sessions' -o -name 'generated' -o -name '.generated' -o -name 'generated_images' -o -name 'sqlite' -o -name '.turbo' -o -name '.parcel-cache' -o -name '.vite' -o -name '.nuxt' -o -name '.svelte-kit' -o -name '.astro' \) \
      -prune -exec rm -rf {} + 2>/dev/null || true
  fi
  find "$root" -name '.gitignore' -type f -delete 2>/dev/null || true
}
