#!/usr/bin/env bash
# dotfriend — macOS preference backup helpers
# shellcheck shell=bash

set -euo pipefail

MACOS_PREFERENCE_CATEGORIES=(
  "global_ui|Global UI and typing preferences"
  "dock|Dock settings beyond app order"
  "finder|Finder and Desktop preferences"
  "input_devices|Trackpad, mouse, and input devices"
  "keyboard_shortcuts|Keyboard shortcuts and input settings"
  "mission_control|Mission Control, Spaces, Stage Manager, and windows"
  "menu_bar|Menu bar and Control Center"
  "screenshots|Screenshots and screen recording defaults"
  "wallpaper_screensaver|Wallpaper, screen saver, and lock screen"
  "accessibility|Accessibility preferences"
  "notifications_focus|Notifications and Focus"
  "spotlight_siri|Spotlight and Siri"
  "default_apps|Default apps and URL/file handlers"
  "login_items|Login items and background items report"
  "energy|Energy, battery, and power settings"
  "network|Network service, DNS, proxy, and computer name report"
  "sharing|Sharing, AirDrop, AirPlay, and Handoff preferences"
  "security_privacy|Security and privacy posture report"
  "software_update|Software Update and App Store preferences"
  "time_machine|Time Machine settings report"
  "printers|Printers, scanners, and CUPS settings report"
  "services_extensions|Services, Share menu, and Extensions"
  "apple_apps|Apple app-specific preferences"
)

MACOS_RECOMMENDED_PREFERENCE_CATEGORIES=(
  global_ui
  dock
  finder
  input_devices
  keyboard_shortcuts
  mission_control
  menu_bar
  screenshots
  wallpaper_screensaver
  accessibility
  notifications_focus
  spotlight_siri
  default_apps
  login_items
  energy
  network
  sharing
  security_privacy
  software_update
  time_machine
  printers
  services_extensions
  apple_apps
)

macos_preference_category_ids() {
  local item
  for item in "${MACOS_PREFERENCE_CATEGORIES[@]}"; do
    printf '%s\n' "${item%%|*}"
  done
}

macos_recommended_preference_category_ids() {
  local item
  for item in "${MACOS_RECOMMENDED_PREFERENCE_CATEGORIES[@]}"; do
    printf '%s\n' "$item"
  done
}

macos_preference_category_label() {
  local id="$1" item
  for item in "${MACOS_PREFERENCE_CATEGORIES[@]}"; do
    if [[ "${item%%|*}" == "$id" ]]; then
      printf '%s' "${item#*|}"
      return 0
    fi
  done
  printf '%s' "$id"
}

macos_preference_domains_for_category() {
  case "$1" in
    global_ui)
      printf '%s\n' NSGlobalDomain .GlobalPreferences
      ;;
    dock)
      printf '%s\n' com.apple.dock
      ;;
    finder)
      printf '%s\n' com.apple.finder com.apple.desktopservices
      ;;
    input_devices)
      printf '%s\n' \
        com.apple.AppleMultitouchTrackpad \
        com.apple.driver.AppleBluetoothMultitouch.trackpad \
        com.apple.AppleMultitouchMouse \
        com.apple.driver.AppleBluetoothMultitouch.mouse \
        com.apple.driver.AppleHIDMouse \
        com.apple.Multitouch.preferencesBackup
      ;;
    keyboard_shortcuts)
      printf '%s\n' \
        com.apple.symbolichotkeys \
        com.apple.keyboard \
        com.apple.keyboard.preferences \
        com.apple.HIToolbox \
        com.apple.TextInputMenu \
        com.apple.TextInputMenuAgent
      ;;
    mission_control)
      printf '%s\n' com.apple.spaces com.apple.WindowManager
      ;;
    menu_bar)
      printf '%s\n' com.apple.controlcenter com.apple.systemuiserver com.apple.menuextra.clock
      ;;
    screenshots)
      printf '%s\n' com.apple.screencapture
      ;;
    wallpaper_screensaver)
      printf '%s\n' \
        com.apple.wallpaper \
        com.apple.wallpaper.agent \
        com.apple.wallpaper.aerial \
        com.apple.screensaver \
        com.apple.loginwindow
      ;;
    accessibility)
      printf '%s\n' \
        com.apple.universalaccess \
        com.apple.Accessibility \
        com.apple.AccessibilityHearingNearby \
        com.apple.mediaaccessibility.public \
        com.apple.SpeakSelection
      ;;
    notifications_focus)
      printf '%s\n' com.apple.ncprefs com.apple.notificationcenterui com.apple.donotdisturbd
      ;;
    spotlight_siri)
      printf '%s\n' \
        com.apple.Spotlight \
        com.apple.Siri \
        com.apple.assistant \
        com.apple.assistant.support \
        com.apple.assistant.backedup
      ;;
    sharing)
      printf '%s\n' \
        com.apple.sharingd \
        com.apple.airplay \
        com.apple.preferences.sharing.SharingPrefsExtension \
        com.apple.Sharing-Settings.extension
      ;;
    software_update)
      printf '%s\n' com.apple.SoftwareUpdate com.apple.preferences.softwareupdate com.apple.AppStore
      ;;
    services_extensions)
      printf '%s\n' \
        pbs \
        com.apple.ServicesMenu.Services \
        com.apple.ExtensionsPreferences.ShareMenu \
        com.apple.preferences.extensions.ServicesWithUI \
        com.apple.preferences.extensions.ShareMenu
      ;;
    apple_apps)
      printf '%s\n' \
        com.apple.ActivityMonitor \
        com.apple.Console \
        com.apple.DictionaryServices \
        com.apple.FaceTime \
        com.apple.FontBook \
        com.apple.Freeform \
        com.apple.iCal \
        com.apple.iChat \
        com.apple.Maps \
        com.apple.MobileSMS \
        com.apple.Music \
        com.apple.Notes \
        com.apple.Photos \
        com.apple.Preview \
        com.apple.QuickTimePlayerX \
        com.apple.remindd \
        com.apple.Safari \
        com.apple.StocksKitService \
        com.apple.Terminal \
        com.apple.TextEdit \
        com.apple.TV \
        com.apple.weather.widget
      ;;
  esac
}

_macos_safe_filename() {
  printf '%s' "$1" | tr '/:' '__'
}

_macos_export_domain() {
  local domain="$1" dest_dir="$2"
  local file="${dest_dir}/$(_macos_safe_filename "$domain").plist"

  if ! defaults export "$domain" "$file" >/dev/null 2>&1; then
    rm -f "$file"
    return 0
  fi

  # Text replacements often sync via iCloud and commonly contain private snippets.
  if [[ "$domain" == "NSGlobalDomain" || "$domain" == ".GlobalPreferences" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :NSUserDictionaryReplacementItems" "$file" >/dev/null 2>&1 || true
  fi

  if [[ "$domain" == "com.apple.dock" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :persistent-apps" "$file" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Delete :persistent-others" "$file" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Delete :recent-apps" "$file" >/dev/null 2>&1 || true
  fi
}

_macos_write_report() {
  local out="$1"
  shift
  {
    printf '# %s\n\n' "$(basename "$out" .txt)"
    "$@" 2>/dev/null || true
  } > "$out"
}

_macos_backup_default_apps() {
  local dest_dir="$1"
  ensure_dir "$dest_dir"

  local plist json rules
  plist="$(mktemp)"
  json="$(mktemp)"
  rules="${dest_dir}/default-apps.duti"

  if defaults export com.apple.LaunchServices/com.apple.launchservices.secure "$plist" >/dev/null 2>&1 &&
    plutil -convert json -o "$json" "$plist" >/dev/null 2>&1 &&
    command -v jq >/dev/null 2>&1; then
    jq -r '
      def rows:
        . as $item |
        ($item.LSHandlerContentType // $item.LSHandlerURLScheme) as $handler |
        select($handler != null) |
        [
          ["LSHandlerRoleAll", "all"],
          ["LSHandlerRoleViewer", "viewer"],
          ["LSHandlerRoleEditor", "editor"],
          ["LSHandlerRoleShell", "shell"]
        ][] as $role |
        select($item[$role[0]] != null) |
        [$item[$role[0]], $handler, $role[1]];
      .LSHandlers // []
      | map(rows)
      | unique
      | .[]
      | @tsv
    ' "$json" > "$rules" 2>/dev/null || true
  fi

  rm -f "$plist" "$json"
  [[ -s "$rules" ]] || rm -f "$rules"
}

backup_macos_preferences() {
  local dest="$1"
  shift

  local -a categories=("$@")
  [[ ${#categories[@]} -gt 0 ]] || return 0

  local defaults_dir="${dest}/defaults"
  local reports_dir="${dest}/reports"
  ensure_dir "$defaults_dir"
  ensure_dir "$reports_dir"

  local category domain
  for category in "${categories[@]}"; do
    case "$category" in
      default_apps)
        _macos_backup_default_apps "$dest"
        ;;
      login_items)
        _macos_write_report "${reports_dir}/login-items.txt" sfltool dumpbtm
        ;;
      energy)
        _macos_write_report "${reports_dir}/energy.txt" pmset -g custom
        ;;
      network)
        {
          printf '# network\n\n'
          printf 'ComputerName: '; scutil --get ComputerName 2>/dev/null || true
          printf 'HostName: '; scutil --get HostName 2>/dev/null || true
          printf 'LocalHostName: '; scutil --get LocalHostName 2>/dev/null || true
          printf '\nNetwork services:\n'
          networksetup -listallnetworkservices 2>/dev/null || true
          printf '\nHardware ports:\n'
          networksetup -listallhardwareports 2>/dev/null || true
        } > "${reports_dir}/network.txt"
        ;;
      security_privacy)
        {
          printf '# security-privacy\n\n'
          printf 'Gatekeeper: '; spctl --status 2>/dev/null || true
          printf 'FileVault: '; fdesetup status 2>/dev/null || true
          printf 'Firewall:\n'; /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || true
        } > "${reports_dir}/security-privacy.txt"
        ;;
      time_machine)
        {
          printf '# time-machine\n\n'
          tmutil destinationinfo 2>/dev/null || true
          printf '\nExclusions:\n'
          tmutil listexclusions 2>/dev/null || true
        } > "${reports_dir}/time-machine.txt"
        ;;
      printers)
        {
          printf '# printers\n\n'
          lpstat -v 2>/dev/null || true
          printf '\nDefault printer:\n'
          lpstat -d 2>/dev/null || true
          printf '\nCUPS settings:\n'
          cupsctl 2>/dev/null || true
        } > "${reports_dir}/printers.txt"
        ;;
      *)
        while IFS= read -r domain; do
          [[ -n "$domain" ]] || continue
          _macos_export_domain "$domain" "$defaults_dir"
        done < <(macos_preference_domains_for_category "$category")
        ;;
    esac
  done

  {
    printf '{\n  "categories": ['
    local first=true
    for category in "${categories[@]}"; do
      [[ "$first" == true ]] || printf ', '
      first=false
      printf '"%s"' "$category"
    done
    printf ']\n}\n'
  } > "${dest}/manifest.json"
}
