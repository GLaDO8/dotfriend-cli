#!/usr/bin/env bash
# Verify structured discovery cache and backend discovery output contracts.
set -euo pipefail

PROJECT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
REAL_JQ="$(command -v jq)"

FAKE_BIN="${TEST_DIR}/bin"
HOME_DIR="${TEST_DIR}/home"
APP_DIR="${TEST_DIR}/Applications"
mkdir -p "$FAKE_BIN" "$HOME_DIR/.cache/dotfriend" "$HOME_DIR/.config/zed" "$HOME_DIR/.codex" "$APP_DIR/Cursor.app"

cat > "${HOME_DIR}/.zshrc" <<'EOF'
# fake zshrc
EOF

cat > "${FAKE_BIN}/brew" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  leaves)
    printf 'git\n'
    ;;
  desc)
    shift
    printf 'git: Distributed revision control system\n'
    ;;
  list)
    if [[ "${2:-}" == "--cask" ]]; then
      printf 'cursor\n'
    fi
    ;;
  tap)
    printf 'homebrew/cask\n'
    ;;
esac
SH

cat > "${FAKE_BIN}/npm" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
  cat <<'JSON'
{"dependencies":{"typescript":{"version":"5.9.0"},"@openai/codex":{"version":"1.0.0"}}}
JSON
fi
SH

chmod +x "${FAKE_BIN}"/*

export HOME="$HOME_DIR"
export DOTFRIEND_CACHE_DIR="${HOME}/.cache/dotfriend"
export DOTFRIEND_APP_SEARCH_DIRS="$APP_DIR"
export GUM_AVAILABLE=false
export PATH="${FAKE_BIN}:$(dirname "$REAL_JQ"):/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"

cat > "${DOTFRIEND_CACHE_DIR}/cask-api.json" <<'JSON'
[
  {
    "token": "cursor",
    "name": ["Cursor"],
    "artifacts": [{"app": ["Cursor.app"]}]
  }
]
JSON

cd "$PROJECT"

json_output="$(./dotfriend discover --json)"
printf '%s\n' "$json_output" | "$REAL_JQ" -e '.command == "discover" and .status == "ok"' >/dev/null
printf '%s\n' "$json_output" | "$REAL_JQ" -e '.data.discovery.schema_version == 2' >/dev/null
printf '%s\n' "$json_output" | "$REAL_JQ" -e '.data.discovery.agents | type == "array"' >/dev/null
printf '%s\n' "$json_output" | "$REAL_JQ" -e '.data.discovery.apps[] | select(.name == "Cursor" and .cask == "cursor" and .source == "cask")' >/dev/null
printf '%s\n' "$json_output" | "$REAL_JQ" -e '.data.discovery.formulae[] | select(.name == "git")' >/dev/null
printf '%s\n' "$json_output" | "$REAL_JQ" -e '.data.discovery.config_dirs[] | select(.name == "zed")' >/dev/null
printf '%s\n' "$json_output" | "$REAL_JQ" -e '.data.discovery.editors.cursor.settings_path == ""' >/dev/null

"$REAL_JQ" -e '.schema_version == 2 and (.agents | type == "array")' "${DOTFRIEND_CACHE_DIR}/discovery.json" >/dev/null

event_output="$(./dotfriend discover --events)"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  printf '%s\n' "$line" | "$REAL_JQ" -e '.contract_version == 1 and (.event | type == "string")' >/dev/null
done <<< "$event_output"
printf '%s\n' "$event_output" | "$REAL_JQ" -e 'select(.event == "job_started" and .job == "discover")' >/dev/null
printf '%s\n' "$event_output" | "$REAL_JQ" -e 'select(.event == "job_finished" and .status == "ok")' >/dev/null

tmp_cache="${DOTFRIEND_CACHE_DIR}/discovery.cached.json"
"$REAL_JQ" '.cached_only = true' "${DOTFRIEND_CACHE_DIR}/discovery.json" > "$tmp_cache"
mv "$tmp_cache" "${DOTFRIEND_CACHE_DIR}/discovery.json"
cached_output="$(./dotfriend discover --json --cached)"
printf '%s\n' "$cached_output" | "$REAL_JQ" -e '.command == "discover" and .status == "ok"' >/dev/null
printf '%s\n' "$cached_output" | "$REAL_JQ" -e '.data.discovery.cached_only == true' >/dev/null

source "$PROJECT/lib/wizard.sh"
v2_agents=()
while IFS= read -r line; do
  v2_agents+=("$line")
done < <(discovery_cache_lines agents "${DOTFRIEND_CACHE_DIR}/discovery.json")
printf '%s\n' "${v2_agents[@]}" | grep -q '^codex|OpenAI Codex|'

legacy_cache="${TEST_DIR}/legacy-discovery.json"
cat > "$legacy_cache" <<'JSON'
{
  "apps": "Cursor|cask:cursor",
  "agents": "codex|OpenAI Codex|~/.codex|found|1",
  "formulae": "git|Distributed revision control system",
  "config_dirs": "zed",
  "vscode": "settings:missing",
  "cursor": "settings:/tmp/Cursor/settings.json"
}
JSON
legacy_agents=()
while IFS= read -r line; do
  legacy_agents+=("$line")
done < <(discovery_cache_lines agents "$legacy_cache")
[[ "${legacy_agents[0]}" == "codex|OpenAI Codex|~/.codex|found|1" ]]
[[ "$(discovery_editor_settings_path cursor "$legacy_cache")" == "settings:/tmp/Cursor/settings.json" ]]

printf 'discovery contract ok\n'
