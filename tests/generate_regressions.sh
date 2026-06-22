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

  if grep -Fq 'DRY_RUN="${DRY_RUN:-false}"' "${repo_dir}/install.sh" \
    && grep -Fq 'INSTALL_VALIDATE="${INSTALL_VALIDATE:-false}"' "${repo_dir}/install.sh" \
    && grep -Fq 'INSTALL_DOTFRIEND="${INSTALL_DOTFRIEND:-true}"' "${repo_dir}/install.sh"; then
    ok "install.sh keeps restore toggles runtime-configurable"
  else
    ko "install.sh keeps restore toggles runtime-configurable" "restore toggles were hard-coded during generation"
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

test_backend_generate_events_and_cached_editor_extensions() {
  setup_case "backend_generate"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [],
  "formulae": [],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [".zshrc"],
  "config_dirs": [],
  "editors": {"vscode": true, "cursor": true},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "backend-repo", "private": true}
}
EOF
  cat > "${DOTFRIEND_CACHE_DIR}/discovery.json" <<'EOF'
{
  "schema_version": 2,
  "editors": {
    "vscode": {"settings_path": "", "extensions": ["cached.vscode"]},
    "cursor": {"settings_path": "", "extensions": ["cached.cursor"]}
  }
}
EOF
  printf '# zshrc\n' > "${HOME}/.zshrc"

  local bin_dir="${TEST_DIR}/backend_generate/bin"
  mkdir -p "$bin_dir"
  cat > "${bin_dir}/code" <<'EOF'
#!/usr/bin/env bash
printf 'code CLI should not run when discovery cache has extensions\n' >&2
exit 44
EOF
  cat > "${bin_dir}/cursor" <<'EOF'
#!/usr/bin/env bash
printf 'cursor CLI should not run when discovery cache has extensions\n' >&2
exit 45
EOF
  chmod +x "${bin_dir}/code" "${bin_dir}/cursor"
  PATH="${bin_dir}:${PATH}"

  local repo_dir="${TEST_DIR}/backend_generate/out"
  local stdout_file="${TEST_DIR}/backend_generate/stdout.jsonl"
  local stderr_file="${TEST_DIR}/backend_generate/stderr.log"
  if "${PROJECT_ROOT}/dotfriend" --no-bootstrap generate --events --target "$repo_dir" --no-push --force >"$stdout_file" 2>"$stderr_file"; then
    ok "backend generate --events command succeeds"
  else
    ko "backend generate --events command succeeds" "command failed"
    cat "$stderr_file"
    return
  fi

  if jq -s -e 'map(.event) | index("job_started") and index("step_started") and index("step_finished") and index("job_finished")' "$stdout_file" >/dev/null; then
    ok "backend generate streams JSON events"
  else
    ko "backend generate streams JSON events" "missing expected event names"
  fi

  if grep -v '^{.*}$' "$stdout_file" >/dev/null; then
    ko "backend generate event stdout stays JSON-only" "saw non-json stdout"
  else
    ok "backend generate event stdout stays JSON-only"
  fi

  if [[ "$(cat "${repo_dir}/vscode/extensions.txt")" == "cached.vscode" && "$(cat "${repo_dir}/cursor/extensions.txt")" == "cached.cursor" ]]; then
    ok "generation uses cached editor extensions before editor CLIs"
  else
    ko "generation uses cached editor extensions before editor CLIs" "cached extension manifests missing"
  fi

  if [[ -f "${repo_dir}/.dotfriend/generation-state.json" ]]; then
    ok "generation state is written"
  else
    ko "generation state is written" "missing .dotfriend/generation-state.json"
  fi
}

test_generation_state_skips_unchanged_sections() {
  setup_case "generation_state"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [],
  "formulae": [],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [],
  "config_dirs": [],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "state-repo", "private": true}
}
EOF

  source_generator

  local repo_dir="${TEST_DIR}/generation_state/out"
  GEN_NO_PUSH=true
  generate_repo "$repo_dir" false >/dev/null 2>&1
  printf 'local note\n' > "${repo_dir}/README.md"
  GEN_FORCE=true
  generate_repo "$repo_dir" false >/dev/null 2>&1
  GEN_FORCE=false
  GEN_NO_PUSH=false

  if [[ "$(cat "${repo_dir}/README.md")" == "local note" ]]; then
    ok "unchanged generation sections are skipped"
  else
    ko "unchanged generation sections are skipped" "README.md was rewritten despite unchanged section fingerprint"
  fi
}

test_generator_code_changes_invalidate_generated_install_script() {
  setup_case "generator_code_change"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [],
  "formulae": [],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [],
  "config_dirs": [],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "state-repo", "private": true}
}
EOF

  source_generator

  local repo_dir="${TEST_DIR}/generator_code_change/out"
  local old_fingerprint
  old_fingerprint="$(
    {
      printf '%s\n' "install_script"
      jq -S -c '.' "${DOTFRIEND_CACHE_DIR}/selections.json"
    } | shasum -a 256 | awk '{print $1}'
  )"
  mkdir -p "${repo_dir}/.dotfriend"
  printf '# stale install script\n' > "${repo_dir}/install.sh"
  cat > "${repo_dir}/.dotfriend/generation-state.json" <<EOF
{
  "schema_version": 1,
  "generated_by": "dotfriend",
  "sections": {
    "install_script": {
      "fingerprint": "${old_fingerprint}",
      "generated_at": "2026-06-01T00:00:00Z"
    }
  }
}
EOF

  GEN_NO_PUSH=true
  GEN_FORCE=true
  generate_repo "$repo_dir" false >/dev/null 2>&1
  GEN_FORCE=false
  GEN_NO_PUSH=false

  if grep -Fq 'ensure_brew_package npm node "dotfriend CLI"' "${repo_dir}/install.sh"; then
    ok "generator changes invalidate stale install.sh"
  else
    ko "generator changes invalidate stale install.sh" "install.sh was skipped using an old selection-only fingerprint"
  fi
}

test_macos_defaults_generation_and_apply_script() {
  setup_case "macos_defaults"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [],
  "formulae": [],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [],
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
    },
    {
      "id": "dock.tile-size",
      "domain": "com.apple.dock",
      "key": "tilesize",
      "scope": "user",
      "value_type": "int",
      "value": 42,
      "risk": "safe",
      "restart": ["Dock"]
    },
    {
      "id": "safari.auto-open-safe-downloads",
      "domain": "com.apple.Safari",
      "key": "AutoOpenSafeDownloads",
      "scope": "user",
      "value_type": "bool",
      "value": true,
      "risk": "risky",
      "restart": ["Safari"]
    },
    {
      "id": "trackpad.scale",
      "domain": "com.apple.trackpad.test",
      "key": "Scale",
      "scope": "currentHost",
      "value_type": "float",
      "value": 1.25,
      "risk": "safe",
      "restart": []
    }
  ],
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "macos-defaults-repo", "private": true}
}
EOF

  source_generator

  local repo_dir="${TEST_DIR}/macos_defaults/out"
  GEN_NO_PUSH=true
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "selected Mac settings generate repo contents"
  else
    GEN_NO_PUSH=false
    ko "selected Mac settings generate repo contents" "generate_repo failed"
    return
  fi
  GEN_NO_PUSH=false

  if jq -e '.entries[] | select(.id == "dock.orientation" and .value == "left")' "${repo_dir}/macos/defaults.json" >/dev/null; then
    ok "macos/defaults.json records selected reviewed values"
  else
    ko "macos/defaults.json records selected reviewed values" "missing dock.orientation"
  fi

  if [[ -x "${repo_dir}/scripts/apply-macos-defaults.sh" ]]; then
    ok "Mac settings apply script is generated"
  else
    ko "Mac settings apply script is generated" "missing executable script"
  fi

  if grep -q 'apply-macos-defaults.sh' "${repo_dir}/install.sh"; then
    ok "install.sh calls Mac settings apply script"
  else
    ko "install.sh calls Mac settings apply script" "missing apply script call"
  fi

  if jq -e '.items[] | select(.id == "macos_defaults:selected" and .type == "macos_defaults" and .restore_mode == "defaults_import")' "${repo_dir}/.dotfriend/restore-manifest.json" >/dev/null; then
    ok "restore manifest includes Mac settings defaults_import item"
  else
    ko "restore manifest includes Mac settings defaults_import item" "missing manifest item"
  fi

  if bash -n "${repo_dir}/scripts/apply-macos-defaults.sh" && bash -n "${repo_dir}/install.sh"; then
    ok "generated Mac settings scripts are syntactically valid"
  else
    ko "generated Mac settings scripts are syntactically valid" "bash -n failed"
  fi

  local bin_dir="${TEST_DIR}/macos_defaults/bin"
  local defaults_log="${TEST_DIR}/macos_defaults/defaults.log"
  local killall_log="${TEST_DIR}/macos_defaults/killall.log"
  mkdir -p "$bin_dir"
  cat > "${bin_dir}/defaults" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${DEFAULTS_LOG:?}"
if [[ "${1:-}" == "-currentHost" && "${2:-}" == "export" ]]; then
  mkdir -p "$(dirname "${4:?}")"
  printf 'plist\n' > "${4:?}"
elif [[ "${1:-}" == "export" ]]; then
  mkdir -p "$(dirname "${3:?}")"
  printf 'plist\n' > "${3:?}"
fi
EOF
  cat > "${bin_dir}/killall" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${KILLALL_LOG:?}"
EOF
  chmod +x "${bin_dir}/defaults" "${bin_dir}/killall"

  DEFAULTS_LOG="$defaults_log" KILLALL_LOG="$killall_log" BACKUP_ROOT="${TEST_DIR}/macos_defaults/backup" PATH="${bin_dir}:${PATH}" "${repo_dir}/scripts/apply-macos-defaults.sh" >/dev/null

  if grep -Fqx -- 'write com.apple.dock orientation -string left' "$defaults_log" \
    && grep -Fqx -- 'write com.apple.dock tilesize -int 42' "$defaults_log" \
    && grep -Fqx -- 'write com.apple.Safari AutoOpenSafeDownloads -bool true' "$defaults_log" \
    && grep -Fqx -- '-currentHost write com.apple.trackpad.test Scale -float 1.25' "$defaults_log"; then
    ok "apply script writes selected Mac settings with typed defaults commands"
  else
    ko "apply script writes selected Mac settings with typed defaults commands" "unexpected defaults log"
  fi

  if [[ "$(grep -c '^Dock$' "$killall_log")" == "1" && "$(grep -c '^Safari$' "$killall_log")" == "1" ]]; then
    ok "apply script batches process restarts"
  else
    ko "apply script batches process restarts" "restart targets were not batched"
  fi

  if find "${TEST_DIR}/macos_defaults/backup/macos-defaults" -name 'com.apple.dock.plist' -print -quit | grep -q .; then
    ok "apply script backs up affected defaults domains"
  else
    ko "apply script backs up affected defaults domains" "missing domain backup"
  fi
}

test_install_dry_run_plans_restore_dependencies_without_missing_tool_warnings() {
  setup_case "install_dry_run_dependencies"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [],
  "formulae": [],
  "taps": [],
  "npm_globals": ["typescript@latest"],
  "dotfiles": [],
  "config_dirs": [],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": true, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "dry-run-deps", "private": true}
}
EOF

  local generate_bin_dir="${TEST_DIR}/install_dry_run_dependencies/generate-bin"
  mkdir -p "$generate_bin_dir"
  cat > "${generate_bin_dir}/dockutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--list" ]]; then
  printf '/Applications/Safari.app\tpersistent-apps\tfile:///Applications/Safari.app/\n'
fi
EOF
  chmod +x "${generate_bin_dir}/dockutil"

  source_generator

  local repo_dir="${TEST_DIR}/install_dry_run_dependencies/out"
  GEN_NO_PUSH=true
  if PATH="${generate_bin_dir}:${PATH}" generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "restore dependency test repo generates"
  else
    GEN_NO_PUSH=false
    ko "restore dependency test repo generates" "generate_repo failed"
    return
  fi
  GEN_NO_PUSH=false

  local dry_home="${TEST_DIR}/install_dry_run_dependencies/new-home"
  local stdout_file="${TEST_DIR}/install_dry_run_dependencies/install.stdout"
  local stderr_file="${TEST_DIR}/install_dry_run_dependencies/install.stderr"
  mkdir -p "$dry_home"

  if HOME="$dry_home" DOTFRIEND_BREW_PREFIX="${TEST_DIR}/install_dry_run_dependencies/missing-brew" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DRY_RUN=true INSTALL_DOTFRIEND=true BREW_UPGRADE=false "$repo_dir/install.sh" >"$stdout_file" 2>"$stderr_file"; then
    ok "generated install.sh dry-run succeeds without restore dependencies installed"
  else
    ko "generated install.sh dry-run succeeds without restore dependencies installed" "install.sh --dry-run failed"
  fi

  if grep -Fq '[dry-run] Would install node for dotfriend CLI' "$stdout_file" \
    && grep -Fq '[dry-run] Would install node for npm global packages' "$stdout_file" \
    && grep -Fq '[dry-run] Would install dockutil for Dock restore' "$stdout_file" \
    && grep -Fq '[dry-run] would run: npm install -g dotfriend' "$stdout_file" \
    && grep -Fq '[dry-run] would run: npm install -g typescript@latest' "$stdout_file" \
    && grep -Fq '[dry-run] would run: dockutil --add /Applications/Safari.app' "$stdout_file"; then
    ok "install.sh dry-run plans npm and dock restore dependencies"
  else
    ko "install.sh dry-run plans npm and dock restore dependencies" "missing planned dependency install"
  fi

  if grep -Fq 'npm still not found; dotfriend CLI was not installed' "$stderr_file" \
    || grep -Fq 'npm not found; skipping npm global installs' "$stderr_file" \
    || grep -Fq 'dockutil not available; skipping dock restore' "$stderr_file"; then
    ko "install.sh dry-run avoids missing npm and dockutil warnings" "unexpected warning emitted"
  else
    ok "install.sh dry-run avoids missing npm and dockutil warnings"
  fi
}

test_brewfile_entries_use_real_newlines() {
  setup_case "brewfile_newlines"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [
    "Spotify|cask:spotify|cask",
    "Auto Export|mas:Auto Export,id:1115567069|mas"
  ],
  "agents": [],
  "formulae": ["git", "jq"],
  "taps": ["alpha/tap", "beta/tap"],
  "npm_globals": [],
  "dotfiles": [],
  "config_dirs": [],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "brewfile-newlines", "private": true}
}
EOF

  source_generator

  local repo_dir="${TEST_DIR}/brewfile_newlines/out"
  GEN_NO_PUSH=true
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "brewfile newline test repo generates"
  else
    GEN_NO_PUSH=false
    ko "brewfile newline test repo generates" "generate_repo failed"
    return
  fi
  GEN_NO_PUSH=false

  local brewfile="${repo_dir}/Brewfile"
  if grep -Fq '\n' "$brewfile"; then
    ko "Brewfile uses real newlines" "found literal backslash-n text"
  else
    ok "Brewfile uses real newlines"
  fi

  if grep -Fxq 'tap "alpha/tap"' "$brewfile" \
    && grep -Fxq 'tap "beta/tap"' "$brewfile" \
    && grep -Fxq 'brew "git"' "$brewfile" \
    && grep -Fxq 'brew "jq"' "$brewfile" \
    && grep -Fxq 'cask "spotify"' "$brewfile" \
    && grep -Fxq 'mas "Auto Export", id: 1115567069' "$brewfile"; then
    ok "Brewfile package entries are one per line"
  else
    ko "Brewfile package entries are one per line" "missing expected line-delimited entries"
  fi
}

test_install_times_out_slow_brew_taps_and_continues() {
  setup_case "install_brew_tap_timeout"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [],
  "formulae": ["git"],
  "taps": ["jordandtap/stuck"],
  "npm_globals": [],
  "dotfiles": [],
  "config_dirs": [],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "brew-tap-timeout", "private": true}
}
EOF

  source_generator

  local repo_dir="${TEST_DIR}/install_brew_tap_timeout/out"
  GEN_NO_PUSH=true
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "brew tap timeout test repo generates"
  else
    GEN_NO_PUSH=false
    ko "brew tap timeout test repo generates" "generate_repo failed"
    return
  fi
  GEN_NO_PUSH=false

  local fake_prefix="${TEST_DIR}/install_brew_tap_timeout/homebrew"
  local fake_bin="${TEST_DIR}/install_brew_tap_timeout/bin"
  local dry_home="${TEST_DIR}/install_brew_tap_timeout/new-home"
  local brew_log="${TEST_DIR}/install_brew_tap_timeout/brew.log"
  local stdout_file="${TEST_DIR}/install_brew_tap_timeout/install.stdout"
  local stderr_file="${TEST_DIR}/install_brew_tap_timeout/install.stderr"
  mkdir -p "${fake_prefix}/bin" "$fake_bin" "$dry_home"

  cat > "${fake_prefix}/bin/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${BREW_LOG:?}"
case "${1:-}" in
  shellenv)
    exit 0
    ;;
  tap)
    sleep 5
    exit 0
    ;;
  install)
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${fake_prefix}/bin/brew"

  cat > "${fake_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${fake_bin}/sudo"

  local started_at finished_at elapsed
  started_at="$(date +%s)"
  if HOME="$dry_home" BREW_LOG="$brew_log" DOTFRIEND_BREW_PREFIX="$fake_prefix" PATH="${fake_bin}:${fake_prefix}/bin:/usr/bin:/bin:/usr/sbin:/sbin" BREW_UPGRADE=false INSTALL_DOTFRIEND=false BREW_TAP_TIMEOUT_SECONDS=1 "$repo_dir/install.sh" >"$stdout_file" 2>"$stderr_file"; then
    ok "install.sh continues after a slow brew tap"
  else
    ko "install.sh continues after a slow brew tap" "install.sh aborted after slow tap"
  fi
  finished_at="$(date +%s)"
  elapsed=$((finished_at - started_at))

  if [[ "$elapsed" -lt 4 ]]; then
    ok "install.sh bounds slow brew tap duration"
  else
    ko "install.sh bounds slow brew tap duration" "elapsed ${elapsed}s despite BREW_TAP_TIMEOUT_SECONDS=1"
  fi

  if grep -Fxq 'install git' "$brew_log"; then
    ok "install.sh keeps installing formulae after a slow tap"
  else
    ko "install.sh keeps installing formulae after a slow tap" "brew install git was skipped"
  fi

  if grep -Fq 'Command timed out after 1s: brew tap jordandtap/stuck' "$stderr_file"; then
    ok "install.sh reports the timed-out brew tap"
  else
    ko "install.sh reports the timed-out brew tap" "missing timeout message"
  fi
}

test_install_continues_when_brew_update_fails() {
  setup_case "install_brew_update_failure"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [],
  "formulae": [],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [],
  "config_dirs": [],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "brew-update-failure", "private": true}
}
EOF

  source_generator

  local repo_dir="${TEST_DIR}/install_brew_update_failure/out"
  GEN_NO_PUSH=true
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "brew update failure test repo generates"
  else
    GEN_NO_PUSH=false
    ko "brew update failure test repo generates" "generate_repo failed"
    return
  fi
  GEN_NO_PUSH=false

  local fake_prefix="${TEST_DIR}/install_brew_update_failure/homebrew"
  local fake_bin="${TEST_DIR}/install_brew_update_failure/bin"
  local dry_home="${TEST_DIR}/install_brew_update_failure/new-home"
  local brew_log="${TEST_DIR}/install_brew_update_failure/brew.log"
  local stdout_file="${TEST_DIR}/install_brew_update_failure/install.stdout"
  local stderr_file="${TEST_DIR}/install_brew_update_failure/install.stderr"
  mkdir -p "${fake_prefix}/bin" "$fake_bin" "$dry_home"

  cat > "${fake_prefix}/bin/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${BREW_LOG:?}"
case "${1:-}" in
  shellenv)
    exit 0
    ;;
  update)
    exit 42
    ;;
  upgrade)
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${fake_prefix}/bin/brew"

  cat > "${fake_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${fake_bin}/sudo"

  if HOME="$dry_home" BREW_LOG="$brew_log" DOTFRIEND_BREW_PREFIX="$fake_prefix" PATH="${fake_bin}:${fake_prefix}/bin:/usr/bin:/bin:/usr/sbin:/sbin" BREW_UPGRADE=true INSTALL_DOTFRIEND=false "$repo_dir/install.sh" >"$stdout_file" 2>"$stderr_file"; then
    ok "install.sh continues when brew update fails"
  else
    ko "install.sh continues when brew update fails" "install.sh aborted after brew update failure"
  fi

  if grep -Fxq update "$brew_log" && grep -Fxq upgrade "$brew_log"; then
    ok "install.sh still attempts brew upgrade after update failure"
  else
    ko "install.sh still attempts brew upgrade after update failure" "brew upgrade was skipped"
  fi

  if grep -Fq 'Command failed: brew update' "$stderr_file"; then
    ok "install.sh records failed brew update"
  else
    ko "install.sh records failed brew update" "missing brew update failure message"
  fi
}

test_generated_restore_artifacts_are_portable_and_package_safe() {
  setup_case "restore_artifacts"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [
    "Karabiner-Elements|cask:karabiner-elements|cask",
    "Karabiner-EventViewer|cask:karabiner-elements|cask",
    "Spotify|cask:spotify|cask",
    "Auto Export|mas:Auto Export,id:1115567069|mas"
  ],
  "agents": [],
  "formulae": ["git", "jolt", "git", "jq"],
  "taps": ["alpha/tap", "jordond/tap", "alpha/tap"],
  "npm_globals": ["@biomejs/biome@2.4.12", "@openai/codex", "typescript@5.0.0"],
  "dotfiles": [],
  "config_dirs": ["sample"],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "restore-artifacts", "private": true}
}
EOF
  mkdir -p "${HOME}/.config/sample"
  printf 'setting=true\n' > "${HOME}/.config/sample/settings.conf"

  source_generator

  local repo_dir="${TEST_DIR}/restore_artifacts/out"
  GEN_NO_PUSH=true
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "restore artifact test repo generates"
  else
    GEN_NO_PUSH=false
    ko "restore artifact test repo generates" "generate_repo failed"
    return
  fi
  GEN_NO_PUSH=false

  if grep -Fq 'BACKUP_ROOT="${BACKUP_ROOT:-${HOME}/.dotfiles-backup}"' "${repo_dir}/install.sh" \
    && ! grep -Fq "BACKUP_ROOT=\"${HOME}/.dotfiles-backup\"" "${repo_dir}/install.sh"; then
    ok "install.sh keeps BACKUP_ROOT runtime-configurable"
  else
    ko "install.sh keeps BACKUP_ROOT runtime-configurable" "source machine backup path was embedded"
  fi

  if find "$repo_dir" -type f -perm -111 -print0 | xargs -0 grep -I -E '\{\{[A-Z0-9_:-]+\}\}' >/dev/null 2>&1; then
    ko "generated executable scripts contain no unresolved placeholders" "found {{...}} in executable script"
  else
    ok "generated executable scripts contain no unresolved placeholders"
  fi

  if grep -Fq 'soft_run npm install -g @biomejs/biome@2.4.12 || true' "${repo_dir}/install.sh" \
    && grep -Fq 'soft_run npm install -g @openai/codex || true' "${repo_dir}/install.sh" \
    && grep -Fq 'soft_run npm install -g typescript@5.0.0 || true' "${repo_dir}/install.sh" \
    && ! grep -Eq 'npm install -g[[:space:]]+(\|\||$)' "${repo_dir}/install.sh"; then
    ok "scoped npm globals render usable install commands"
  else
    ko "scoped npm globals render usable install commands" "missing scoped package or blank npm install"
  fi

  if [[ -f "${repo_dir}/npm-global.txt" ]] \
    && grep -Fxq '@biomejs/biome@2.4.12' "${repo_dir}/npm-global.txt" \
    && grep -Fxq '@openai/codex' "${repo_dir}/npm-global.txt"; then
    ok "npm globals are written as generated package metadata"
  else
    ko "npm globals are written as generated package metadata" "missing npm-global.txt entries"
  fi

  local brewfile="${repo_dir}/Brewfile"
  if [[ "$(grep -Fx 'tap "alpha/tap"' "$brewfile" | wc -l | tr -d ' ')" == "1" ]] \
    && [[ "$(grep -Fx 'brew "git"' "$brewfile" | wc -l | tr -d ' ')" == "1" ]] \
    && [[ "$(grep -Fx 'cask "karabiner-elements"' "$brewfile" | wc -l | tr -d ' ')" == "1" ]] \
    && ! grep -Fq 'jordond/tap' "$brewfile" \
    && ! grep -Fq 'brew "jolt"' "$brewfile"; then
    ok "Brewfile deduplicates packages and excludes banned stale entries"
  else
    ko "Brewfile deduplicates packages and excludes banned stale entries" "duplicate or banned Brewfile entry remained"
  fi

  if ! jq -e '(.taps // []) | index("jordond/tap")' "${repo_dir}/.dotfriend/selections.json" >/dev/null \
    && ! jq -e '(.formulae // []) | index("jolt")' "${repo_dir}/.dotfriend/selections.json" >/dev/null; then
    ok "generated selections exclude banned stale package state"
  else
    ko "generated selections exclude banned stale package state" "jolt or jordond/tap remained in generated selections"
  fi

  if jq -e '.items[] | select(.id == "packages:homebrew" and .repo_path == "Brewfile")' "${repo_dir}/.dotfriend/restore-manifest.json" >/dev/null \
    && jq -e '.items[] | select(.id == "packages:npm_globals" and .repo_path == "npm-global.txt")' "${repo_dir}/.dotfriend/restore-manifest.json" >/dev/null; then
    ok "restore manifest covers generated package artifacts"
  else
    ko "restore manifest covers generated package artifacts" "missing package manifest items"
  fi

  if "${repo_dir}/scripts/validate.sh" --dotfriend --json >/dev/null; then
    ok "generated artifact validation accepts clean generated package state"
  else
    ko "generated artifact validation accepts clean generated package state" "validate.sh --dotfriend failed"
  fi

  local vendored_key_header="${repo_dir}/config/gcloud/virtenv/lib/python3.13/site-packages/cryptography/hazmat/primitives/serialization/ssh.py"
  mkdir -p "$(dirname "$vendored_key_header")"
  printf '%s\n' 'OPENSSH_PRIVATE_KEY_HEADER = "BEGIN OPENSSH PRIVATE KEY"' > "$vendored_key_header"
  if "${repo_dir}/scripts/validate.sh" --dotfriend --json >/dev/null; then
    ok "generated artifact validation ignores vendored key header literals"
  else
    ko "generated artifact validation ignores vendored key header literals" "vendored dependency source tripped secret scan"
  fi

  local dry_home="${TEST_DIR}/restore_artifacts/new-home"
  local backup_root="${TEST_DIR}/restore_artifacts/backup-root"
  local stdout_file="${TEST_DIR}/restore_artifacts/install.stdout"
  local stderr_file="${TEST_DIR}/restore_artifacts/install.stderr"
  mkdir -p "$dry_home"

  if HOME="$dry_home" BACKUP_ROOT="$backup_root" DOTFRIEND_BREW_PREFIX="${TEST_DIR}/restore_artifacts/missing-brew" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DRY_RUN=true BREW_UPGRADE=false INSTALL_MAS=false "$repo_dir/install.sh" >"$stdout_file" 2>"$stderr_file"; then
    ok "generated install.sh dry-run exits cleanly on a fresh PATH"
  else
    ko "generated install.sh dry-run exits cleanly on a fresh PATH" "install.sh dry-run failed"
  fi

  if [[ ! -e "$backup_root" ]]; then
    ok "install.sh dry-run does not create BACKUP_ROOT"
  else
    ko "install.sh dry-run does not create BACKUP_ROOT" "created ${backup_root}"
  fi

  if grep -Fq '[dry-run] would run: brew tap alpha/tap' "$stdout_file" \
    && grep -Fq '[dry-run] would run: brew install git' "$stdout_file" \
    && grep -Fq '[dry-run] would run: brew install --cask karabiner-elements' "$stdout_file" \
    && grep -Fq '[dry-run] would run: npm install -g @biomejs/biome@2.4.12' "$stdout_file" \
    && grep -Fq 'Skipping MAS app: Auto Export (INSTALL_MAS=false)' "$stderr_file"; then
    ok "install.sh dry-run walks Brewfile and npm restore plan"
  else
    ko "install.sh dry-run walks Brewfile and npm restore plan" "missing concrete planned action"
  fi
}

test_empty_filtered_config_dirs_do_not_break_cloned_restore_artifacts() {
  setup_case "empty_filtered_config"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [],
  "formulae": [],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [],
  "config_dirs": ["raycast"],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "empty-filtered-config", "private": true}
}
EOF
  mkdir -p "${HOME}/.config/raycast/extensions" "${HOME}/.config/raycast/ai"

  source_generator

  local repo_dir="${TEST_DIR}/empty_filtered_config/out"
  GEN_NO_PUSH=true
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "empty filtered config test repo generates"
  else
    GEN_NO_PUSH=false
    ko "empty filtered config test repo generates" "generate_repo failed"
    return
  fi
  GEN_NO_PUSH=false

  local missing_tracked_source=""
  while IFS= read -r repo_path; do
    [[ -n "$repo_path" ]] || continue
    if [[ -e "${repo_dir}/${repo_path}" ]] && ! git -C "$repo_dir" ls-files -- "$repo_path" | grep -q .; then
      missing_tracked_source="$repo_path"
      break
    fi
  done < <(jq -r '
    .items[]?
    | select(.selected != false)
    | select(.restore_mode | IN("symlink","copy","rsync","managed_json_merge","managed_markdown_block","defaults_import"))
    | .repo_path // empty
  ' "${repo_dir}/.dotfriend/restore-manifest.json")

  if [[ -z "$missing_tracked_source" ]]; then
    ok "restore manifest sources are tracked by git"
  else
    ko "restore manifest sources are tracked by git" "untracked source path: ${missing_tracked_source}"
  fi

  if ! jq -e '.items[]? | select(.repo_path == "config/raycast")' "${repo_dir}/.dotfriend/restore-manifest.json" >/dev/null \
    && ! grep -Fq 'config/raycast' "${repo_dir}/install.sh"; then
    ok "empty filtered config dirs are not emitted as restore sources"
  else
    ko "empty filtered config dirs are not emitted as restore sources" "manifest or install.sh still references config/raycast"
  fi
}

test_generated_validation_catches_restore_artifact_issues() {
  setup_case "restore_validation"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": ["Spotify|cask:spotify|cask"],
  "agents": [],
  "formulae": ["git"],
  "taps": ["alpha/tap"],
  "npm_globals": ["@openai/codex"],
  "dotfiles": [],
  "config_dirs": ["sample"],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "restore-validation", "private": true}
}
EOF
  mkdir -p "${HOME}/.config/sample"
  printf 'setting=true\n' > "${HOME}/.config/sample/settings.conf"

  source_generator

  local repo_dir="${TEST_DIR}/restore_validation/out"
  GEN_NO_PUSH=true
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "restore validation test repo generates"
  else
    GEN_NO_PUSH=false
    ko "restore validation test repo generates" "generate_repo failed"
    return
  fi
  GEN_NO_PUSH=false

  printf '\n{{BROKEN_PLACEHOLDER}}\n' >> "${repo_dir}/bootstrap.sh"
  printf '\nsoft_run npm install -g  || true\n' >> "${repo_dir}/install.sh"
  printf 'brew "git"\n' >> "${repo_dir}/Brewfile"
  printf 'brew "jolt"\n' >> "${repo_dir}/Brewfile"
  printf 'tap "jordond/tap"\n' >> "${repo_dir}/Brewfile"
  printf '@broken\n' >> "${repo_dir}/npm-global.txt"
  printf '{not json\n' > "${repo_dir}/.dotfriend/selections.json"
  rm -rf "${repo_dir}/config/sample"

  local output_file="${TEST_DIR}/restore_validation/validate.json"
  if "${repo_dir}/scripts/validate.sh" --dotfriend --json >"$output_file"; then
    ko "generated artifact validation fails on restore issues" "validate.sh unexpectedly passed"
  else
    ok "generated artifact validation fails on restore issues"
  fi

  if jq -e '
    [.checks[] | select(.status == "fail") | .name] as $names |
    ($names | index("generated script placeholders")) and
    ($names | index("blank npm install commands")) and
    ($names | index("Brewfile duplicates")) and
    ($names | index("Brewfile banned entries")) and
    ($names | index("npm package names")) and
    ($names | index("selections JSON")) and
    ($names | index("manifest source paths"))
  ' "$output_file" >/dev/null; then
    ok "generated artifact validation reports the expected restore issues"
  else
    ko "generated artifact validation reports the expected restore issues" "missing expected validation failures"
  fi

  local dry_home="${TEST_DIR}/restore_validation/new-home"
  local stdout_file="${TEST_DIR}/restore_validation/install.stdout"
  local stderr_file="${TEST_DIR}/restore_validation/install.stderr"
  mkdir -p "$dry_home"
  if HOME="$dry_home" DOTFRIEND_BREW_PREFIX="${TEST_DIR}/restore_validation/missing-brew" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DRY_RUN=true BREW_UPGRADE=false INSTALL_MAS=false "$repo_dir/install.sh" >"$stdout_file" 2>"$stderr_file"; then
    ko "install.sh preflight fails before restore actions on bad generated artifacts" "install.sh unexpectedly passed"
  else
    ok "install.sh preflight fails before restore actions on bad generated artifacts"
  fi

  if ! grep -Fq 'Phase 2: App Setup' "$stdout_file" \
    && ! grep -Fq '[dry-run] would run: brew install git' "$stdout_file"; then
    ok "install.sh preflight stops before restore actions"
  else
    ko "install.sh preflight stops before restore actions" "restore actions ran after preflight failure"
  fi
}

test_install_handles_sudo_copy_and_rsync_safely() {
  setup_case "install_safety"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [],
  "formulae": [],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [],
  "config_dirs": ["sample"],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "install-safety", "private": true}
}
EOF
  mkdir -p "${HOME}/.config/sample" "${HOME}/.agents/skills/demo"
  printf 'generated=true\n' > "${HOME}/.config/sample/settings.conf"
  printf '# demo\n' > "${HOME}/.agents/skills/demo/SKILL.md"

  source_generator

  local repo_dir="${TEST_DIR}/install_safety/out"
  GEN_NO_PUSH=true
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "install safety test repo generates"
  else
    GEN_NO_PUSH=false
    ko "install safety test repo generates" "generate_repo failed"
    return
  fi
  GEN_NO_PUSH=false

  local fake_bin="${TEST_DIR}/install_safety/bin"
  local dry_home="${TEST_DIR}/install_safety/new-home"
  local brew_log="${TEST_DIR}/install_safety/brew.log"
  local rsync_log="${TEST_DIR}/install_safety/rsync.log"
  local stdout_file="${TEST_DIR}/install_safety/install.stdout"
  local stderr_file="${TEST_DIR}/install_safety/install.stderr"
  mkdir -p "$fake_bin" "$dry_home/.config/sample" "$dry_home/.agents/skills"
  printf 'keep=true\n' > "$dry_home/.config/sample/existing.conf"
  printf 'local\n' > "$dry_home/.agents/skills/local-only.txt"

  cat > "${fake_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "${fake_bin}/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${BREW_LOG:?}"
case "${1:-}" in
  shellenv)
    exit 0
    ;;
esac
exit 0
EOF
  cat > "${fake_bin}/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${RSYNC_LOG:?}"
delete=false
args=()
for arg in "$@"; do
  if [[ "$arg" == "--delete" ]]; then
    delete=true
    continue
  fi
  args+=("$arg")
done
src="${args[$((${#args[@]} - 2))]}"
dest="${args[$((${#args[@]} - 1))]}"
mkdir -p "$dest"
if [[ "$delete" == true ]]; then
  find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi
cp -a "${src%/}/." "$dest/"
EOF
  chmod +x "${fake_bin}/sudo" "${fake_bin}/brew" "${fake_bin}/rsync"

  if HOME="$dry_home" BREW_LOG="$brew_log" RSYNC_LOG="$rsync_log" PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" BREW_UPGRADE=false INSTALL_DOTFRIEND=false "$repo_dir/install.sh" >"$stdout_file" 2>"$stderr_file"; then
    ok "install.sh continues when sudo keepalive is unavailable"
  else
    ko "install.sh continues when sudo keepalive is unavailable" "install.sh aborted"
  fi

  if [[ -f "$dry_home/.config/sample/settings.conf" && ! -e "$dry_home/.config/sample/sample/settings.conf" ]]; then
    ok "_copy restores directory contents without nesting source directory"
  else
    ko "_copy restores directory contents without nesting source directory" "directory copy nested unexpectedly"
  fi

  if [[ -f "$dry_home/.config/sample/existing.conf" ]]; then
    ok "_copy preserves existing destination files after backup"
  else
    ko "_copy preserves existing destination files after backup" "existing destination file was removed"
  fi

  if [[ -f "$dry_home/.agents/skills/local-only.txt" ]] && ! grep -Fq -- '--delete' "$rsync_log"; then
    ok "_rsync_agent avoids destructive delete behavior"
  else
    ko "_rsync_agent avoids destructive delete behavior" "rsync used --delete or removed local-only file"
  fi
}

test_install_exit_status_contract() {
  setup_case "install_exit_contract"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [],
  "formulae": ["git"],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [],
  "config_dirs": [],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "install-exit-contract", "private": true}
}
EOF

  source_generator

  local repo_dir="${TEST_DIR}/install_exit_contract/out"
  GEN_NO_PUSH=true
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "install exit contract test repo generates"
  else
    GEN_NO_PUSH=false
    ko "install exit contract test repo generates" "generate_repo failed"
    return
  fi
  GEN_NO_PUSH=false

  local fake_bin="${TEST_DIR}/install_exit_contract/bin"
  local soft_home="${TEST_DIR}/install_exit_contract/soft-home"
  local soft_stdout="${TEST_DIR}/install_exit_contract/soft.stdout"
  local soft_stderr="${TEST_DIR}/install_exit_contract/soft.stderr"
  mkdir -p "$fake_bin" "$soft_home"

  cat > "${fake_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "${fake_bin}/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  shellenv|update|upgrade)
    exit 0
    ;;
  install)
    exit 44
    ;;
esac
exit 0
EOF
  chmod +x "${fake_bin}/sudo" "${fake_bin}/brew"

  if HOME="$soft_home" PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin" BREW_UPGRADE=false INSTALL_DOTFRIEND=false "$repo_dir/install.sh" >"$soft_stdout" 2>"$soft_stderr"; then
    ok "soft package restore failures exit zero"
  else
    ko "soft package restore failures exit zero" "install.sh returned nonzero for brew install miss"
  fi

  if grep -Fq 'Command failed: brew install git' "$soft_stderr" && grep -Fq 'warning(s)' "$soft_stdout"; then
    ok "soft package restore failures are summarized as warnings"
  else
    ko "soft package restore failures are summarized as warnings" "missing warning summary for package miss"
  fi

  local critical_home="${TEST_DIR}/install_exit_contract/critical-home"
  local critical_bin="${TEST_DIR}/install_exit_contract/critical-bin"
  local critical_stdout="${TEST_DIR}/install_exit_contract/critical.stdout"
  local critical_stderr="${TEST_DIR}/install_exit_contract/critical.stderr"
  mkdir -p "$critical_home" "$critical_bin"

  cat > "${critical_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "${critical_bin}/curl" <<'EOF'
#!/usr/bin/env bash
printf 'exit 42\n'
EOF
  chmod +x "${critical_bin}/sudo" "${critical_bin}/curl"

  if HOME="$critical_home" PATH="${critical_bin}:/usr/bin:/bin:/usr/sbin:/sbin" BREW_UPGRADE=false INSTALL_DOTFRIEND=false "$repo_dir/install.sh" >"$critical_stdout" 2>"$critical_stderr"; then
    ko "critical prerequisite failures exit nonzero" "install.sh succeeded after Homebrew install failure"
  else
    ok "critical prerequisite failures exit nonzero"
  fi
}

test_install_runs_app_setup_before_config_restore() {
  setup_case "install_order"
  cat > "${DOTFRIEND_CACHE_DIR}/selections.json" <<'EOF'
{
  "apps": [],
  "agents": [],
  "formulae": ["aichat"],
  "taps": [],
  "npm_globals": [],
  "dotfiles": [],
  "config_dirs": ["aichat"],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "install-order", "private": true}
}
EOF
  mkdir -p "${HOME}/.config/aichat"
  printf 'model: test\n' > "${HOME}/.config/aichat/config.yaml"

  source_generator

  local repo_dir="${TEST_DIR}/install_order/out"
  GEN_NO_PUSH=true
  if generate_repo "$repo_dir" false >/dev/null 2>&1; then
    ok "install order test repo generates"
  else
    GEN_NO_PUSH=false
    ko "install order test repo generates" "generate_repo failed"
    return
  fi
  GEN_NO_PUSH=false

  local apps_line config_line
  apps_line="$(grep -n '^  phase_apps' "${repo_dir}/install.sh" | head -n1 | cut -d: -f1)"
  config_line="$(grep -n '^  phase_configuration' "${repo_dir}/install.sh" | head -n1 | cut -d: -f1)"
  if [[ -n "$apps_line" && -n "$config_line" && "$apps_line" -lt "$config_line" ]]; then
    ok "install.sh runs app setup before config restore"
  else
    ko "install.sh runs app setup before config restore" "phase_configuration still runs before phase_apps"
  fi

  if grep -Fq '  ensure_dir "$(dirname "$dest")"' "${repo_dir}/install.sh"; then
    ok "configuration copy creates missing parent directories"
  else
    ko "configuration copy creates missing parent directories" "_copy does not create destination parent"
  fi
}

printf '\n1. Generation regressions\n'
test_repo_name_and_github_push
test_agent_and_shared_config_copy
test_filtered_recursive_copy_and_layout
test_cursor_extension_manifest_and_metadata
test_backend_generate_events_and_cached_editor_extensions
test_generation_state_skips_unchanged_sections
test_generator_code_changes_invalidate_generated_install_script
test_macos_defaults_generation_and_apply_script
test_install_dry_run_plans_restore_dependencies_without_missing_tool_warnings
test_brewfile_entries_use_real_newlines
test_install_times_out_slow_brew_taps_and_continues
test_install_continues_when_brew_update_fails
test_generated_restore_artifacts_are_portable_and_package_safe
test_empty_filtered_config_dirs_do_not_break_cloned_restore_artifacts
test_generated_validation_catches_restore_artifact_issues
test_install_handles_sudo_copy_and_rsync_safely
test_install_exit_status_contract
test_install_runs_app_setup_before_config_restore

printf '\n========================================\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '========================================\n'

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
