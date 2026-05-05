#!/usr/bin/env bash
# Verify managed JSON and Markdown merge adapters.
set -euo pipefail

PROJECT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="${TEST_DIR}/home"
mkdir -p "${HOME}/.cursor" "${HOME}/.codex" "${TEST_DIR}/repo/agents/artifacts"

source "${PROJECT}/lib/merge-json.sh"
source "${PROJECT}/lib/merge-markdown.sh"

cat > "${HOME}/.cursor/mcp.json" <<'JSON'
{
  "mcpServers": {
    "personal": {"command": "personal-server"},
    "github": {
      "command": "old-github",
      "_managed_by": "dotfriend",
      "_dotfriend_artifact_id": "github-mcp"
    }
  }
}
JSON

cat > "${TEST_DIR}/repo/agents/artifacts/github-mcp.json" <<'JSON'
{"command":"github-mcp-server","env":{"GITHUB_TOKEN":"${GITHUB_TOKEN}"}}
JSON

merge_json_apply \
  --source "${TEST_DIR}/repo/agents/artifacts/github-mcp.json" \
  --target "${HOME}/.cursor/mcp.json" \
  --json-path "mcpServers.github" \
  --artifact-id "github-mcp" \
  --approved

jq -e '.mcpServers.personal.command == "personal-server"' "${HOME}/.cursor/mcp.json" >/dev/null
jq -e '.mcpServers.github.command == "github-mcp-server"' "${HOME}/.cursor/mcp.json" >/dev/null
jq -e '.mcpServers.github._managed_by == "dotfriend" and .mcpServers.github._dotfriend_artifact_id == "github-mcp"' "${HOME}/.cursor/mcp.json" >/dev/null

cat > "${TEST_DIR}/repo/agents/artifacts/github-mcp.json" <<'JSON'
{"command":"github-mcp-server-v2","args":["stdio"]}
JSON
merge_json_apply \
  --source "${TEST_DIR}/repo/agents/artifacts/github-mcp.json" \
  --target "${HOME}/.cursor/mcp.json" \
  --json-path "mcpServers.github" \
  --artifact-id "github-mcp" \
  --approved
jq -e '.mcpServers.personal.command == "personal-server"' "${HOME}/.cursor/mcp.json" >/dev/null
jq -e '.mcpServers.github.command == "github-mcp-server-v2" and .mcpServers.github.args[0] == "stdio"' "${HOME}/.cursor/mcp.json" >/dev/null

printf '{bad json\n' > "${HOME}/.cursor/bad.json"
if merge_json_apply \
  --source "${TEST_DIR}/repo/agents/artifacts/github-mcp.json" \
  --target "${HOME}/.cursor/bad.json" \
  --json-path "mcpServers.github" \
  --artifact-id "github-mcp" \
  --approved >/dev/null 2>&1; then
  printf 'invalid target JSON was accepted\n' >&2
  exit 1
fi

cat > "${HOME}/.cursor/personal.json" <<'JSON'
{"mcpServers":{"github":{"command":"personal-github"}}}
JSON
if merge_json_apply \
  --source "${TEST_DIR}/repo/agents/artifacts/github-mcp.json" \
  --target "${HOME}/.cursor/personal.json" \
  --json-path "mcpServers.github" \
  --artifact-id "github-mcp" >/dev/null 2>&1; then
  printf 'unmanaged JSON entry was replaced without approval\n' >&2
  exit 1
fi

cat > "${HOME}/.cursor/full.json" <<'JSON'
{"personal":true}
JSON
merge_json_apply \
  --source "${TEST_DIR}/repo/agents/artifacts/github-mcp.json" \
  --target "${HOME}/.cursor/full.json" \
  --json-path "ignored" \
  --artifact-id "github-mcp" \
  --ownership "managed_partial" >/dev/null
jq -e '.personal == true and .ignored.command == "github-mcp-server-v2"' "${HOME}/.cursor/full.json" >/dev/null
merge_json_apply \
  --source "${TEST_DIR}/repo/agents/artifacts/github-mcp.json" \
  --target "${HOME}/.cursor/full.json" \
  --json-path "ignored" \
  --artifact-id "github-mcp" \
  --ownership "dotfriend_full_file"
jq -e '.command == "github-mcp-server-v2"' "${HOME}/.cursor/full.json" >/dev/null

cat > "${HOME}/.codex/AGENTS.md" <<'MD'
# User heading

Personal instruction.
<!-- dotfriend:start id="global-instructions" -->
old managed content
<!-- dotfriend:end id="global-instructions" -->

Personal footer.
MD
printf 'new managed content\n' > "${TEST_DIR}/repo/agents/artifacts/global-instructions.md"

merge_markdown_apply \
  --source "${TEST_DIR}/repo/agents/artifacts/global-instructions.md" \
  --target "${HOME}/.codex/AGENTS.md" \
  --artifact-id "global-instructions"

grep -q 'Personal instruction.' "${HOME}/.codex/AGENTS.md"
grep -q 'new managed content' "${HOME}/.codex/AGENTS.md"
grep -q 'Personal footer.' "${HOME}/.codex/AGENTS.md"

cat > "${HOME}/.codex/dupe.md" <<'MD'
<!-- dotfriend:start id="global-instructions" -->
a
<!-- dotfriend:end id="global-instructions" -->
<!-- dotfriend:start id="global-instructions" -->
b
<!-- dotfriend:end id="global-instructions" -->
MD
if merge_markdown_apply \
  --source "${TEST_DIR}/repo/agents/artifacts/global-instructions.md" \
  --target "${HOME}/.codex/dupe.md" \
  --artifact-id "global-instructions" >/dev/null 2>&1; then
  printf 'duplicate Markdown managed blocks were accepted\n' >&2
  exit 1
fi

printf 'managed merge ok\n'
