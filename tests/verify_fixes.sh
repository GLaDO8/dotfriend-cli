#!/usr/bin/env bash
# Verification script for dotfriend fixes
set -euo pipefail

PROJECT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"
export HOME="$TEST_DIR"
export DOTFRIEND_CACHE_DIR="${HOME}/.cache/dotfriend"
mkdir -p "$DOTFRIEND_CACHE_DIR"

cd "$PROJECT"

PASS=0
FAIL=0

ok() { printf "  ✅ %s\n" "$1"; ((PASS++)) || true; }
ko() { printf "  ❌ %s: %s\n" "$1" "$2"; ((FAIL++)) || true; }

# ── 1. Syntax check all bash files ──
printf "\n1. Syntax checks\n"
for f in dotfriend lib/*.sh templates/*.sh templates/scripts/*.sh; do
  if [[ -f "$f" ]] && bash -n "$f"; then
    ok "bash -n $f"
  else
    ko "bash -n $f" "syntax error"
  fi
done

# ── 2. CLI basics ──
printf "\n2. CLI basics\n"
if ./dotfriend --help >/dev/null 2>&1; then ok "--help"; else ko "--help" "failed"; fi
if ./dotfriend --version | grep -q "0.3.0"; then ok "--version"; else ko "--version" "wrong output"; fi
if ! ./dotfriend badcmd >/dev/null 2>&1; then ok "unknown command exits non-zero"; else ko "unknown command" "should fail"; fi
if grep -q 'source "${LIB_DIR}/bootstrap.sh"' dotfriend; then ok "bootstrap module sourced"; else ko "bootstrap module" "missing"; fi
if grep -q 'DOTFRIEND_RUNTIME_BOOTSTRAPPED=true' dotfriend; then ok "entrypoint re-execs after bootstrap"; else ko "bootstrap re-exec" "missing"; fi

# ── 3. Entry script local bug ──
printf "\n3. Entry script fix\n"
if ! grep -q 'local dry_run=false' dotfriend; then ok "no local dry_run in dotfriend"; else ko "local dry_run" "still present"; fi
if ! grep -q 'dotfriend will continue, but some features may be limited' dotfriend; then ok "no partial dependency mode"; else ko "partial dependency mode" "still present"; fi

# ── 4. Discovery EXIT trap ──
printf "\n4. Discovery EXIT trap fix\n"
if grep -q 'trap "rm -rf' lib/discovery.sh; then ok "trap uses double quotes"; else ko "trap" "not fixed"; fi

# ── 5. Validate.sh fixes ──
printf "\n5. validate.sh fixes\n"
if ! grep -n '^local ' templates/scripts/validate.sh | grep -v '^[0-9]*:\s*local ' >/dev/null 2>&1; then
  # Check that there are no top-level local declarations
  # Actually just check the specific lines
  if ! grep -q '^local first=true' templates/scripts/validate.sh; then ok "no top-level local"; else ko "top-level local" "still present"; fi
else
  ok "no top-level local"
fi
if grep -q '((total_pass++)) || true' templates/scripts/validate.sh; then ok "arithmetic guarded"; else ko "arithmetic" "not guarded"; fi

# ── 6. Sync.sh fixes ──
printf "\n6. sync.sh fixes\n"
if grep -q ".agents // empty | .\[\] | .id" lib/sync.sh; then ok "agent jq query fixed"; else ko "agent jq" "not fixed"; fi
if grep -q 'REPO_DIR="\$(_find_repo)" || true' lib/sync.sh; then ok "find_repo set -e fix"; else ko "find_repo" "not fixed"; fi
if grep -q 'npm list -g --depth=0 --json' lib/sync.sh; then ok "npm JSON parsing"; else ko "npm parsing" "not fixed"; fi

# ── 7. Gum.sh fixes ──
printf "\n7. gum.sh fixes\n"
if grep -q 'gum confirm "\$prompt_text" "\${args\[@\]}"' lib/gum.sh; then ok "gum_confirm translates --prompt correctly"; else ko "gum_confirm" "not fixed"; fi
if grep -q 'shift 2' lib/gum.sh; then ok "gum_spin consumes args"; else ko "gum_spin" "not fixed"; fi
if grep -q 'GUM_CHOOSE_SHOW_HELP="true"' lib/gum.sh; then ok "gum choose built-in footer enabled"; else ko "gum choose footer" "built-in footer is disabled"; fi
if ! grep -q 'GUM_CHOOSE_MULTISELECT_HELP=' lib/gum.sh; then ok "gum choose no longer pushes help into header"; else ko "gum choose header help" "custom header help still present"; fi

# ── 8. Wizard output stays quiet ──
printf "\n8. Wizard output stays quiet\n"
if ! grep -q 'cat "\$SELECTIONS_FILE"' lib/wizard.sh; then ok "wizard no longer dumps selections json"; else ko "wizard json dump" "still present"; fi
if ! grep -q "printf '%s\\\\n' \"\$SELECTIONS_FILE\"" lib/wizard.sh; then ok "wizard no longer prints selections file path"; else ko "wizard selections path" "still present"; fi

# ── 9. cask-map.json dedup ──
printf "\n9. cask-map.json dedup\n"
DUPES=$(python3 -c "
import json, re
from collections import Counter
with open('lib/cask-map.json') as f:
    keys = re.findall(r'\"([^\"]+)\"\s*:', f.read())
dupes = [k for k,v in Counter(keys).items() if v > 1]
print(len(dupes))
")
if [[ "$DUPES" == "0" ]]; then ok "zero duplicates"; else ko "duplicates" "$DUPES remaining"; fi

# ── 10. Generated script guards ──
printf "\n10. Template guards\n"
if grep -q 'rm -rf "\$dest" || {' templates/install.sh; then ok "install.sh symlink guarded"; else ko "symlink guard" "missing"; fi
if grep -q 'npm install -g dotfriend' templates/install.sh && grep -q 'last-sync.json' templates/install.sh; then ok "install.sh bootstraps dotfriend sync"; else ko "dotfriend install" "missing"; fi
if grep -q 'git clone' templates/bootstrap.sh | grep -q '|| {' templates/bootstrap.sh; then
  ok "bootstrap.sh git clone guarded"
else
  # Check separately
  if grep -A1 'git clone' templates/bootstrap.sh | grep -q '||'; then ok "bootstrap.sh git clone guarded"; else ko "git clone guard" "missing"; fi
fi
if grep -q 'config_dir:?' templates/scripts/backup.sh; then ok "backup.sh rm -rf safe"; else ko "backup.sh safety" "missing"; fi

# ── 11. Test with mock selections ──
printf "\n11. Repo generation with mock selections\n"
cat > "$DOTFRIEND_CACHE_DIR/selections.json" <<'EOF'
{
  "apps": [{"name":"Spotify","cask":"spotify","source":"cask"}],
  "agents": [{"id":"claude","name":"Claude Code"}],
  "formulae": ["git"],
  "taps": ["homebrew/cask"],
  "npm_globals": [],
  "dotfiles": [".zshrc"],
  "config_dirs": [],
  "editors": {"vscode": false, "cursor": false},
  "dock": {"backup": false, "defaults": false},
  "xcode": false,
  "telemetry": false,
  "github": {"repo_name": "dotfiles", "private": true}
}
EOF

# Create fake dotfiles
printf "# zshrc\n" > "${HOME}/.zshrc"
mkdir -p "${HOME}/.claude"
printf "# claude md\n" > "${HOME}/.claude/CLAUDE.md"

# Source generate and run
source lib/common.sh
source lib/generate.sh
if generate_repo "${TEST_DIR}/dotfiles_test" "false" 2>/dev/null; then
  ok "generate_repo succeeded"
else
  ko "generate_repo" "failed"
fi

if [[ -f "${TEST_DIR}/dotfiles_test/install.sh" ]]; then ok "install.sh created"; else ko "install.sh" "missing"; fi
if [[ -f "${TEST_DIR}/dotfiles_test/bootstrap.sh" ]]; then ok "bootstrap.sh created"; else ko "bootstrap.sh" "missing"; fi
if [[ -f "${TEST_DIR}/dotfiles_test/Brewfile" ]]; then ok "Brewfile created"; else ko "Brewfile" "missing"; fi

# Check no remaining placeholders
if ! grep -q '{{' "${TEST_DIR}/dotfiles_test/install.sh" 2>/dev/null; then ok "no placeholders in install.sh"; else ko "placeholders" "still in install.sh"; fi
if grep -q 'npm install -g dotfriend' "${TEST_DIR}/dotfiles_test/install.sh" && grep -q 'last-sync.json' "${TEST_DIR}/dotfiles_test/install.sh"; then ok "generated install.sh registers dotfriend sync"; else ko "generated dotfriend sync registration" "missing"; fi

# Syntax check generated scripts
if bash -n "${TEST_DIR}/dotfiles_test/install.sh" 2>/dev/null; then ok "generated install.sh syntax OK"; else ko "install.sh syntax" "error"; fi
if bash -n "${TEST_DIR}/dotfiles_test/bootstrap.sh" 2>/dev/null; then ok "generated bootstrap.sh syntax OK"; else ko "bootstrap.sh syntax" "error"; fi

# ── 12. Generation regressions ──
printf "\n12. Generation regressions\n"
if bash tests/generate_regressions.sh; then ok "generate regressions"; else ko "generate regressions" "failed"; fi

# ── Summary ──
printf "\n========================================\n"
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
printf "========================================\n"

rm -rf "$TEST_DIR"

if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
