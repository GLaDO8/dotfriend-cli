#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"

PASS=0
FAIL=0

ok() {
  printf '  ✅ %s\n' "$1"
  ((PASS++)) || true
}

ko() {
  printf '  ❌ %s: %s\n' "$1" "$2"
  ((FAIL++)) || true
}

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

setup_case() {
  local case_dir="$1"
  export HOME="${TEST_DIR}/${case_dir}/home"
  export DOTFRIEND_CACHE_DIR="${HOME}/.cache/dotfriend"
  mkdir -p "$DOTFRIEND_CACHE_DIR"
}

write_selections() {
  local repo_name="$1"
  local dotfiles_json="$2"
  local config_dirs_json="$3"
  local agents_json="$4"

  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<EOF
{
  "apps": [],
  "agents": ${agents_json},
  "formulae": [],
  "taps": [],
  "npm_globals": [],
  "dotfiles": ${dotfiles_json},
  "config_dirs": ${config_dirs_json},
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "${repo_name}", "private": true}
}
EOF
}

source_generator() {
  # shellcheck disable=SC1091
  source "${PROJECT_ROOT}/lib/common.sh"
  # shellcheck disable=SC1091
  source "${PROJECT_ROOT}/lib/generate.sh"
}

test_repo_name_and_github_push() {
  setup_case "repo_name"
  write_selections "work-mac" '[".zshrc"]' '[]' '[]'
  printf '# test zshrc\n' > "${HOME}/.zshrc"

  local bin_dir="${TEST_DIR}/repo_name/bin"
  local gh_log="${TEST_DIR}/repo_name/gh.log"
  local gh_pwd_log="${TEST_DIR}/repo_name/gh-pwd.log"
  local git_log="${TEST_DIR}/repo_name/git.log"
  mkdir -p "$bin_dir"

  cat > "${bin_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG:?}"
case "$1 $2" in
  "auth status")
    exit 0
    ;;
  "api user")
    printf 'tester\n'
    exit 0
    ;;
  "repo view")
    exit 1
    ;;
  "repo create")
    printf '%s\n' "${PWD}" >> "${GH_PWD_LOG:?}"
    if [[ "${PWD}" != "${EXPECTED_REPO_DIR:?}" ]]; then
      printf 'gh repo create ran from %s, expected %s\n' "${PWD}" "${EXPECTED_REPO_DIR}" >&2
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${bin_dir}/gh"

  cat > "${bin_dir}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GIT_LOG:?}"
case "${1:-}" in
  init)
    mkdir -p .git
    printf 'NOISY_GIT_INIT_STDOUT\n'
    printf 'NOISY_GIT_INIT_STDERR\n' >&2
    exit 0
    ;;
  add)
    printf 'NOISY_GIT_ADD_STDOUT\n'
    exit 0
    ;;
  commit)
    printf 'NOISY_GIT_COMMIT_STDOUT\n'
    exit 0
    ;;
  remote|branch|push)
    printf 'NOISY_GIT_PUSH_STDOUT\n'
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${bin_dir}/git"

  PATH="${bin_dir}:${PATH}"
  export GH_LOG="$gh_log"
  export GH_PWD_LOG="$gh_pwd_log"
  export GIT_LOG="$git_log"
  export EXPECTED_REPO_DIR="${HOME}/work-mac"

  source_generator

  local output
  if output="$(generate_repo "" false 2>&1)"; then
    ok "generate_repo uses repo name as the default folder"
  else
    ko "generate_repo uses repo name as the default folder" "command failed"
    printf '%s\n' "$output"
    return
  fi

  local repo_dir="${HOME}/work-mac"
  if [[ -d "$repo_dir" ]]; then
    ok "repo directory matches GitHub repo name"
  else
    ko "repo directory matches GitHub repo name" "missing ${repo_dir}"
  fi

  if [[ -d "${repo_dir}/.git" ]]; then
    ok "git init still creates a local repo"
  else
    ko "git init still creates a local repo" "missing ${repo_dir}/.git"
  fi

  if [[ "$output" == *"unbound variable"* ]]; then
    ko "github push path avoids DRY_RUN crash" "saw unbound variable"
  else
    ok "github push path avoids DRY_RUN crash"
  fi

  if [[ "$output" == *"command not found"* || "$output" == *"invalid option"* ]]; then
    ko "readme generation avoids shell interpolation errors" "saw shell error output during repo generation"
  else
    ok "readme generation avoids shell interpolation errors"
  fi

  if [[ "$output" == *"NOISY_GIT_INIT_STDOUT"* || "$output" == *"NOISY_GIT_INIT_STDERR"* || "$output" == *"NOISY_GIT_ADD_STDOUT"* || "$output" == *"NOISY_GIT_COMMIT_STDOUT"* ]]; then
    ko "git setup stays quiet in terminal output" "saw suppressed git command output"
  else
    ok "git setup stays quiet in terminal output"
  fi

  if [[ -f "$gh_log" ]] && grep -q 'repo create work-mac --private --source=. --push' "$gh_log"; then
    ok "github create uses the selected repo name"
  else
    ko "github create uses the selected repo name" "gh repo create was not called correctly"
  fi

  if [[ -f "$gh_pwd_log" ]] && grep -qx "${repo_dir}" "$gh_pwd_log"; then
    ok "github create runs from the generated repo"
  else
    ko "github create runs from the generated repo" "gh repo create ran outside ${repo_dir}"
  fi

  if [[ "$output" == *"Your dotfiles repo has been generated and backed up to GitHub."* && "$output" == *"Local repo: ${repo_dir}"* && "$output" == *"GitHub: https://github.com/tester/work-mac"* && "$output" == *"dotfriend sync"* ]]; then
    ok "final summary explains the repo location and sync command"
  else
    ko "final summary explains the repo location and sync command" "missing final completion details"
  fi

  if grep -q "${repo_dir}" "${repo_dir}/install.sh"; then
    ko "install.sh stays portable" "embedded source-machine path in install.sh"
  else
    ok "install.sh stays portable"
  fi

  if grep -Fq 'DOTFILES_DIR="${DOTFILES_DIR:-${SCRIPT_DIR}}"' "${repo_dir}/install.sh"; then
    ok "install.sh uses its clone as the managed repo"
  else
    ko "install.sh uses its clone as the managed repo" "DOTFILES_DIR does not default to script directory"
  fi

  if grep -q 'npm install -g dotfriend' "${repo_dir}/install.sh" && grep -q 'last-sync.json' "${repo_dir}/install.sh"; then
    ok "install.sh installs dotfriend and records sync repo"
  else
    ko "install.sh installs dotfriend and records sync repo" "missing dotfriend install or cache registration"
  fi

  if grep -q '`bootstrap.sh`' "${repo_dir}/README.md" && grep -q '`Brewfile`' "${repo_dir}/README.md" && grep -q 'dotfriend sync' "${repo_dir}/README.md"; then
    ok "generated readme keeps literal markdown command names"
  else
    ko "generated readme keeps literal markdown command names" "missing literal markdown backticks or dotfriend sync guidance"
  fi

  if grep -q "DOTFILES_DIR=\"\${HOME}/work-mac\"" "${repo_dir}/bootstrap.sh"; then
    ok "bootstrap.sh clones into the selected repo folder"
  else
    ko "bootstrap.sh clones into the selected repo folder" "wrong DOTFILES_DIR"
  fi
}

test_agent_and_shared_config_copy() {
  setup_case "agents"
  write_selections "agent-repo" '[".zshrc"]' '[]' '[{"id":"claude","name":"Claude Code"},{"id":"codex","name":"OpenAI Codex"}]'
  printf '# test zshrc\n' > "${HOME}/.zshrc"

  mkdir -p "${HOME}/.claude/hooks" "${HOME}/.codex" "${HOME}/.agents/skills/demo" "${HOME}/.agents/agent-docs"
  printf '# CLAUDE\n' > "${HOME}/.claude/CLAUDE.md"
  cat > "${HOME}/.claude/settings.json" <<'EOF'
{
  "theme": "dark",
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/lint-check.sh"
          }
        ]
      }
    ]
  }
}
EOF
  printf '#!/usr/bin/env bash\n' > "${HOME}/.claude/hooks/pre.sh"
  printf '# AGENTS\n' > "${HOME}/.codex/AGENTS.md"
  printf '# RTK\n' > "${HOME}/.codex/RTK.md"
  printf 'skill\n' > "${HOME}/.agents/skills/demo/SKILL.md"
  printf 'docs\n' > "${HOME}/.agents/agent-docs/readme.md"
  ln -s "${HOME}/.agents/skills" "${HOME}/.codex/skills"
  ln -s "${HOME}/.agents/agent-docs" "${HOME}/.codex/agent-docs"

  source_generator

  local repo_dir="${TEST_DIR}/agents/out"
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "agent config generation succeeds"
  else
    ko "agent config generation succeeds" "generate_repo failed"
    return
  fi

  if [[ -f "${repo_dir}/claude/CLAUDE.md" && -f "${repo_dir}/claude/settings.json" && -f "${repo_dir}/claude/hooks/pre.sh" ]]; then
    ok "claude files are copied into the claude folder"
  else
    ko "claude files are copied into the claude folder" "expected Claude files missing"
  fi

  if ! grep -q '"hooks"' "${repo_dir}/claude/settings.json"; then
    ok "copied claude settings disable active hooks"
  else
    ko "copied claude settings disable active hooks" "hooks remained active in generated repo"
  fi

  if [[ -f "${repo_dir}/codex/AGENTS.md" && -f "${repo_dir}/codex/RTK.md" ]]; then
    ok "codex files are copied into the codex folder"
  else
    ko "codex files are copied into the codex folder" "expected Codex files missing"
  fi

  if [[ -f "${repo_dir}/agents/skills/demo/SKILL.md" && -f "${repo_dir}/agents/agent-docs/readme.md" ]]; then
    ok "shared ~/.agents content is copied into agents/"
  else
    ko "shared ~/.agents content is copied into agents/" "expected shared agent files missing"
  fi

  if [[ -e "${repo_dir}/codex/skills" || -e "${repo_dir}/codex/agent-docs" ]]; then
    ko "symlinked shared dirs stay out of codex/" "shared symlinked dirs were copied twice"
  else
    ok "symlinked shared dirs stay out of codex/"
  fi
}

test_filtered_recursive_copy_and_layout() {
  setup_case "filtered_copy"
  write_selections "filtered-repo" '[".zshrc",".gitconfig",".npmrc"]' '["opencode"]' '[]'
  printf '# zshrc\n' > "${HOME}/.zshrc"
  printf '[user]\nname = Test\n' > "${HOME}/.gitconfig"
  printf 'prefix=/tmp/test\n' > "${HOME}/.npmrc"

  mkdir -p \
    "${HOME}/.config/opencode/node_modules/pkg" \
    "${HOME}/.config/opencode/cache" \
    "${HOME}/.config/opencode/gcloud" \
    "${HOME}/.config/opencode/virtenv" \
    "${HOME}/.config/opencode/marketplace" \
    "${HOME}/.config/opencode/.turbo" \
    "${HOME}/.config/opencode/vendor" \
    "${HOME}/.config/opencode/logs"
  printf '{"model":"gpt"}\n' > "${HOME}/.config/opencode/settings.json"
  printf 'node_modules/\n' > "${HOME}/.config/opencode/.gitignore"
  printf 'junk\n' > "${HOME}/.config/opencode/node_modules/pkg/index.js"
  printf 'gcloud cache\n' > "${HOME}/.config/opencode/gcloud/cache.db"
  printf 'python runtime\n' > "${HOME}/.config/opencode/virtenv/runtime.py"
  printf 'market cache\n' > "${HOME}/.config/opencode/marketplace/list.json"
  printf 'generated cache\n' > "${HOME}/.config/opencode/.turbo/cache.bin"
  printf 'dependency tree\n' > "${HOME}/.config/opencode/vendor/lib.js"
  printf 'log line\n' > "${HOME}/.config/opencode/logs/run.log"

  source_generator

  local repo_dir="${TEST_DIR}/filtered_copy/out"
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "filtered config generation succeeds"
  else
    ko "filtered config generation succeeds" "generate_repo failed"
    return
  fi

  if [[ -f "${repo_dir}/zsh/.zshrc" && -f "${repo_dir}/zsh/.npmrc" ]]; then
    ok "shell dotfiles land in zsh/"
  else
    ko "shell dotfiles land in zsh/" "expected shell files missing"
  fi

  if [[ -f "${repo_dir}/config/git/.gitconfig" ]]; then
    ok "gitconfig lands in config/git/"
  else
    ko "gitconfig lands in config/git/" "missing config/git/.gitconfig"
  fi

  if [[ -f "${repo_dir}/config/opencode/settings.json" ]]; then
    ok "config directories still copy wanted files"
  else
    ko "config directories still copy wanted files" "missing settings.json"
  fi

  if [[ -e "${repo_dir}/config/opencode/node_modules" ]]; then
    ko "node_modules is excluded from copied configs" "node_modules was copied"
  else
    ok "node_modules is excluded from copied configs"
  fi

  local filtered_path
  for filtered_path in gcloud/cache.db virtenv/runtime.py marketplace/list.json .turbo/cache.bin vendor/lib.js logs/run.log; do
    if [[ -e "${repo_dir}/config/opencode/${filtered_path}" ]]; then
      ko "runtime-heavy config paths are excluded" "${filtered_path} was copied"
      return
    fi
  done
  ok "runtime-heavy config paths are excluded"

  if [[ -e "${repo_dir}/config/opencode/.gitignore" ]]; then
    ko ".gitignore files are excluded from copied configs" ".gitignore was copied"
  else
    ok ".gitignore files are excluded from copied configs"
  fi

  if grep -q 'node_modules/' "${repo_dir}/.gitignore" && \
     grep -q 'virtenv/' "${repo_dir}/.gitignore" && \
     grep -q 'marketplace/' "${repo_dir}/.gitignore" && \
     grep -q '.turbo/' "${repo_dir}/.gitignore" && \
     grep -q 'vendor/' "${repo_dir}/.gitignore"; then
    ok "generated .gitignore still ignores dependency and runtime paths"
  else
    ko "generated .gitignore still ignores dependency and runtime paths" "missing expected ignore rule"
  fi

  if grep -q '_symlink "\$DOTFILES_DIR/zsh/.zshrc" "\$HOME/.zshrc"' "${repo_dir}/install.sh" && \
     grep -q '_symlink "\$DOTFILES_DIR/config/git/.gitconfig" "\$HOME/.gitconfig"' "${repo_dir}/install.sh"; then
    ok "install.sh points to the new repo layout"
  else
    ko "install.sh points to the new repo layout" "missing portable symlink paths"
  fi
}

test_cursor_extension_manifest_and_metadata() {
  setup_case "cursor_manifest"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [{"id":"cursor","name":"Cursor"}],
  "formulae": [],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [".zshrc"],
  "config_dirs": [],
  "editors": {"vscode": false, "cursor": true},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "cursor-repo", "private": true}
}
EOF
  printf '# test zshrc\n' > "${HOME}/.zshrc"

  mkdir -p "${HOME}/.cursor/rules" "${HOME}/Library/Application Support/Cursor/User"
  printf '{"chat":"enabled"}\n' > "${HOME}/.cursor/mcp.json"
  printf '{"agent":true}\n' > "${HOME}/.cursor/settings.json"
  printf '{"kb":"agent"}\n' > "${HOME}/.cursor/keybindings.json"
  printf 'rule\n' > "${HOME}/.cursor/rules/base.md"
  mkdir -p "${HOME}/.cursor/extensions/ms-python.python-2025.6.1-darwin-arm64"
  printf 'vendored\n' > "${HOME}/.cursor/extensions/ms-python.python-2025.6.1-darwin-arm64/METADATA"
  printf '{"editor":true}\n' > "${HOME}/Library/Application Support/Cursor/User/settings.json"
  printf '{"editorKb":true}\n' > "${HOME}/Library/Application Support/Cursor/User/keybindings.json"

  local bin_dir="${TEST_DIR}/cursor_manifest/bin"
  mkdir -p "$bin_dir"
  cat > "${bin_dir}/cursor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--list-extensions" ]]; then
  printf 'ms-python.python\n'
  printf 'anysphere.cursorpyright\n'
  exit 0
fi
printf 'unexpected cursor args: %s\n' "$*" >&2
exit 1
EOF
  chmod +x "${bin_dir}/cursor"
  PATH="${bin_dir}:${PATH}"

  source_generator

  local repo_dir="${TEST_DIR}/cursor_manifest/out"
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "cursor repo generation succeeds"
  else
    ko "cursor repo generation succeeds" "generate_repo failed"
    return
  fi

  if [[ -f "${repo_dir}/cursor/extensions.txt" ]]; then
    ok "cursor extension manifest is generated"
  else
    ko "cursor extension manifest is generated" "missing cursor/extensions.txt"
  fi

  if [[ -e "${repo_dir}/cursor/extensions/ms-python.python-2025.6.1-darwin-arm64/METADATA" ]]; then
    ko "cursor vendored extension files stay out of repo" "vendored extension payload was copied"
  else
    ok "cursor vendored extension files stay out of repo"
  fi

  if grep -q 'cursor --install-extension "\$ext"' "${repo_dir}/install.sh"; then
    ok "install.sh restores cursor extensions from extension IDs"
  else
    ko "install.sh restores cursor extensions from extension IDs" "missing cursor install loop"
  fi

  if grep -q '_rsync_agent "\$DOTFILES_DIR/cursor" "\$HOME/.cursor"' "${repo_dir}/install.sh"; then
    ko "install.sh avoids full cursor root rsync" "cursor root rsync still present"
  else
    ok "install.sh avoids full cursor root rsync"
  fi

  if [[ -f "${repo_dir}/README.md" && -f "${repo_dir}/.dotfriend/agent-tools.json" && -f "${repo_dir}/.dotfriend/selections.json" ]]; then
    ok "generated repo includes readme and metadata"
  else
    ko "generated repo includes readme and metadata" "missing README.md or .dotfriend metadata"
  fi
}

printf '\n1. Generation regressions\n'
test_repo_name_and_github_push
test_agent_and_shared_config_copy
test_filtered_recursive_copy_and_layout
test_cursor_extension_manifest_and_metadata

printf '\n========================================\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '========================================\n'

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
