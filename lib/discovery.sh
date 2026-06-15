#!/usr/bin/env bash
# dotfriend — Discovery engine
# shellcheck shell=bash
#
# Scans the local environment (apps, brew packages, dotfiles, editors, etc.)
# and caches the results in ~/.cache/dotfriend/discovery.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=gum.sh
source "${SCRIPT_DIR}/gum.sh"

# ─────────────────────────────────────────────────────────────
# Cask API helpers
# ─────────────────────────────────────────────────────────────

# Cache file path
_CASK_API_JSON="${DOTFRIEND_CACHE_DIR}/cask-api.json"

# Fetch the Homebrew cask API and cache it locally.
# Skips download if cache is less than 24 hours old.
_fetch_cask_api() {
  ensure_dir "$DOTFRIEND_CACHE_DIR"

  local max_age=86400  # 24 hours in seconds
  if [[ -f "$_CASK_API_JSON" ]]; then
    local mtime age
    mtime="$(stat -f %m "$_CASK_API_JSON" 2>/dev/null || stat -c %Y "$_CASK_API_JSON" 2>/dev/null || printf '0')"
    age="$(($(date +%s) - mtime))"
    if [[ "$age" -lt "$max_age" ]]; then
      return 0
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    local tmpfile
    tmpfile="$(mktemp)"
    if dotfriend_run_optional_command curl -fsSL "https://formulae.brew.sh/api/cask.json" > "$tmpfile"; then
      mv "$tmpfile" "$_CASK_API_JSON"
    else
      rm -f "$tmpfile"
    fi
  fi
}

# Batch-lookup app names in the cached Homebrew API.
# Input: newline-separated app names via stdin
# Output: lines of "app_name|cask:token" for each match
_batch_lookup_cask_in_api() {
  if [[ ! -f "$_CASK_API_JSON" ]] || ! command -v jq >/dev/null 2>&1; then
    return
  fi

  local apps_json
  apps_json="$(jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || true)"
  [[ -n "$apps_json" ]] || return

  jq \
    --slurpfile api "$_CASK_API_JSON" \
    --argjson apps "$apps_json" \
    -n \
    -r \
    '
    def uniq_preserve:
      reduce .[] as $x ([]; if index($x) == null then . + [$x] else . end);

    def normalized_key:
      ascii_downcase
      | sub("\\.app$"; "")
      | gsub("\\+"; "plus")
      | gsub("[^a-z0-9]+"; "");

    def stripped_version:
      sub("([\\-_ ]+)?v?[0-9]+(\\.[0-9]+)+(?:[\\-_ ].*)?$"; "")
      | sub("([\\-_ ]+)20[0-9]{2}$"; "")
      | if test(".*[^0-9][0-9]$") then sub("[0-9]+$"; "") else . end
      | gsub("^[\\-_. ]+|[\\-_. ]+$"; "");

    def version_key:
      stripped_version | normalized_key;

    def stable_candidates:
      map(select(
        (contains("@") | not) and
        (contains("beta") | not) and
        (contains("nightly") | not) and
        (contains("preview") | not) and
        (contains("tip") | not)
      ));

    def choose_token($tokens):
      ($tokens | uniq_preserve) as $uniq |
      if ($uniq | length) == 0 then
        null
      else
        (($uniq | stable_candidates)[0] // $uniq[0])
      end;

    def embedded_app_name:
      split("/") | map(select(endswith(".app"))) | last? |
      if . == null then empty else sub("\\.app$"; "") end;

    def artifact_paths($c):
      [
        (($c.artifacts // [])[]? | .uninstall[]? | .delete?),
        (($c.artifacts // [])[]? | .installer[]? | .script.executable?)
      ]
      | .[]
      | if type == "array" then .[] else . end
      | select(type == "string");

    ($api[0] | reduce .[] as $c ({
      app_map: {},
      name_map: {},
      token_norm_map: {},
      path_norm_map: {},
      version_norm_map: {}
    };
      ($c.token) as $token |
      .token_norm_map[($token | normalized_key)] =
        ((.token_norm_map[($token | normalized_key)] // []) + [$token]) |
      .version_norm_map[($token | version_key)] =
        ((.version_norm_map[($token | version_key)] // []) + [$token]) |
      reduce
        (($c.artifacts // []) | .[] | select(has("app")) | .app | .[] | select(type == "string"))
        as $a (.;
          .app_map[($a | ascii_downcase | sub("\\.app$"; ""))] =
            ((.app_map[($a | ascii_downcase | sub("\\.app$"; ""))] // []) + [$token]) |
          .version_norm_map[($a | version_key)] =
            ((.version_norm_map[($a | version_key)] // []) + [$token])
        ) |
      reduce
        (($c.name // []) | .[] | select(type == "string"))
        as $n (.;
          .name_map[($n | ascii_downcase)] = ((.name_map[($n | ascii_downcase)] // []) + [$token])
        ) |
      reduce
        (artifact_paths($c) | embedded_app_name)
        as $path_app (.;
          .path_norm_map[($path_app | normalized_key)] =
            ((.path_norm_map[($path_app | normalized_key)] // []) + [$token]) |
          .version_norm_map[($path_app | version_key)] =
            ((.version_norm_map[($path_app | version_key)] // []) + [$token])
        )
    )) as $indexes |

    $apps[] as $app |
    ($app | ascii_downcase) as $app_lc |
    ($app | normalized_key) as $app_norm |
    ($app | version_key) as $app_version_norm |
    (
      if $indexes.app_map[$app_lc] != null then $indexes.app_map[$app_lc]
      elif $indexes.name_map[$app_lc] != null then $indexes.name_map[$app_lc]
      elif $indexes.token_norm_map[$app_norm] != null then $indexes.token_norm_map[$app_norm]
      elif $indexes.path_norm_map[$app_norm] != null then $indexes.path_norm_map[$app_norm]
      else $indexes.version_norm_map[$app_version_norm]
      end
    ) as $tokens |
    (choose_token($tokens // [])) as $chosen |
    select($chosen != null) |
    "\($app)|cask:\($chosen)"
    ' 2>/dev/null || true
}

_override_cask_for_app() {
  case "$1" in
    ".Karabiner-VirtualHIDDevice-Manager"|"Karabiner-EventViewer")
      printf '%s\n' "karabiner-elements"
      ;;
    *)
      return 1
      ;;
  esac
}

_app_search_roots() {
  local roots_spec="${DOTFRIEND_APP_SEARCH_DIRS:-/Applications:${HOME}/Applications}"
  local -a roots=()
  local root

  IFS=':' read -r -a roots <<< "$roots_spec"
  for root in "${roots[@]}"; do
    [[ -n "$root" ]] || continue
    printf '%s\n' "$root"
  done
}

_collect_installed_app_names() {
  local root app app_name
  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      app_name="${app##*/}"
      app_name="${app_name%.app}"
      printf '%s\n' "$app_name"
    done < <(find "$root" -maxdepth 1 -name '*.app' -print 2>/dev/null || true)
  done < <(_app_search_roots)
}

_app_has_mas_receipt() {
  local app_name="$1"
  local root
  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    if [[ -d "$root/${app_name}.app/Contents/_MASReceipt" ]]; then
      return 0
    fi
  done < <(_app_search_roots)
  return 1
}

_bundle_id_for_app() {
  local app_name="$1"
  local root plist

  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    plist="$root/${app_name}.app/Contents/Info.plist"
    if [[ -f "$plist" ]]; then
      plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null || true
      return 0
    fi
  done < <(_app_search_roots)

  return 0
}

# Batch-lookup receipt-backed apps in the local mas install list.
# Input: newline-separated app names via stdin
# Output: lines of "app_name|mas:MAS Name,id:123456789" for each match
_batch_lookup_mas_receipt_apps() {
  if ! command -v mas >/dev/null 2>&1; then
    return 0
  fi

  local apps_input mas_output
  apps_input="$(cat)"
  [[ -n "$apps_input" ]] || return 0

  mas_output="$(dotfriend_run_optional_command mas list || true)"
  [[ -n "$mas_output" ]] || return 0

  awk '
    function norm(value) {
      value = tolower(value)
      sub(/\.app$/, "", value)
      gsub(/\+/, "plus", value)
      gsub(/[^a-z0-9]+/, "", value)
      return value
    }

    NR == FNR {
      if ($0 == "") {
        next
      }
      apps[++app_count] = $0
      next
    }

    $0 !~ /^[0-9]+[[:space:]]+/ {
      next
    }

    {
      id = $1
      line = $0
      sub(/^[0-9]+[[:space:]]+/, "", line)
      name = line
      sub(/[[:space:]]+\([^()]*\)[[:space:]]*$/, "", name)
      if (!(name in exact_id)) {
        exact_id[name] = id
        exact_name[name] = name
      }
      key = norm(name)
      if (!(key in norm_id)) {
        norm_id[key] = id
        norm_name[key] = name
      }
    }

    END {
      for (i = 1; i <= app_count; i++) {
        app = apps[i]
        if (app in exact_id) {
          printf "%s|mas:%s,id:%s\n", app, exact_name[app], exact_id[app]
          continue
        }

        key = norm(app)
        if (key in norm_id) {
          printf "%s|mas:%s,id:%s\n", app, norm_name[key], norm_id[key]
        }
      }
    }
  ' <(printf '%s\n' "$apps_input") <(printf '%s\n' "$mas_output")
}

# ─────────────────────────────────────────────────────────────
# App discovery
# ─────────────────────────────────────────────────────────────

# Scan /Applications and ~/Applications, cross-referencing with Homebrew
# casks and local App Store receipts.
# Output format: App Name|cask:<token>  or  App Name|mas:<name>,id:<id>
#   or App Name|appstore:<bundle-id>  or  App Name|manual
discover_apps() {
  local -a apps=()
  local -a receipt_apps=()
  local app_name

  while IFS= read -r app_name; do
    [[ -n "$app_name" ]] || continue
    apps+=("$app_name")
    if _app_has_mas_receipt "$app_name"; then
      receipt_apps+=("$app_name")
    fi
  done < <(_collect_installed_app_names | sort -u)

  if [[ ${#apps[@]} -eq 0 ]]; then
    return 0
  fi

  # ── Tier 0: Fetch Homebrew cask API ──
  _fetch_cask_api

  # ── Tier 1: Batch lookup all apps in the Homebrew API ──
  local api_matches=""
  api_matches="$(printf '%s\n' "${apps[@]}" | _batch_lookup_cask_in_api)"

  # ── Tier 2: Batch lookup receipt-backed apps in mas ──
  local mas_matches=""
  if [[ ${#receipt_apps[@]} -gt 0 ]]; then
    mas_matches="$(printf '%s\n' "${receipt_apps[@]}" | _batch_lookup_mas_receipt_apps)"
  fi

  # ── Resolve each app ──
  for app_name in "${apps[@]}"; do
    local api_match=""
    api_match="$(printf '%s\n' "$api_matches" | awk -F'|' -v app="$app_name" '$1 == app { print $0; exit }')"

    # Tier 1: Homebrew API index
    if [[ -n "$api_match" ]]; then
      printf '%s\n' "$api_match"
      continue
    fi

    # Tier 2: curated overrides for helper apps shipped by a parent cask
    local override_cask=""
    override_cask="$(_override_cask_for_app "$app_name" 2>/dev/null || true)"
    if [[ -n "$override_cask" ]]; then
      printf '%s|cask:%s\n' "$app_name" "$override_cask"
      continue
    fi

    # Tier 3: mas-installed App Store app
    local mas_match=""
    mas_match="$(printf '%s\n' "$mas_matches" | awk -F'|' -v app="$app_name" '$1 == app { print $0; exit }')"
    if [[ -n "$mas_match" ]]; then
      printf '%s\n' "$mas_match"
      continue
    fi

    # Tier 4: Local App Store receipt without a mas match
    if _app_has_mas_receipt "$app_name"; then
      local bundle_id
      bundle_id="$(_bundle_id_for_app "$app_name")"
      if [[ -n "$bundle_id" ]]; then
        printf '%s|appstore:%s\n' "$app_name" "$bundle_id"
      else
        printf '%s|appstore:receipt\n' "$app_name"
      fi
      continue
    fi

    # Tier 5: manual
    printf '%s|manual\n' "$app_name"
  done | sort -u
}

# ─────────────────────────────────────────────────────────────
# Homebrew discovery
# ─────────────────────────────────────────────────────────────

# List installed formulae with descriptions.
# Output format: formula-name|description
discover_brew_formulae() {
  if ! has_brew; then
    return 0
  fi

  local formulae
  formulae="$(dotfriend_run_optional_command brew leaves || dotfriend_run_optional_command brew list --formula || true)"
  if [[ -z "$formulae" ]]; then
    return 0
  fi

  local output
  # shellcheck disable=SC2086
  output="$(dotfriend_run_optional_command brew desc $formulae | sed 's/: /|/' || true)"

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  else
    # Fallback: names only
    printf '%s\n' "$formulae" | sed 's/$/|/'
  fi
}

# List installed casks.
discover_brew_casks() {
  if ! has_brew; then
    return 0
  fi
  dotfriend_run_optional_command brew list --cask || true
}

# List tapped repositories.
discover_brew_taps() {
  if ! has_brew; then
    return 0
  fi
  dotfriend_run_optional_command brew tap || true
}

# ─────────────────────────────────────────────────────────────
# npm discovery
# ─────────────────────────────────────────────────────────────

# List globally installed npm packages.
# Output format: package@version
discover_npm_globals() {
  if ! command -v npm >/dev/null 2>&1; then
    return 0
  fi

  # Prefer JSON + Node for robust scoped-package support
  if command -v node >/dev/null 2>&1; then
    local npm_json
    npm_json="$(dotfriend_run_optional_command npm list -g --depth=0 --json || true)"
    [[ -n "$npm_json" ]] || return 0
    printf '%s' "$npm_json" | node -e '
      const data = require("fs").readFileSync(0, "utf8");
      const json = JSON.parse(data);
      const deps = json.dependencies || {};
      for (const [name, info] of Object.entries(deps)) {
        console.log(name + "@" + info.version);
      }
    ' 2>/dev/null || true
  else
    # Fallback text-tree parsing
    dotfriend_run_optional_command npm list -g --depth=0 \
      | grep -oE '(\@[^/]+/)?[^@[:space:]]+@[^[:space:]]+' \
      || true
  fi
}

# ─────────────────────────────────────────────────────────────
# Agentic tools discovery
# ─────────────────────────────────────────────────────────────

# Read lib/agent-tools.json and check whether each tool's config directory
# exists under $HOME.
# Output format: tool-id|Tool Name|config_dir|status|skill_count
discover_agentic_tools() {
  local tools_file="${SCRIPT_DIR}/agent-tools.json"
  if [[ ! -f "$tools_file" ]]; then
    return 0
  fi

  local parser="none"
  if command -v jq >/dev/null 2>&1; then
    parser="jq"
  elif command -v python3 >/dev/null 2>&1; then
    parser="python3"
  fi

  if [[ "$parser" == "none" ]]; then
    log_warn "Cannot parse agent-tools.json: install jq or python3"
    return 0
  fi

  local raw=""
  if [[ "$parser" == "jq" ]]; then
    raw="$(jq -r '.agentic_tools[] | "\(.id)|\(.name)|\(.canonical_dir // .config_dirs[0])|\(.important_files // [] | join(","))|\(.important_dirs // [] | join(","))"' "$tools_file" 2>/dev/null || true)"
  else
    raw="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
tools = data.get("agentic_tools", [])
for tool in tools:
    if not isinstance(tool, dict):
        continue
    cfg = tool.get("canonical_dir", tool.get("config_dirs", [""])[0])
    files = tool.get("important_files", [])
    dirs = tool.get("important_dirs", [])
    print("{}|{}|{}|{}|{}".format(
        tool.get("id", ""),
        tool.get("name", ""),
        cfg,
        ",".join(files),
        ",".join(dirs)
    ))
' "$tools_file" 2>/dev/null || true)"
  fi

  local tid name cfg files_str dirs_str status skill_count
  while IFS='|' read -r tid name cfg files_str dirs_str; do
    [[ -n "$tid" ]] || continue
    # Expand leading ~ to $HOME (canonical_dir values are like ~/.claude)
    cfg="${cfg/#\~/$HOME}"
    if [[ -d "$cfg" ]]; then
      status="found"
      skill_count=0
      local f d
      if [[ -n "$files_str" ]]; then
        IFS=',' read -ra files <<< "$files_str"
        for f in "${files[@]}"; do
          [[ -n "$f" && -f "$cfg/$f" ]] && ((skill_count++)) || true
        done
      fi
      if [[ -n "$dirs_str" ]]; then
        IFS=',' read -ra dirs <<< "$dirs_str"
        for d in "${dirs[@]}"; do
          [[ -n "$d" && -d "$cfg/$d" ]] || continue
          local dir_count
          dir_count="$(find "$cfg/$d" -maxdepth 1 -mindepth 1 -not -type l 2>/dev/null | wc -l | tr -d ' ')"
          skill_count=$((skill_count + dir_count))
        done
      fi
    else
      status="missing"
      skill_count=0
    fi
    printf '%s|%s|%s|%s|%d\n' "$tid" "$name" "$cfg" "$status" "$skill_count"
  done <<< "$raw"
}

# ─────────────────────────────────────────────────────────────
# Dotfile & config discovery
# ─────────────────────────────────────────────────────────────

# Scan home directory for known dotfiles.
# Skips .bash_profile and any shell history files.
discover_dotfiles() {
  local files=(
    .zshrc
    .bashrc
    .gitconfig
    .tmux.conf
    .npmrc
    .ignore
  )
  local f
  for f in "${files[@]}"; do
    if [[ -f "${HOME}/${f}" ]]; then
      printf '%s\n' "$f"
    fi
  done
}

# List directories inside ~/.config/.
discover_config_dirs() {
  local dir
  for dir in "${HOME}/.config"/*/; do
    [[ -d "$dir" ]] || continue
    basename "$dir"
  done | sort
}

# ─────────────────────────────────────────────────────────────
# Editor discovery
# ─────────────────────────────────────────────────────────────

# Discover VS Code settings and extensions.
# Multiline output: first line is settings path, remaining lines are extensions.
discover_vscode() {
  local settings_path="${HOME}/Library/Application Support/Code/User/settings.json"
  if [[ -f "$settings_path" ]]; then
    printf 'settings:%s\n' "$settings_path"
  else
    printf 'settings:missing\n'
  fi

  if command -v code >/dev/null 2>&1; then
    dotfriend_run_optional_command code --list-extensions || true
  fi
}

# Discover Cursor settings and extensions.
discover_cursor() {
  local settings_path="${HOME}/Library/Application Support/Cursor/User/settings.json"
  if [[ -f "$settings_path" ]]; then
    printf 'settings:%s\n' "$settings_path"
  else
    printf 'settings:missing\n'
  fi

  if command -v cursor >/dev/null 2>&1; then
    dotfriend_run_optional_command cursor --list-extensions || true
  fi
}

# ─────────────────────────────────────────────────────────────
# Dock discovery
# ─────────────────────────────────────────────────────────────

# List Dock items if dockutil is installed.
discover_dock() {
  if command -v dockutil >/dev/null 2>&1; then
    dotfriend_run_optional_command dockutil --list || true
  fi
}

# ─────────────────────────────────────────────────────────────
# Curated macOS defaults discovery
# ─────────────────────────────────────────────────────────────

macos_defaults_catalog_file() {
  printf '%s' "${DOTFRIEND_MACOS_DEFAULTS_CATALOG_FILE:-${SCRIPT_DIR}/macos-defaults.json}"
}

macos_defaults_validate_catalog() {
  local catalog_file="${1:-$(macos_defaults_catalog_file)}"
  [[ -f "$catalog_file" ]] || { printf 'macOS defaults catalog missing: %s\n' "$catalog_file" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'jq is required for macOS defaults catalog validation\n' >&2; return 1; }

  jq -e '
    .schema_version == 1
    and (.catalog_version | type == "string" and length > 0)
    and (.entries | type == "array")
    and all(.entries[]?;
      (.id | type == "string" and length > 0)
      and (.category | type == "string" and length > 0)
      and (.title | type == "string" and length > 0)
      and (.description | type == "string")
      and (.domain | type == "string" and length > 0)
      and (.key | type == "string" and length > 0)
      and (.scope | IN("user","currentHost"))
      and (.value_type | IN("bool","int","float","string"))
      and (.risk | IN("safe","attention","risky"))
      and (.default_selected | type == "boolean")
      and ((.restart // []) | type == "array")
      and ((.source // "") | type == "string" and length > 0)
    )
  ' "$catalog_file" >/dev/null
}

_macos_defaults_expected_read_type() {
  case "$1" in
    bool) printf 'boolean' ;;
    int) printf 'integer' ;;
    float) printf 'float' ;;
    string) printf 'string' ;;
    *) printf '%s' "$1" ;;
  esac
}

_macos_defaults_read_type_matches() {
  local value_type="$1" raw_type="$2" expected_type
  expected_type="$(_macos_defaults_expected_read_type "$value_type")"
  [[ "$raw_type" == "$expected_type" ]] || [[ "$value_type" == "int" && "$raw_type" == "float" ]]
}

_macos_defaults_convert_value_json() {
  local value_type="$1" raw="$2"
  case "$value_type" in
    bool)
      case "$raw" in
        1|true|TRUE|True|yes|YES|Yes) printf 'true' ;;
        0|false|FALSE|False|no|NO|No) printf 'false' ;;
        *) return 1 ;;
      esac
      ;;
    int)
      jq -cn --arg raw "$raw" '
        ($raw | tonumber) as $n |
        if $n == ($n | floor) then ($n | floor) else error("not an integer") end
      '
      ;;
    float)
      jq -cn --arg raw "$raw" '$raw | tonumber'
      ;;
    string)
      jq -cn --arg raw "$raw" '$raw'
      ;;
    *)
      return 1
      ;;
  esac
}

_macos_defaults_read_command() {
  local scope="$1"
  local timeout_seconds="${DOTFRIEND_MACOS_DEFAULTS_COMMAND_TIMEOUT:-1}"
  shift
  if [[ "$scope" == "currentHost" ]]; then
    DOTFRIEND_OPTIONAL_COMMAND_TIMEOUT="$timeout_seconds" dotfriend_run_optional_command defaults -currentHost "$@"
  else
    DOTFRIEND_OPTIONAL_COMMAND_TIMEOUT="$timeout_seconds" dotfriend_run_optional_command defaults "$@"
  fi
}

macos_defaults_read_value_json() {
  local domain="$1" key="$2" scope="$3" value_type="$4"
  local read_type raw_type expected_type raw_value

  read_type="$(_macos_defaults_read_command "$scope" read-type "$domain" "$key" 2>/dev/null)" || return 1
  [[ -n "$read_type" ]] || return 1

  raw_type="$(printf '%s' "$read_type" | sed 's/^Type is //; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
  if ! _macos_defaults_read_type_matches "$value_type" "$raw_type"; then
    return 2
  fi

  raw_value="$(_macos_defaults_read_command "$scope" read "$domain" "$key" 2>/dev/null || true)"
  [[ -n "$raw_value" ]] || return 1
  raw_value="$(printf '%s' "$raw_value" | sed 's/[[:space:]]*$//')"
  _macos_defaults_convert_value_json "$value_type" "$raw_value"
}

discover_macos_defaults() {
  local catalog_file="${1:-$(macos_defaults_catalog_file)}"
  macos_defaults_validate_catalog "$catalog_file"

  local catalog_version items_json found_count missing_count skipped_count risky_count entry_json
  catalog_version="$(jq -r '.catalog_version' "$catalog_file")"
  items_json="[]"
  found_count=0
  missing_count=0
  skipped_count=0
  risky_count=0

  while IFS= read -r entry_json; do
    [[ -n "$entry_json" ]] || continue

    local id domain key scope value_type value_json status
    id="$(jq -r '.id' <<< "$entry_json")"
    domain="$(jq -r '.domain' <<< "$entry_json")"
    key="$(jq -r '.key' <<< "$entry_json")"
    scope="$(jq -r '.scope' <<< "$entry_json")"
    value_type="$(jq -r '.value_type' <<< "$entry_json")"
    status=0
    value_json="$(macos_defaults_read_value_json "$domain" "$key" "$scope" "$value_type")" || status=$?

    case "$status" in
      0)
        local item_json
        item_json="$(jq -cn --argjson entry "$entry_json" --argjson value "$value_json" '
          $entry
          | .value = $value
          | .status = "found"
        ')"
        items_json="$(jq -cn --argjson items "$items_json" --argjson item "$item_json" '$items + [$item]')"
        ((found_count++)) || true
        if [[ "$(jq -r '.risk' <<< "$entry_json")" == "risky" ]]; then
          ((risky_count++)) || true
        fi
        ;;
      2)
        ((skipped_count++)) || true
        ;;
      *)
        ((missing_count++)) || true
        ;;
    esac
  done < <(jq -c '.entries[]' "$catalog_file")

  jq -cn \
    --arg catalog_version "$catalog_version" \
    --argjson items "$items_json" \
    --argjson found "$found_count" \
    --argjson missing "$missing_count" \
    --argjson skipped "$skipped_count" \
    --argjson risky "$risky_count" \
    '{catalog_version:$catalog_version,items:$items,counts:{found:$found,missing:$missing,skipped:$skipped,risky:$risky}}'
}

# ─────────────────────────────────────────────────────────────
# Orchestration
# ─────────────────────────────────────────────────────────────

_discovery_file_json_array() {
  local file="$1" jq_filter="$2"
  if [[ -f "$file" ]]; then
    jq -R -s "$jq_filter" "$file"
  else
    jq -n '[]'
  fi
}

_discovery_editor_json() {
  local file="$1"
  if [[ -f "$file" ]]; then
    jq -R -s '
      split("\n") as $lines |
      ($lines[0] // "") as $settings |
      {
        settings_path: (if ($settings | startswith("settings:")) then ($settings | sub("^settings:"; "") | select(. != "missing") // "") else "" end),
        extensions: ($lines[1:] | map(select(length > 0 and . != "extensions:")))
      }
    ' "$file"
  else
    jq -n '{settings_path:"", extensions:[]}'
  fi
}

write_discovery_v2() {
  local tmpdir="$1" cache_file="$2"
  if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required to write structured discovery cache."
    return 1
  fi

  local apps_json formulae_json casks_json taps_json npm_json agents_json dotfiles_json config_dirs_json vscode_json cursor_json dock_json macos_defaults_json
  apps_json="$(_discovery_file_json_array "$tmpdir/apps.txt" '
    split("\n") | map(select(length > 0)) | map(
      split("|") as $p |
      ($p[1] // "") as $raw |
      {
        name: $p[0],
        path: "",
        cask: (if $raw | startswith("cask:") then ($raw | sub("^cask:"; "")) else "" end),
        source: (
          if $raw | startswith("cask:") then "cask"
          elif $raw | startswith("mas:") then "mas"
          elif $raw | startswith("appstore:") then "appstore"
          elif $raw == "manual" then "manual"
          else "unknown" end
        ),
        restore_ref: $raw
      }
    )
  ')"
  formulae_json="$(_discovery_file_json_array "$tmpdir/formulae.txt" 'split("\n") | map(select(length > 0)) | map(split("|") as $p | {name:$p[0], description:($p[1] // "")})')"
  casks_json="$(_discovery_file_json_array "$tmpdir/casks.txt" 'split("\n") | map(select(length > 0)) | map({token:., name:.})')"
  taps_json="$(_discovery_file_json_array "$tmpdir/taps.txt" 'split("\n") | map(select(length > 0)) | map({name:.})')"
  npm_json="$(_discovery_file_json_array "$tmpdir/npm_globals.txt" 'split("\n") | map(select(length > 0)) | map(capture("^(?<name>.+)@(?<version>[^@]+)$")? // {name:., version:""})')"
  agents_json="$(_discovery_file_json_array "$tmpdir/agents.txt" '
    split("\n") | map(select(length > 0)) | map(
      split("|") as $p |
      {id:$p[0], name:($p[1] // ""), config_dir:($p[2] // ""), status:($p[3] // "missing"), skill_count:(($p[4] // "0") | tonumber? // 0)}
    )
  ')"
  dotfiles_json="$(_discovery_file_json_array "$tmpdir/dotfiles.txt" 'split("\n") | map(select(length > 0)) | map({path:., status:"found"})')"
  config_dirs_json="$(_discovery_file_json_array "$tmpdir/config_dirs.txt" 'split("\n") | map(select(length > 0)) | map({name:., path:("~/.config/" + .), status:"found"})')"
  vscode_json="$(_discovery_editor_json "$tmpdir/vscode.txt")"
  cursor_json="$(_discovery_editor_json "$tmpdir/cursor.txt")"
  dock_json="$(_discovery_file_json_array "$tmpdir/dock.txt" 'split("\n") | map(select(length > 0)) | {apps:.}')"
  if [[ -f "$tmpdir/macos_defaults.json" ]]; then
    macos_defaults_json="$(jq -c '.' "$tmpdir/macos_defaults.json")"
  else
    macos_defaults_json='{"catalog_version":"","items":[],"counts":{"found":0,"missing":0,"skipped":0,"risky":0}}'
  fi

  jq -n \
    --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson apps "$apps_json" \
    --argjson formulae "$formulae_json" \
    --argjson casks "$casks_json" \
    --argjson taps "$taps_json" \
    --argjson npm_globals "$npm_json" \
    --argjson agents "$agents_json" \
    --argjson dotfiles "$dotfiles_json" \
    --argjson config_dirs "$config_dirs_json" \
    --argjson vscode "$vscode_json" \
    --argjson cursor "$cursor_json" \
    --argjson dock "$dock_json" \
    --argjson macos_defaults "$macos_defaults_json" \
    '{
      schema_version: 2,
      generated_at: $generated_at,
      apps: $apps,
      formulae: $formulae,
      casks: $casks,
      taps: $taps,
      npm_globals: $npm_globals,
      agents: $agents,
      dotfiles: $dotfiles,
      config_dirs: $config_dirs,
      editors: {vscode: $vscode, cursor: $cursor},
      dock: $dock,
      macos_defaults: $macos_defaults
    }' > "$cache_file"
}

# Run all discovery tasks in parallel, cache results to discovery.json,
# and provide TUI feedback via gum_spin.
run_discovery() {
  ensure_dir "$DOTFRIEND_CACHE_DIR"
  local cache_file="${DOTFRIEND_CACHE_DIR}/discovery.json"

  # Absolute path to this script so subshells can source it regardless of cwd
  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  local tmpdir
  tmpdir="$(mktemp -d)"
  # Clean up temp directory on exit (expand tmpdir now so the local var is not needed later)
  trap "rm -rf '$tmpdir'" EXIT

  local -a pids=()

  # Run all discovery tasks in parallel inside a SINGLE gum_spin subshell.
  # This avoids multiple concurrent gum processes querying terminal colors
  # and causing ANSI escape code garbage (OSC 11 responses) to leak.
  gum_spin --spinner dot --title "Scanning your system..." \
    -- bash -c "
      source '$script_path'
      exit_code=0
      discover_apps > '$tmpdir/apps.txt' 2>/dev/null &
      p1=\$!
      discover_brew_formulae > '$tmpdir/formulae.txt' 2>/dev/null &
      p2=\$!
      discover_brew_casks > '$tmpdir/casks.txt' 2>/dev/null &
      p3=\$!
      discover_brew_taps > '$tmpdir/taps.txt' 2>/dev/null &
      p4=\$!
      discover_npm_globals > '$tmpdir/npm_globals.txt' 2>/dev/null &
      p5=\$!
      discover_agentic_tools > '$tmpdir/agents.txt' 2>/dev/null &
      p6=\$!
      discover_dotfiles > '$tmpdir/dotfiles.txt' 2>/dev/null &
      p7=\$!
      discover_config_dirs > '$tmpdir/config_dirs.txt' 2>/dev/null &
      p8=\$!
      discover_vscode > '$tmpdir/vscode.txt' 2>/dev/null &
      p9=\$!
      discover_cursor > '$tmpdir/cursor.txt' 2>/dev/null &
      p10=\$!
      discover_dock > '$tmpdir/dock.txt' 2>/dev/null &
      p11=\$!
      discover_macos_defaults > '$tmpdir/macos_defaults.json' 2>/dev/null &
      p12=\$!
      if ! wait \$p1; then exit_code=1; fi
      if ! wait \$p2; then exit_code=1; fi
      if ! wait \$p3; then exit_code=1; fi
      if ! wait \$p4; then exit_code=1; fi
      if ! wait \$p5; then exit_code=1; fi
      if ! wait \$p6; then exit_code=1; fi
      if ! wait \$p7; then exit_code=1; fi
      if ! wait \$p8; then exit_code=1; fi
      if ! wait \$p9; then exit_code=1; fi
      if ! wait \$p10; then exit_code=1; fi
      if ! wait \$p11; then exit_code=1; fi
      if ! wait \$p12; then exit_code=1; fi
      exit \$exit_code
    "

  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log_warn "Some discovery tasks finished with errors."
  fi

  # Assemble the cache file from individual temp outputs.
  if command -v jq >/dev/null 2>&1; then
    write_discovery_v2 "$tmpdir" "$cache_file"
  else
    # Portable fallback without jq
    {
      printf '{\n'
      printf '  "apps": "%s",\n' "$(json_escape "$(cat "$tmpdir/apps.txt" 2>/dev/null || true)")"
      printf '  "formulae": "%s",\n' "$(json_escape "$(cat "$tmpdir/formulae.txt" 2>/dev/null || true)")"
      printf '  "casks": "%s",\n' "$(json_escape "$(cat "$tmpdir/casks.txt" 2>/dev/null || true)")"
      printf '  "taps": "%s",\n' "$(json_escape "$(cat "$tmpdir/taps.txt" 2>/dev/null || true)")"
      printf '  "npm_globals": "%s",\n' "$(json_escape "$(cat "$tmpdir/npm_globals.txt" 2>/dev/null || true)")"
      printf '  "agents": "%s",\n' "$(json_escape "$(cat "$tmpdir/agents.txt" 2>/dev/null || true)")"
      printf '  "dotfiles": "%s",\n' "$(json_escape "$(cat "$tmpdir/dotfiles.txt" 2>/dev/null || true)")"
      printf '  "config_dirs": "%s",\n' "$(json_escape "$(cat "$tmpdir/config_dirs.txt" 2>/dev/null || true)")"
      printf '  "vscode": "%s",\n' "$(json_escape "$(cat "$tmpdir/vscode.txt" 2>/dev/null || true)")"
      printf '  "cursor": "%s",\n' "$(json_escape "$(cat "$tmpdir/cursor.txt" 2>/dev/null || true)")"
      printf '  "dock": "%s",\n' "$(json_escape "$(cat "$tmpdir/dock.txt" 2>/dev/null || true)")"
      printf '  "macos_defaults": "%s"\n' "$(json_escape "$(cat "$tmpdir/macos_defaults.json" 2>/dev/null || true)")"
      printf '}\n'
    } > "$cache_file"
  fi

  # Clear the trap so the local tmpdir variable doesn't leak as unbound
  trap - EXIT
  rm -rf "$tmpdir"

  log_ok "Discovery complete. Cached to $cache_file"
}

# ─────────────────────────────────────────────────────────────
# Cache loader
# ─────────────────────────────────────────────────────────────

# Load discovery.json into exported DISCOVERY_* variables.
# Returns 1 if the cache does not exist.
load_discovery() {
  local cache_file="${DOTFRIEND_CACHE_DIR}/discovery.json"
  if [[ ! -f "$cache_file" ]]; then
    log_warn "No discovery cache found. Run run_discovery first."
    return 1
  fi

  if command -v jq >/dev/null 2>&1 && [[ "$(jq -r '.schema_version // 1' "$cache_file" 2>/dev/null || printf '1')" == "2" ]]; then
    load_discovery_v2 "$cache_file"
    return 0
  fi

  load_discovery_legacy "$cache_file"
}

load_discovery_v2() {
  local cache_file="${1:-${DOTFRIEND_CACHE_DIR}/discovery.json}"
  if [[ ! -f "$cache_file" ]]; then
    log_warn "No discovery cache found. Run run_discovery first."
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_warn "jq is required to load structured discovery cache."
    return 1
  fi

  DISCOVERY_APPS="$(jq -r '.apps[]? | [.name, .restore_ref] | @tsv | gsub("\t"; "|")' "$cache_file")"
  DISCOVERY_FORMULAE="$(jq -r '.formulae[]? | [.name, (.description // "")] | @tsv | gsub("\t"; "|")' "$cache_file")"
  DISCOVERY_CASKS="$(jq -r '.casks[]? | .token // .name // empty' "$cache_file")"
  DISCOVERY_TAPS="$(jq -r '.taps[]? | .name // empty' "$cache_file")"
  DISCOVERY_NPM_GLOBALS="$(jq -r '.npm_globals[]? | if .version then "\(.name)@\(.version)" else .name end' "$cache_file")"
  DISCOVERY_AGENTS="$(jq -r '.agents[]? | [.id, .name, (.config_dir // ""), (.status // "missing"), ((.skill_count // 0) | tostring)] | @tsv | gsub("\t"; "|")' "$cache_file")"
  DISCOVERY_DOTFILES="$(jq -r '.dotfiles[]? | .path // empty' "$cache_file")"
  DISCOVERY_CONFIG_DIRS="$(jq -r '.config_dirs[]? | .name // empty' "$cache_file")"
  DISCOVERY_VSCODE="$(jq -r '.editors.vscode as $v | "settings:\($v.settings_path // "")", ($v.extensions[]? // empty)' "$cache_file")"
  DISCOVERY_CURSOR="$(jq -r '.editors.cursor as $v | "settings:\($v.settings_path // "")", ($v.extensions[]? // empty)' "$cache_file")"
  DISCOVERY_DOCK="$(jq -r '.dock.apps[]? // empty' "$cache_file")"
  DISCOVERY_MACOS_DEFAULTS="$(jq -c '.macos_defaults // {catalog_version:"",items:[],counts:{found:0,missing:0,skipped:0,risky:0}}' "$cache_file")"

  export DISCOVERY_APPS DISCOVERY_FORMULAE DISCOVERY_CASKS DISCOVERY_TAPS \
    DISCOVERY_NPM_GLOBALS DISCOVERY_AGENTS DISCOVERY_DOTFILES \
    DISCOVERY_CONFIG_DIRS DISCOVERY_VSCODE DISCOVERY_CURSOR DISCOVERY_DOCK \
    DISCOVERY_MACOS_DEFAULTS
}

load_discovery_legacy() {
  local cache_file="${1:-${DOTFRIEND_CACHE_DIR}/discovery.json}"
  if [[ ! -f "$cache_file" ]]; then
    log_warn "No discovery cache found. Run run_discovery first."
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    DISCOVERY_APPS="$(jq -r '.apps // empty' "$cache_file")"
    DISCOVERY_FORMULAE="$(jq -r '.formulae // empty' "$cache_file")"
    DISCOVERY_CASKS="$(jq -r '.casks // empty' "$cache_file")"
    DISCOVERY_TAPS="$(jq -r '.taps // empty' "$cache_file")"
    DISCOVERY_NPM_GLOBALS="$(jq -r '.npm_globals // empty' "$cache_file")"
    DISCOVERY_AGENTS="$(jq -r '.agents // empty' "$cache_file")"
    DISCOVERY_DOTFILES="$(jq -r '.dotfiles // empty' "$cache_file")"
    DISCOVERY_CONFIG_DIRS="$(jq -r '.config_dirs // empty' "$cache_file")"
    DISCOVERY_VSCODE="$(jq -r '.vscode // empty' "$cache_file")"
    DISCOVERY_CURSOR="$(jq -r '.cursor // empty' "$cache_file")"
    DISCOVERY_DOCK="$(jq -r '.dock // empty' "$cache_file")"
    DISCOVERY_MACOS_DEFAULTS="$(jq -c '.macos_defaults // empty' "$cache_file")"
  else
    DISCOVERY_APPS="$(json_get_key "$cache_file" apps)"
    DISCOVERY_FORMULAE="$(json_get_key "$cache_file" formulae)"
    DISCOVERY_CASKS="$(json_get_key "$cache_file" casks)"
    DISCOVERY_TAPS="$(json_get_key "$cache_file" taps)"
    DISCOVERY_NPM_GLOBALS="$(json_get_key "$cache_file" npm_globals)"
    DISCOVERY_AGENTS="$(json_get_key "$cache_file" agents)"
    DISCOVERY_DOTFILES="$(json_get_key "$cache_file" dotfiles)"
    DISCOVERY_CONFIG_DIRS="$(json_get_key "$cache_file" config_dirs)"
    DISCOVERY_VSCODE="$(json_get_key "$cache_file" vscode)"
    DISCOVERY_CURSOR="$(json_get_key "$cache_file" cursor)"
    DISCOVERY_DOCK="$(json_get_key "$cache_file" dock)"
    DISCOVERY_MACOS_DEFAULTS="$(json_get_key "$cache_file" macos_defaults)"
  fi

  export DISCOVERY_APPS DISCOVERY_FORMULAE DISCOVERY_CASKS DISCOVERY_TAPS \
    DISCOVERY_NPM_GLOBALS DISCOVERY_AGENTS DISCOVERY_DOTFILES \
    DISCOVERY_CONFIG_DIRS DISCOVERY_VSCODE DISCOVERY_CURSOR DISCOVERY_DOCK \
    DISCOVERY_MACOS_DEFAULTS
}

discovery_cache_data_json() {
  local cache_file="${1:-${DOTFRIEND_CACHE_DIR}/discovery.json}"
  if [[ ! -f "$cache_file" ]]; then
    jq -n '{cache_path:"", discovery:null}'
    return 0
  fi
  jq -n --arg cache_path "$cache_file" --slurpfile discovery "$cache_file" \
    '{cache_path:$cache_path, discovery:$discovery[0]}'
}
