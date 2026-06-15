#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/shreyasgupta/local-documents/dotfriend"
TEST_DIR="$(mktemp -d)"
trap "rm -rf '$TEST_DIR'" EXIT

export HOME="${TEST_DIR}/home"
export DOTFRIEND_APP_SEARCH_DIRS="${TEST_DIR}/system-apps:${HOME}/Applications"
export PATH="${TEST_DIR}/bin:${PATH}"

mkdir -p "${HOME}/.cache/dotfriend" "${HOME}/Applications" "${TEST_DIR}/system-apps" "${TEST_DIR}/bin"

cat > "${HOME}/.cache/dotfriend/cask-api.json" <<'EOF'
[
  {
    "token": "chatgpt",
    "name": ["ChatGPT"],
    "artifacts": [{"app": ["ChatGPT.app"]}]
  },
  {
    "token": "chatgpt@beta",
    "name": ["ChatGPT"],
    "artifacts": [{"app": ["ChatGPT.app"]}]
  },
  {
    "token": "diashapes",
    "name": ["Dia"],
    "artifacts": [{"app": ["Shapes.app"]}]
  },
  {
    "token": "thebrowsercompany-dia",
    "name": ["Dia"],
    "artifacts": [{"app": ["Dia.app"]}]
  },
  {
    "token": "paper-design",
    "name": ["Paper"],
    "artifacts": [{"app": ["Paper.app"]}]
  },
  {
    "token": "logi-options+",
    "name": ["Logitech Options+"],
    "artifacts": [
      {
        "uninstall": [
          {
            "delete": ["/Applications/logioptionsplus.app"]
          }
        ]
      }
    ]
  },
  {
    "token": "jdownloader",
    "name": ["JDownloader"],
    "artifacts": [
      {
        "uninstall": [
          {
            "delete": ["$APPDIR/JDownloader2.app"]
          }
        ]
      }
    ]
  },
  {
    "token": "karabiner-elements",
    "name": ["Karabiner Elements"],
    "artifacts": [
      {
        "installer": [
          {
            "script": {
              "executable": "Karabiner-Elements Installer.app/Contents/MacOS/installer"
            }
          }
        ]
      }
    ]
  },
  {
    "token": "cables",
    "name": ["Cables"],
    "artifacts": [{"app": ["cables-0.10.6.app"]}]
  }
]
EOF

mkdir -p "${TEST_DIR}/system-apps/ChatGPT.app/Contents"
mkdir -p "${TEST_DIR}/system-apps/Dia.app/Contents"
mkdir -p "${TEST_DIR}/system-apps/JDownloader2.app/Contents"
mkdir -p "${TEST_DIR}/system-apps/Karabiner-Elements.app/Contents"
mkdir -p "${TEST_DIR}/system-apps/Karabiner-EventViewer.app/Contents"
mkdir -p "${TEST_DIR}/system-apps/.Karabiner-VirtualHIDDevice-Manager.app/Contents"
mkdir -p "${TEST_DIR}/system-apps/cables-0.10.5.app/Contents"
mkdir -p "${HOME}/Applications/Paper.app/Contents"
mkdir -p "${HOME}/Applications/logioptionsplus.app/Contents"
mkdir -p "${TEST_DIR}/system-apps/AppStoreOnly.app/Contents/_MASReceipt"
mkdir -p "${TEST_DIR}/system-apps/Things3.app/Contents/_MASReceipt"
mkdir -p "${TEST_DIR}/system-apps/ReceiptOnly.app/Contents/_MASReceipt"
mkdir -p "${TEST_DIR}/system-apps/Manual.app/Contents"

cat > "${TEST_DIR}/system-apps/AppStoreOnly.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.appstore-only</string>
</dict>
</plist>
EOF

cat > "${TEST_DIR}/system-apps/ReceiptOnly.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.receipt-only</string>
</dict>
</plist>
EOF

cat > "${TEST_DIR}/bin/mas" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "list" ]]; then
  printf '%s\n' '123456789 AppStoreOnly (1.0)'
  printf '%s\n' '987654321 Things 3 (3.0)'
fi
EOF
chmod +x "${TEST_DIR}/bin/mas"

source "${PROJECT}/lib/discovery.sh"

OUTPUT="$(discover_apps)"

assert_has_line() {
  local expected="$1"
  if ! printf '%s\n' "$OUTPUT" | grep -Fqx "$expected"; then
    printf 'Missing expected line: %s\n' "$expected" >&2
    printf 'Actual output:\n%s\n' "$OUTPUT" >&2
    exit 1
  fi
}

assert_has_line "AppStoreOnly|mas:AppStoreOnly,id:123456789"
assert_has_line "ChatGPT|cask:chatgpt"
assert_has_line "Dia|cask:thebrowsercompany-dia"
assert_has_line "JDownloader2|cask:jdownloader"
assert_has_line "Karabiner-Elements|cask:karabiner-elements"
assert_has_line "Karabiner-EventViewer|cask:karabiner-elements"
assert_has_line "Manual|manual"
assert_has_line "ReceiptOnly|appstore:com.example.receipt-only"
assert_has_line "Things3|mas:Things 3,id:987654321"
assert_has_line "cables-0.10.5|cask:cables"
assert_has_line "logioptionsplus|cask:logi-options+"
assert_has_line "Paper|cask:paper-design"
assert_has_line ".Karabiner-VirtualHIDDevice-Manager|cask:karabiner-elements"

cat > "${TEST_DIR}/bin/code" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list-extensions" ]]; then
  sleep 4
  printf 'slow.extension\n'
fi
EOF
chmod +x "${TEST_DIR}/bin/code"

export DOTFRIEND_OPTIONAL_COMMAND_TIMEOUT=1
start_seconds="$(date +%s)"
vscode_output="$(discover_vscode)"
elapsed_seconds="$(($(date +%s) - start_seconds))"

if [[ "$elapsed_seconds" -ge 4 ]]; then
  printf 'discover_vscode did not time out optional editor CLI quickly enough\n' >&2
  exit 1
fi
if printf '%s\n' "$vscode_output" | grep -q 'slow.extension'; then
  printf 'discover_vscode included output from a timed-out editor CLI\n' >&2
  exit 1
fi

cat > "${TEST_DIR}/macos-defaults-test.json" <<'EOF'
{
  "schema_version": 1,
  "catalog_version": "test-catalog",
  "entries": [
    {
      "id": "dock.orientation",
      "category": "Dock",
      "title": "Dock position",
      "description": "Where the Dock appears.",
      "domain": "com.apple.dock",
      "key": "orientation",
      "scope": "user",
      "value_type": "string",
      "default_value": "bottom",
      "risk": "safe",
      "default_selected": true,
      "restart": ["Dock"],
      "source": "https://macos-defaults.com/dock/orientation.html"
    },
    {
      "id": "safari.auto-open-safe-downloads",
      "category": "Safari",
      "title": "Open safe downloads automatically",
      "description": "Whether Safari opens safe downloads automatically.",
      "domain": "com.apple.Safari",
      "key": "AutoOpenSafeDownloads",
      "scope": "user",
      "value_type": "bool",
      "default_value": true,
      "risk": "risky",
      "default_selected": false,
      "restart": ["Safari"],
      "source": "https://macos-defaults.com/safari/autoopensafedownloads.html"
    },
    {
      "id": "finder.missing",
      "category": "Finder",
      "title": "Missing Finder setting",
      "description": "A setting missing on this machine.",
      "domain": "com.apple.finder",
      "key": "MissingKey",
      "scope": "user",
      "value_type": "bool",
      "default_value": false,
      "risk": "safe",
      "default_selected": true,
      "restart": ["Finder"],
      "source": "https://macos-defaults.com/finder/missing.html"
    },
    {
      "id": "keyboard.key-repeat",
      "category": "Keyboard",
      "title": "Key repeat speed",
      "description": "Repeat speed for held keys.",
      "domain": "NSGlobalDomain",
      "key": "KeyRepeat",
      "scope": "user",
      "value_type": "int",
      "default_value": 6,
      "risk": "safe",
      "default_selected": true,
      "restart": [],
      "source": "https://macos-defaults.com/keyboard/keyrepeat.html"
    },
    {
      "id": "trackpad.current-host",
      "category": "Trackpad",
      "title": "Current host trackpad setting",
      "description": "A current-host-only setting.",
      "domain": "com.apple.trackpad.test",
      "key": "CurrentHostSetting",
      "scope": "currentHost",
      "value_type": "int",
      "default_value": 0,
      "risk": "safe",
      "default_selected": true,
      "restart": [],
      "source": "https://macos-defaults.com/trackpad/currenthost.html"
    }
  ]
}
EOF

cat > "${TEST_DIR}/bin/defaults" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${DEFAULTS_CALL_LOG:?}"

current_host=false
if [[ "${1:-}" == "-currentHost" ]]; then
  current_host=true
  shift
fi

cmd="${1:-}"
domain="${2:-}"
key="${3:-}"

case "${cmd}|${current_host}|${domain}|${key}" in
  "read-type|false|com.apple.dock|orientation") printf 'Type is string\n' ;;
  "read|false|com.apple.dock|orientation") printf 'left\n' ;;
  "read-type|false|com.apple.Safari|AutoOpenSafeDownloads") printf 'Type is boolean\n' ;;
  "read|false|com.apple.Safari|AutoOpenSafeDownloads") printf '1\n' ;;
  "read-type|false|com.apple.finder|MissingKey") sleep 6; exit 1 ;;
  "read-type|false|NSGlobalDomain|KeyRepeat") printf 'Type is float\n' ;;
  "read|false|NSGlobalDomain|KeyRepeat") printf '2\n' ;;
  "read-type|true|com.apple.trackpad.test|CurrentHostSetting") printf 'Type is integer\n' ;;
  "read|true|com.apple.trackpad.test|CurrentHostSetting") printf '2\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${TEST_DIR}/bin/defaults"

export DEFAULTS_CALL_LOG="${TEST_DIR}/defaults-calls.log"
export DOTFRIEND_OPTIONAL_COMMAND_TIMEOUT=5
export DOTFRIEND_MACOS_DEFAULTS_COMMAND_TIMEOUT=1
start_seconds="$(date +%s)"
macos_defaults_output="$(discover_macos_defaults "${TEST_DIR}/macos-defaults-test.json")"
elapsed_seconds="$(($(date +%s) - start_seconds))"

if [[ "$elapsed_seconds" -ge 5 ]]; then
  printf 'discover_macos_defaults did not time out a slow missing defaults key quickly enough\n' >&2
  exit 1
fi

printf '%s\n' "$macos_defaults_output" | jq -e '.catalog_version == "test-catalog"' >/dev/null
printf '%s\n' "$macos_defaults_output" | jq -e '.counts.found == 4 and .counts.missing == 1 and .counts.risky == 1' >/dev/null
printf '%s\n' "$macos_defaults_output" | jq -e '.items[] | select(.id == "dock.orientation" and .value == "left" and .risk == "safe" and .default_selected == true)' >/dev/null
printf '%s\n' "$macos_defaults_output" | jq -e '.items[] | select(.id == "safari.auto-open-safe-downloads" and .value == true and .risk == "risky" and .default_selected == false)' >/dev/null
printf '%s\n' "$macos_defaults_output" | jq -e '.items[] | select(.id == "keyboard.key-repeat" and .value == 2 and .value_type == "int")' >/dev/null
printf '%s\n' "$macos_defaults_output" | jq -e '.items[] | select(.id == "trackpad.current-host" and .value == 2 and .scope == "currentHost")' >/dev/null
if ! grep -Fqx -- '-currentHost read com.apple.trackpad.test CurrentHostSetting' "$DEFAULTS_CALL_LOG"; then
  printf 'current-host defaults read was not invoked\n' >&2
  cat "$DEFAULTS_CALL_LOG" >&2
  exit 1
fi

tmp_cache_dir="${TEST_DIR}/cache-assembly"
mkdir -p "$tmp_cache_dir"
printf '%s\n' "$macos_defaults_output" > "${tmp_cache_dir}/macos_defaults.json"
cache_file="${TEST_DIR}/discovery-with-defaults.json"
write_discovery_v2 "$tmp_cache_dir" "$cache_file"
jq -e '.macos_defaults.items[] | select(.id == "dock.orientation")' "$cache_file" >/dev/null

bad_catalog="${TEST_DIR}/bad-macos-defaults.json"
jq 'del(.entries[0].id)' "${TEST_DIR}/macos-defaults-test.json" > "$bad_catalog"
if macos_defaults_validate_catalog "$bad_catalog" >/dev/null 2>&1; then
  printf 'malformed macOS defaults catalog was accepted\n' >&2
  exit 1
fi

printf 'discovery_strategy_test: ok\n'
