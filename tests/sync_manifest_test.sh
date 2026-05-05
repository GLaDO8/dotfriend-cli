#!/usr/bin/env bash
# Verify manifest-aware sync and sync event stream behavior.
set -euo pipefail

PROJECT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
REAL_JQ="$(command -v jq)"

HOME_DIR="${TEST_DIR}/home"
REPO_DIR="${TEST_DIR}/dotfiles"
FAKE_BIN="${TEST_DIR}/bin"
mkdir -p \
  "$HOME_DIR/.cache/dotfriend" \
  "$HOME_DIR/.config/zed" \
  "$HOME_DIR/.config/unselected" \
  "$REPO_DIR/.dotfriend" \
  "$REPO_DIR/config/zed" \
  "$FAKE_BIN"

export HOME="$HOME_DIR"
export DOTFRIEND_CACHE_DIR="${HOME}/.cache/dotfriend"
export PATH="${FAKE_BIN}:$(dirname "$REAL_JQ"):/usr/bin:/bin:/usr/sbin:/sbin"

cat > "${FAKE_BIN}/git" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "rev-parse --show-toplevel") exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "${FAKE_BIN}/git"

cat > "${DOTFRIEND_CACHE_DIR}/last-sync.json" <<JSON
{"repo_dir":"${REPO_DIR}","last_sync":"2026-05-05T00:00:00Z"}
JSON

cat > "${DOTFRIEND_CACHE_DIR}/discovery.json" <<'JSON'
{
  "schema_version": 2,
  "config_dirs": [
    {"name": "zed", "path": "~/.config/zed"},
    {"name": "unselected", "path": "~/.config/unselected"}
  ]
}
JSON

printf 'live enabled\n' > "${HOME_DIR}/.config/zed/settings.json"
printf 'repo stale\n' > "${REPO_DIR}/config/zed/settings.json"
printf 'repo only\n' > "${REPO_DIR}/config/zed/repo-only.json"
printf 'do not copy\n' > "${HOME_DIR}/.config/unselected/settings.json"

cat > "${REPO_DIR}/.dotfriend/restore-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "generated_by": "dotfriend",
  "generated_at": "2026-05-05T00:00:00Z",
  "source_machine": {"hostname": "fake", "os": "darwin"},
  "items": [
    {
      "id": "config_dir:zed",
      "type": "config_dir",
      "restore_mode": "copy",
      "repo_path": "config/zed",
      "target_path": "~/.config/zed",
      "selected": true,
      "requires_approval": false
    },
    {
      "id": "config_dir:missing",
      "type": "config_dir",
      "restore_mode": "copy",
      "repo_path": "config/missing",
      "target_path": "~/.config/missing",
      "selected": true,
      "requires_approval": false
    }
  ],
  "manual_followups": []
}
JSON

cd "$TEST_DIR"

dry_stdout="${TEST_DIR}/dry.stdout"
dry_stderr="${TEST_DIR}/dry.stderr"
"${PROJECT}/dotfriend" --no-bootstrap sync --dry-run --quick >"$dry_stdout" 2>"$dry_stderr"

if [[ "$(cat "${REPO_DIR}/config/zed/settings.json")" != "repo stale" ]]; then
  printf 'dry-run mutated manifest-owned repo file\n' >&2
  exit 1
fi
if [[ -e "${REPO_DIR}/config/unselected/settings.json" ]]; then
  printf 'dry-run copied unselected config dir\n' >&2
  exit 1
fi
grep -q 'Manifest sync:' "$dry_stdout"

events_stdout="${TEST_DIR}/events.stdout"
events_stderr="${TEST_DIR}/events.stderr"
"${PROJECT}/dotfriend" --no-bootstrap sync --dry-run --quick --events >"$events_stdout" 2>"$events_stderr"

"$REAL_JQ" -e . "$events_stdout" >/dev/null
"$REAL_JQ" -s -e 'all(.[]; has("contract_version") and has("event"))' "$events_stdout" >/dev/null
"$REAL_JQ" -s -e 'map(.event) | index("job_started") and index("step_started") and index("item_changed") and index("step_finished") and index("job_finished")' "$events_stdout" >/dev/null
"$REAL_JQ" -s -e '.[] | select(.event == "item_changed" and .code == "missing_live_target" and .item_id == "config_dir:missing")' "$events_stdout" >/dev/null
"$REAL_JQ" -s -e '.[] | select(.event == "item_changed" and .code == "changed_live_file" and .repo_path == "config/zed/settings.json")' "$events_stdout" >/dev/null
"$REAL_JQ" -s -e '.[] | select(.event == "item_changed" and .code == "changed_repo_file" and .repo_path == "config/zed/repo-only.json")' "$events_stdout" >/dev/null
"$REAL_JQ" -s -e '.[] | select(.event == "item_changed" and .code == "untracked_discovered_config" and .item_id == "config_dir:unselected")' "$events_stdout" >/dev/null
if grep -v '^{.*}$' "$events_stdout" >/dev/null; then
  printf 'sync --events stdout contained non-json output\n' >&2
  exit 1
fi

legacy_repo="${TEST_DIR}/legacy-dotfiles"
mkdir -p "$legacy_repo/config/zed"
printf 'legacy repo stale\n' > "${legacy_repo}/config/zed/settings.json"
cat > "${DOTFRIEND_CACHE_DIR}/last-sync.json" <<JSON
{"repo_dir":"${legacy_repo}","last_sync":"2026-05-05T00:00:00Z"}
JSON

legacy_events="${TEST_DIR}/legacy-events.stdout"
"${PROJECT}/dotfriend" --no-bootstrap sync --dry-run --quick --events >"$legacy_events" 2>"${TEST_DIR}/legacy-events.stderr"
"$REAL_JQ" -s -e '.[] | select(.event == "warning" and .code == "manifest_missing")' "$legacy_events" >/dev/null
"$REAL_JQ" -s -e '.[] | select(.event == "job_finished" and .status == "warning")' "$legacy_events" >/dev/null

printf 'sync manifest contract ok\n'
