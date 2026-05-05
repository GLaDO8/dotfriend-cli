# Phase 1: API Output and Runtime Preflight

## Objective

Create the machine-readable backend surface that a menu bar app can call without scraping terminal output. Separate runtime preflight from runtime installation.

## Files

1. `dotfriend`
2. `lib/common.sh`
3. `lib/bootstrap.sh`
4. new `lib/api.sh`
5. new `lib/preflight.sh`
6. new `tests/api_contract_test.sh`
7. new `tests/preflight_contract_test.sh`

## API Helpers

Add `lib/api.sh` with these functions:

1. `api_json_escape`
2. `api_now_iso`
3. `api_print_envelope status command data_json warnings_json errors_json`
4. `api_event event payload_json`
5. `api_warning code message details_json`
6. `api_error code message details_json`
7. `api_fail command code message details_json`

Implementation rules:

1. Prefer `jq -n` to construct JSON.
2. JSON stdout must contain no ANSI escapes.
3. In `--json` and `--events` mode, human logs must go to stderr.
4. If `jq` is unavailable, only fatal error envelopes need fallback JSON.
5. Do not use Gum in API mode.

## Entrypoint Changes

Update `dotfriend` to parse global flags before subcommand dispatch:

1. `--json`
2. `--events`
3. `--no-bootstrap`
4. `--approved`

Required behavior:

1. `dotfriend --help` stays unchanged.
2. `dotfriend --version` stays unchanged.
3. `dotfriend start` and `dotfriend sync` keep current human behavior.
4. `dotfriend start --no-bootstrap` skips `bootstrap_runtime`.
5. `dotfriend sync --no-bootstrap` skips `bootstrap_runtime`.
6. `--json` and `--events` imply non-interactive mode unless a command explicitly documents otherwise.

## Preflight Command

Add `lib/preflight.sh`.

Add:

```bash
dotfriend preflight --json
```

It must check:

1. OS is macOS/Darwin.
2. `xcode-select` exists.
3. Xcode Command Line Tools are installed.
4. Homebrew is installed.
5. Runtime formulae are installed: `git`, `jq`, `gum`, `gh`, `mas`, `node`.
6. Commands resolve: `brew`, `git`, `jq`, `gum`, `gh`, `mas`, `npm`.

Output data shape:

```json
{
  "ready": false,
  "requires_approval": true,
  "checks": [
    {"id":"homebrew","status":"missing","action":"install_homebrew"},
    {"id":"jq","status":"missing","action":"brew_install","package":"jq"}
  ],
  "planned_commands": [
    {"label":"Install jq","command":["brew","install","jq"]}
  ]
}
```

Allowed check statuses:

1. `ok`
2. `missing`
3. `needs_install`
4. `blocked`
5. `unknown`

`preflight --json` must never install anything.

## Bootstrap Behavior

Keep `bootstrap_runtime` for human CLI mode.

Do not remove:

1. `ensure_xcode_cli`
2. `ensure_homebrew`
3. `ensure_runtime_formulae`
4. `verify_runtime_dependencies`

Add a write path only if needed:

```bash
dotfriend bootstrap --events --approved
```

If implemented, it must refuse to run without `--approved` and must emit `approval_required` otherwise.

## Tests

`tests/api_contract_test.sh`:

1. `./dotfriend preflight --json` parses with `jq`.
2. JSON has `contract_version == 1`.
3. JSON has `command == "preflight"`.
4. JSON has `status`, `warnings`, `errors`, and `data`.
5. stdout contains no ANSI escape bytes.

`tests/preflight_contract_test.sh`:

1. Use fake `HOME` and fake `PATH`.
2. With missing `jq`, `preflight --json` reports missing `jq`.
3. With missing Homebrew, `preflight --json` reports `requires_approval`.
4. No fake `brew install` command is invoked by preflight.
5. `dotfriend start --no-bootstrap` does not call fake `brew`.

## Done When

1. A GUI can determine readiness without mutating the Mac.
2. Human CLI behavior remains intact.
3. New API/preflight tests pass.
