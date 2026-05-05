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

printf 'discovery_strategy_test: ok\n'
