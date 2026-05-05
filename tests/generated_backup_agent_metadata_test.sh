#!/usr/bin/env bash
# Verify generated backup uses agent metadata paths instead of ~/.<id> guesses.
set -euo pipefail

PROJECT_ROOT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="${TEST_DIR}/home"
repo="${TEST_DIR}/repo"
fake_bin="${TEST_DIR}/bin"
mkdir -p "$repo/.dotfriend" "$repo/scripts" "$HOME/.config/zed" "$HOME/.config/github-copilot" "$HOME/.agents/skills/demo" "$fake_bin"

cp "${PROJECT_ROOT}/templates/scripts/backup.sh" "$repo/scripts/backup.sh"
chmod +x "$repo/scripts/backup.sh"
cp "${PROJECT_ROOT}/lib/agent-tools.json" "$repo/.dotfriend/agent-tools.json"

cat > "$repo/.dotfriend/selections.json" <<'JSON'
{
  "agents": [
    {"id":"zed","name":"Zed"},
    {"id":"copilot","name":"GitHub Copilot"}
  ]
}
JSON

printf '{"zed":true}\n' > "$HOME/.config/zed/settings.json"
printf '{"copilot":true}\n' > "$HOME/.config/github-copilot/apps.json"
printf 'skill\n' > "$HOME/.agents/skills/demo/SKILL.md"
ln -s "$HOME/.agents/skills" "$HOME/.config/zed/skills"

cat > "$fake_bin/brew" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fake_bin/npm" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
  printf '/tmp\n'
  printf '└── typescript@5.0.0\n'
fi
exit 0
SH
cat > "$fake_bin/git" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fake_bin"/*
export PATH="${fake_bin}:/bin:/usr/bin"

output="$("$repo/scripts/backup.sh" --dry-run 2>&1)"

if printf '%s\n' "$output" | grep -q "${HOME}/.zed"; then
  printf 'dry-run guessed ~/.zed instead of metadata canonical_dir\n' >&2
  exit 1
fi

if printf '%s\n' "$output" | grep -q "${HOME}/.copilot"; then
  printf 'dry-run guessed ~/.copilot instead of metadata canonical_dir\n' >&2
  exit 1
fi

printf '%s\n' "$output" | grep -q "${HOME}/.config/zed"
printf '%s\n' "$output" | grep -q "${HOME}/.config/github-copilot"
printf '%s\n' "$output" | grep -q "${HOME}/.agents/skills"

printf 'generated backup agent metadata ok\n'
