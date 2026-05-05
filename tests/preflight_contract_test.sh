#!/usr/bin/env bash
# Verify preflight is non-mutating and reports missing runtime tools.
set -euo pipefail

PROJECT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
REAL_JQ="$(command -v jq)"

FAKE_BIN="${TEST_DIR}/bin"
HOME_DIR="${TEST_DIR}/home"
mkdir -p "$FAKE_BIN" "$HOME_DIR/.cache/dotfriend"

cat > "${FAKE_BIN}/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH

cat > "${FAKE_BIN}/xcode-select" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -p) printf '/Library/Developer/CommandLineTools\n' ;;
  --install)
    printf 'xcode-select --install should not run during preflight\n' >&2
    exit 44
    ;;
esac
SH

cat > "${FAKE_BIN}/git" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "${FAKE_BIN}/gum" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "${FAKE_BIN}/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "${FAKE_BIN}/mas" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "${FAKE_BIN}/npm" <<'SH'
#!/usr/bin/env bash
exit 0
SH

chmod +x "${FAKE_BIN}"/*

export HOME="$HOME_DIR"
export DOTFRIEND_CACHE_DIR="${HOME}/.cache/dotfriend"
export BREW_CALLED_FILE="${TEST_DIR}/brew-called"
export PATH="${FAKE_BIN}:/bin:/usr/bin"

cd "$PROJECT"

output="$(./dotfriend preflight --json)"

printf '%s\n' "$output" | "$REAL_JQ" -e '.command == "preflight"' >/dev/null
printf '%s\n' "$output" | "$REAL_JQ" -e '.status == "needs_approval"' >/dev/null
printf '%s\n' "$output" | "$REAL_JQ" -e '.data.requires_approval == true' >/dev/null
printf '%s\n' "$output" | "$REAL_JQ" -e '.data.checks[] | select(.id == "jq" and .status == "needs_install")' >/dev/null
printf '%s\n' "$output" | "$REAL_JQ" -e '.data.checks[] | select(.id == "homebrew" and .status == "missing")' >/dev/null

if [[ -s "$BREW_CALLED_FILE" ]]; then
  printf 'preflight invoked fake brew unexpectedly\n' >&2
  cat "$BREW_CALLED_FILE" >&2
  exit 1
fi

START_LOG="${TEST_DIR}/start.log"
set +e
timeout 3 ./dotfriend start --no-bootstrap --dry-run >"$START_LOG" 2>&1
start_code=$?
set -e
if [[ "$start_code" == "43" || -s "$BREW_CALLED_FILE" ]]; then
  printf 'dotfriend start --no-bootstrap invoked fake brew\n' >&2
  exit 1
fi

printf 'preflight contract ok\n'
