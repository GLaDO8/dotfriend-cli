#!/usr/bin/env bash
# Verify status/plan JSON contracts against a fake generated repo.
set -euo pipefail

PROJECT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
REAL_JQ="$(command -v jq)"

HOME_DIR="${TEST_DIR}/home"
REPO_DIR="${TEST_DIR}/dotfiles"
mkdir -p "$HOME_DIR/.cache/dotfriend" "$REPO_DIR/.dotfriend" "$REPO_DIR/zsh" "$HOME_DIR"

export HOME="$HOME_DIR"
export DOTFRIEND_CACHE_DIR="${HOME}/.cache/dotfriend"

cat > "${DOTFRIEND_CACHE_DIR}/last-sync.json" <<JSON
{"repo_dir":"${REPO_DIR}","last_sync":"2026-05-05T00:00:00Z"}
JSON

printf '# fake zshrc\n' > "${REPO_DIR}/zsh/.zshrc"
printf '# live zshrc\n' > "${HOME}/.zshrc"

cat > "${REPO_DIR}/.dotfriend/restore-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "generated_by": "dotfriend",
  "generated_at": "2026-05-05T00:00:00Z",
  "source_machine": {"hostname": "fake", "os": "darwin"},
  "items": [
    {
      "id": "dotfile:zshrc",
      "type": "dotfile",
      "restore_mode": "symlink",
      "repo_path": "zsh/.zshrc",
      "target_path": "~/.zshrc",
      "selected": true,
      "requires_approval": false
    },
    {
      "id": "config_dir:zed",
      "type": "config_dir",
      "restore_mode": "copy",
      "repo_path": "config/zed",
      "target_path": "~/.config/zed",
      "selected": true,
      "requires_approval": false
    }
  ],
  "manual_followups": []
}
JSON

cd "$TEST_DIR"

status_output="$("$PROJECT/dotfriend" status --json)"
printf '%s\n' "$status_output" | "$REAL_JQ" -e '.command == "status" and .status == "ok"' >/dev/null
printf '%s\n' "$status_output" | "$REAL_JQ" -e --arg repo "$REPO_DIR" '.data.managed_repo == $repo' >/dev/null
printf '%s\n' "$status_output" | "$REAL_JQ" -e '.data.manifest_found == true and .data.manifest_schema_version == 1' >/dev/null
printf '%s\n' "$status_output" | "$REAL_JQ" -e '.data.counts.items == 2' >/dev/null
printf '%s\n' "$status_output" | "$REAL_JQ" -e '.data.drift[] | select(.code == "missing_repo_source" and .item_id == "config_dir:zed")' >/dev/null
printf '%s\n' "$status_output" | "$REAL_JQ" -e '.data.drift[] | select(.code == "missing_live_target" and .item_id == "config_dir:zed")' >/dev/null

plan_output="$("$PROJECT/dotfriend" plan --json)"
printf '%s\n' "$plan_output" | "$REAL_JQ" -e '.command == "plan" and .status == "ok"' >/dev/null
printf '%s\n' "$plan_output" | "$REAL_JQ" -e '.data.planned_actions[] | select(.item_id == "config_dir:zed" and .reason == "missing_repo_source")' >/dev/null

legacy_repo="${TEST_DIR}/legacy-dotfiles"
mkdir -p "$legacy_repo"
cat > "${DOTFRIEND_CACHE_DIR}/last-sync.json" <<JSON
{"repo_dir":"${legacy_repo}","last_sync":"2026-05-05T00:00:00Z"}
JSON

legacy_output="$("$PROJECT/dotfriend" status --json)"
printf '%s\n' "$legacy_output" | "$REAL_JQ" -e '.status == "warning"' >/dev/null
printf '%s\n' "$legacy_output" | "$REAL_JQ" -e '.warnings[] | select(.code == "manifest_missing")' >/dev/null

printf 'status contract ok\n'
