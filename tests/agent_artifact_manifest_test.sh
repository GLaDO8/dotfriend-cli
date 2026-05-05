#!/usr/bin/env bash
# Verify generated agent artifact manifest and agent backend commands.
set -euo pipefail

PROJECT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
REAL_JQ="$(command -v jq)"

export HOME="${TEST_DIR}/home"
export DOTFRIEND_CACHE_DIR="${HOME}/.cache/dotfriend"
FAKE_BIN="${TEST_DIR}/bin"
mkdir -p "$DOTFRIEND_CACHE_DIR" "$FAKE_BIN" "${HOME}/.cursor" "${HOME}/.codex" "${HOME}/.agents/skills/demo" "${HOME}/.agents/agent-docs"

cat > "${FAKE_BIN}/git" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "rev-parse --show-toplevel") exit 1 ;;
  "init ") exit 0 ;;
  "add .") exit 0 ;;
  "commit -m") exit 0 ;;
esac
exit 0
SH

cat > "${FAKE_BIN}/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH

for cmd in gum brew npm mas code cursor dockutil; do
  cat > "${FAKE_BIN}/${cmd}" <<'SH'
#!/usr/bin/env bash
exit 0
SH
done
cat > "${FAKE_BIN}/jq" <<SH
#!/usr/bin/env bash
exec "${REAL_JQ}" "\$@"
SH
chmod +x "${FAKE_BIN}"/*
export PATH="${FAKE_BIN}:/bin:/usr/bin:/usr/sbin:/sbin"

cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'JSON'
{
  "apps": [],
  "agents": [{"id":"cursor","name":"Cursor"},{"id":"codex","name":"OpenAI Codex"}],
  "formulae": [],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [],
  "config_dirs": [],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "agent-repo", "private": true}
}
JSON

cat > "${HOME}/.cursor/mcp.json" <<'JSON'
{"mcpServers":{"github":{"command":"github-mcp-server","env":{"GITHUB_TOKEN":"ghp_should_not_be_in_manifest"}}}
JSON
printf '# Codex instructions\n' > "${HOME}/.codex/AGENTS.md"
printf 'skill\n' > "${HOME}/.agents/skills/demo/SKILL.md"
printf 'docs\n' > "${HOME}/.agents/agent-docs/readme.md"

source "${PROJECT}/lib/common.sh"
source "${PROJECT}/lib/generate.sh"

repo_dir="${TEST_DIR}/out"
generate_repo "$repo_dir" false >/dev/null 2>&1

artifacts="${repo_dir}/.dotfriend/agent-artifacts.json"
[[ -f "$artifacts" ]]
"$REAL_JQ" -e '.schema_version == 1 and (.artifacts | length > 0)' "$artifacts" >/dev/null
"$REAL_JQ" -e '.artifacts[] | select(.id == "cursor:mcp.json" and .install.strategy == "managed_json_merge")' "$artifacts" >/dev/null
"$REAL_JQ" -e '.artifacts[] | select(.id == "codex:AGENTS.md" and .install.strategy == "managed_markdown_block")' "$artifacts" >/dev/null
if grep -q 'ghp_should_not_be_in_manifest' "$artifacts"; then
  printf 'secret value copied into agent artifact manifest\n' >&2
  exit 1
fi

cat > "${DOTFRIEND_CACHE_DIR}/last-sync.json" <<JSON
{"repo_dir":"${repo_dir}","last_sync":"2026-05-05T00:00:00Z"}
JSON

status_output="$("${PROJECT}/dotfriend" agent status --json)"
printf '%s\n' "$status_output" | "$REAL_JQ" -e '.command == "agent status" and .status == "ok"' >/dev/null
printf '%s\n' "$status_output" | "$REAL_JQ" -e '.data.artifact_count > 0 and (.data.selected_tools | index("cursor"))' >/dev/null

check_output="$("${PROJECT}/dotfriend" agent check --json)"
printf '%s\n' "$check_output" | "$REAL_JQ" -e '.command == "agent check" and .status == "ok" and .data.valid == true' >/dev/null

sync_output="$("${PROJECT}/dotfriend" agent sync --dry-run --json)"
printf '%s\n' "$sync_output" | "$REAL_JQ" -e '.command == "agent sync" and .status == "ok" and (.data.planned_writes | type == "array")' >/dev/null

before="$(find "$HOME" -type f -print | sort)"
suggest_output="$("${PROJECT}/dotfriend" agent suggest --json)"
after="$(find "$HOME" -type f -print | sort)"
[[ "$before" == "$after" ]] || { printf 'agent suggest wrote to HOME\n' >&2; exit 1; }
printf '%s\n' "$suggest_output" | "$REAL_JQ" -e '.command == "agent suggest" and (.data.proposed_artifacts[] | select(.id == "cursor:mcp.json"))' >/dev/null

bad_artifacts="${repo_dir}/.dotfriend/agent-artifacts.json"
"$REAL_JQ" '.artifacts[0].install.strategy = "unsafe_replace"' "$bad_artifacts" > "${bad_artifacts}.tmp"
mv "${bad_artifacts}.tmp" "$bad_artifacts"
if "${PROJECT}/dotfriend" agent check --json | "$REAL_JQ" -e '.status == "ok"' >/dev/null; then
  printf 'agent check accepted invalid artifact schema\n' >&2
  exit 1
fi

printf 'agent artifact manifest ok\n'
