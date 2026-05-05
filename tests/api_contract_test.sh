#!/usr/bin/env bash
# Verify dotfriend JSON API envelope behavior.
set -euo pipefail

PROJECT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
REAL_JQ="$(command -v jq)"

export HOME="${TEST_DIR}/home"
export DOTFRIEND_CACHE_DIR="${HOME}/.cache/dotfriend"
FAKE_BIN="${TEST_DIR}/bin"
mkdir -p "$DOTFRIEND_CACHE_DIR" "$FAKE_BIN"

cat > "${FAKE_BIN}/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH

cat > "${FAKE_BIN}/xcode-select" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -p) printf '/Library/Developer/CommandLineTools\n' ;;
esac
SH

cat > "${FAKE_BIN}/brew" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) exit 0 ;;
esac
exit 0
SH

for cmd in git gum gh mas npm; do
  cat > "${FAKE_BIN}/${cmd}" <<'SH'
#!/usr/bin/env bash
exit 0
SH
done
cat > "${FAKE_BIN}/jq" <<SH
#!/usr/bin/env bash
exec "${REAL_JQ}" "\$@"
SH
chmod +x "${FAKE_BIN}"/*
export PATH="${FAKE_BIN}:/bin:/usr/bin"

cd "$PROJECT"

output="$(./dotfriend preflight --json)"

printf '%s\n' "$output" | jq -e '.contract_version == 1' >/dev/null
printf '%s\n' "$output" | jq -e '.command == "preflight"' >/dev/null
printf '%s\n' "$output" | jq -e 'has("status") and has("warnings") and has("errors") and has("data")' >/dev/null

if printf '%s' "$output" | LC_ALL=C grep -q "$(printf '\033')"; then
  printf 'stdout contains ANSI escape bytes\n' >&2
  exit 1
fi

printf 'api contract ok\n'
