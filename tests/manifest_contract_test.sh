#!/usr/bin/env bash
# Verify generated restore manifest contract.
set -euo pipefail

PROJECT_ROOT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="${TEST_DIR}/home"
export DOTFRIEND_CACHE_DIR="${HOME}/.cache/dotfriend"
mkdir -p "$DOTFRIEND_CACHE_DIR" "${HOME}/.codex" "${HOME}/.agents/skills/demo" "${HOME}/.agents/agent-docs"

cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'JSON'
{
  "apps": [],
  "agents": [{"id":"codex","name":"OpenAI Codex"}],
  "formulae": [],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [".zshrc", ".gitconfig"],
  "config_dirs": [],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "macos_defaults": [
    {
      "id": "dock.orientation",
      "domain": "com.apple.dock",
      "key": "orientation",
      "scope": "user",
      "value_type": "string",
      "value": "left",
      "risk": "safe",
      "restart": ["Dock"]
    }
  ],
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "manifest-repo", "private": true}
}
JSON

printf '# zshrc\n' > "${HOME}/.zshrc"
printf '[user]\nname = Test\n' > "${HOME}/.gitconfig"
printf '# AGENTS\n' > "${HOME}/.codex/AGENTS.md"
printf 'skill\n' > "${HOME}/.agents/skills/demo/SKILL.md"
printf 'docs\n' > "${HOME}/.agents/agent-docs/readme.md"

source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/generate.sh"

repo_dir="${TEST_DIR}/out"
generate_repo "$repo_dir" false >/dev/null 2>&1

manifest="${repo_dir}/.dotfriend/restore-manifest.json"
[[ -f "$manifest" ]]

jq -e '.schema_version == 1' "$manifest" >/dev/null
jq -e '.items[] | select(.id == "dotfile:zshrc" and .repo_path == "zsh/.zshrc" and .restore_mode == "symlink")' "$manifest" >/dev/null
jq -e '.items[] | select(.id == "dotfile:gitconfig" and .repo_path == "config/git/.gitconfig")' "$manifest" >/dev/null
jq -e '.items[] | select(.id == "agent_config:codex" and .target_path == "~/.codex")' "$manifest" >/dev/null
jq -e '.items[] | select(.id == "agent_shared_store:skills" and .repo_path == "agents/skills")' "$manifest" >/dev/null
jq -e '.items[] | select(.id == "agent_shared_store:agent-docs" and .repo_path == "agents/agent-docs")' "$manifest" >/dev/null
jq -e '.items[] | select(.id == "macos_defaults:selected" and .restore_mode == "defaults_import" and .repo_path == "macos/defaults.json")' "$manifest" >/dev/null

source "${PROJECT_ROOT}/lib/manifest.sh"
manifest_validate "$manifest"

bad_manifest="${TEST_DIR}/bad-manifest.json"
cp "$manifest" "$bad_manifest"
jq '.items[0].repo_path = "../bad"' "$bad_manifest" > "${bad_manifest}.tmp"
mv "${bad_manifest}.tmp" "$bad_manifest"
if manifest_validate "$bad_manifest" >/dev/null 2>&1; then
  printf 'unsafe repo_path was accepted\n' >&2
  exit 1
fi

printf 'manifest contract ok\n'
