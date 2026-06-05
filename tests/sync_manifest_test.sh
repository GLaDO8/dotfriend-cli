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
  "$HOME_DIR/.codex/cache" \
  "$HOME_DIR/.config/zed" \
  "$HOME_DIR/.config/unselected" \
  "$REPO_DIR/.dotfriend" \
  "$REPO_DIR/codex" \
  "$REPO_DIR/config/zed" \
  "$FAKE_BIN"

export HOME="$HOME_DIR"
export DOTFRIEND_CACHE_DIR="${HOME}/.cache/dotfriend"
export FIND_ROOT_MARKER="${TEST_DIR}/find-root.marker"
export DIFF_CALL_MARKER="${TEST_DIR}/diff-calls.log"
export PATH="${FAKE_BIN}:$(dirname "$REAL_JQ"):/usr/bin:/bin:/usr/sbin:/sbin"

cat > "${FAKE_BIN}/git" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "rev-parse --show-toplevel") exit 1 ;;
  "diff --stat") printf ' config/zed/settings.json | 2 +-\n'; exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "${FAKE_BIN}/git"

cat > "${FAKE_BIN}/gum" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  pager)
    printf 'gum pager must not be used for app event streams\n' >&2
    exit 42
    ;;
  style)
    shift
    last=""
    for arg in "$@"; do last="$arg"; done
    printf '%s\n' "$last"
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "${FAKE_BIN}/gum"

cat > "${FAKE_BIN}/find" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "${HOME}/.codex" ]]; then
  printf 'root codex find invoked\n' >> "${FIND_ROOT_MARKER:?}"
fi
exec /usr/bin/find "$@"
SH
chmod +x "${FAKE_BIN}/find"

cat > "${FAKE_BIN}/diff" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DIFF_CALL_MARKER:?}"
exec /usr/bin/diff "$@"
SH
chmod +x "${FAKE_BIN}/diff"

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
mkdir -p "${HOME_DIR}/.config/zed/extensions"
mkdir -p "${HOME_DIR}/.config/zed/gcloud" "${HOME_DIR}/.config/zed/virtenv" "${HOME_DIR}/.config/zed/marketplace" "${HOME_DIR}/.config/zed/.turbo" "${HOME_DIR}/.config/zed/vendor" "${HOME_DIR}/.config/zed/logs"
printf 'vendored extension\n' > "${HOME_DIR}/.config/zed/extensions/cache.txt"
printf 'gcloud cache\n' > "${HOME_DIR}/.config/zed/gcloud/cache.db"
printf 'python runtime\n' > "${HOME_DIR}/.config/zed/virtenv/runtime.py"
printf 'market cache\n' > "${HOME_DIR}/.config/zed/marketplace/list.json"
printf 'generated cache\n' > "${HOME_DIR}/.config/zed/.turbo/cache.bin"
printf 'dependency tree\n' > "${HOME_DIR}/.config/zed/vendor/lib.js"
printf 'log line\n' > "${HOME_DIR}/.config/zed/logs/run.log"
printf '# AGENTS\n' > "${HOME_DIR}/.codex/AGENTS.md"
mkdir -p "${HOME_DIR}/.codex/plugins/custom" "${HOME_DIR}/.codex/plugins/marketplace" "${HOME_DIR}/.codex/plugins/cache"
printf 'custom plugin\n' > "${HOME_DIR}/.codex/plugins/custom/plugin.json"
printf 'marketplace plugin\n' > "${HOME_DIR}/.codex/plugins/marketplace/index.json"
printf 'plugin cache\n' > "${HOME_DIR}/.codex/plugins/cache/index.json"
printf 'session cache\n' > "${HOME_DIR}/.codex/cache/session.log"
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
    },
    {
      "id": "agent_config:codex",
      "type": "agent_config",
      "restore_mode": "rsync",
      "repo_path": "codex",
      "target_path": "~/.codex",
      "selected": true,
      "requires_approval": false,
      "metadata": {
        "important_files": ["AGENTS.md"],
        "important_dirs": ["agent-docs", "plugins"],
        "symlinks_to_skip": []
      }
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
if [[ -e "${REPO_DIR}/config/zed/extensions/cache.txt" ]]; then
  printf 'dry-run copied filtered extension cache\n' >&2
  exit 1
fi
for filtered_path in \
  "${REPO_DIR}/config/zed/gcloud/cache.db" \
  "${REPO_DIR}/config/zed/virtenv/runtime.py" \
  "${REPO_DIR}/config/zed/marketplace/list.json" \
  "${REPO_DIR}/config/zed/.turbo/cache.bin" \
  "${REPO_DIR}/config/zed/vendor/lib.js" \
  "${REPO_DIR}/config/zed/logs/run.log"
do
  if [[ -e "$filtered_path" ]]; then
    printf 'dry-run copied filtered runtime path: %s\n' "$filtered_path" >&2
    exit 1
  fi
done
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
"$REAL_JQ" -s -e '.[] | select(.event == "item_finished" and .item_id == "config_dir:zed" and (.elapsed_seconds | type == "number"))' "$events_stdout" >/dev/null
if grep -v '^{.*}$' "$events_stdout" >/dev/null; then
  printf 'sync --events stdout contained non-json output\n' >&2
  exit 1
fi

mkdir -p "${REPO_DIR}/.git"
printf 'live changed again\n' > "${HOME_DIR}/.config/zed/settings.json"
rm -f "$FIND_ROOT_MARKER"
app_events_stdout="${TEST_DIR}/app-events.stdout"
app_events_stderr="${TEST_DIR}/app-events.stderr"
"${PROJECT}/dotfriend" --no-bootstrap sync --quick --no-commit --events >"$app_events_stdout" 2>"$app_events_stderr"
"$REAL_JQ" -s -e '.[] | select(.event == "job_finished")' "$app_events_stdout" >/dev/null
if grep -q 'gum pager must not be used' "$app_events_stderr"; then
  printf 'app event sync invoked interactive pager\n' >&2
  exit 1
fi
if grep -v '^{.*}$' "$app_events_stdout" >/dev/null; then
  printf 'app event sync stdout contained non-json output\n' >&2
  exit 1
fi
if [[ -f "$FIND_ROOT_MARKER" ]]; then
  printf 'app event sync scanned full codex root\n' >&2
  exit 1
fi
if [[ "$(cat "${REPO_DIR}/codex/AGENTS.md")" != "# AGENTS" ]]; then
  printf 'app event sync did not copy allowlisted codex file\n' >&2
  exit 1
fi
if [[ "$(cat "${REPO_DIR}/codex/plugins/custom/plugin.json")" != "custom plugin" ]]; then
  printf 'app event sync did not copy allowlisted custom plugin\n' >&2
  exit 1
fi
if [[ -e "${REPO_DIR}/codex/cache/session.log" ]]; then
  printf 'app event sync copied unallowlisted codex cache\n' >&2
  exit 1
fi
if [[ -e "${REPO_DIR}/codex/plugins/marketplace/index.json" || -e "${REPO_DIR}/codex/plugins/cache/index.json" ]]; then
  printf 'app event sync copied plugin marketplace/cache data\n' >&2
  exit 1
fi
if [[ -e "${REPO_DIR}/config/zed/extensions/cache.txt" ]]; then
  printf 'app event sync copied filtered extension cache\n' >&2
  exit 1
fi
for filtered_path in \
  "${REPO_DIR}/config/zed/gcloud/cache.db" \
  "${REPO_DIR}/config/zed/virtenv/runtime.py" \
  "${REPO_DIR}/config/zed/marketplace/list.json" \
  "${REPO_DIR}/config/zed/.turbo/cache.bin" \
  "${REPO_DIR}/config/zed/vendor/lib.js" \
  "${REPO_DIR}/config/zed/logs/run.log"
do
  if [[ -e "$filtered_path" ]]; then
    printf 'app event sync copied filtered runtime path: %s\n' "$filtered_path" >&2
    exit 1
  fi
done

rm -f "$DIFF_CALL_MARKER"
noop_events_stdout="${TEST_DIR}/noop-events.stdout"
"${PROJECT}/dotfriend" --no-bootstrap sync --quick --no-commit --events >"$noop_events_stdout" 2>"${TEST_DIR}/noop-events.stderr"
"$REAL_JQ" -s -e '.[] | select(.event == "job_finished")' "$noop_events_stdout" >/dev/null
if [[ -s "$DIFF_CALL_MARKER" ]]; then
  printf 'no-op app event sync launched per-file diff checks:\n' >&2
  cat "$DIFF_CALL_MARKER" >&2
  exit 1
fi
rm -rf "${REPO_DIR}/.git"

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
