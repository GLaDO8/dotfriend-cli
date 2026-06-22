# dotfriend

Agent handoff for this repo. Keep this file focused on implementation guidance, not product docs. For user-facing overview, commands, and installation, see `README.md`.

When making considerable user-facing or workflow changes, update `README.md` in the same change.

## High-Value Files

| File | Purpose |
|------|---------|
| `dotfriend` | Main CLI entrypoint. Bootstraps runtime deps for `start`/`sync`, then dispatches commands. |
| `bin/dotfriend.js` | npm package wrapper that invokes `./dotfriend`. |
| `lib/bootstrap.sh` | Ensures Xcode CLI tools, Homebrew, and runtime dependencies exist. |
| `lib/wizard.sh` | Interactive `dotfriend start` flow. Writes selections to cache. |
| `lib/discovery.sh` | Scans machine state and writes discovery cache. |
| `lib/generate.sh` | Builds the output dotfiles repo from cached selections. |
| `lib/macos_preferences.sh` | macOS preference category registry and backup/export helpers. |
| `lib/sync.sh` | Syncs machine changes back into an existing generated repo. |
| `lib/gum.sh` | Gum wrappers plus plain-bash fallbacks used in tests. |
| `templates/install.sh` | Generated restore/install script. |
| `templates/bootstrap.sh` | Generated first-run bootstrap script for new Macs. |
| `templates/scripts/validate.sh` | Generated validation helper. |
| `templates/scripts/backup.sh` | Generated reverse-sync helper. |

## Durable Invariants

### Bash Safety
- Scripts use `set -euo pipefail`.
- `local` is only valid inside functions.
- `((var++))` can exit under `set -e` when the old value is `0`; use `((var++)) || true`.
- Prefer `printf '%s\n' "$value"` over variable format strings.

### Runtime and Gum
- `dotfriend start` and `dotfriend sync` bootstrap runtime dependencies before doing real work. Do not assume the old `require_gum()` flow still exists.
- Treat Gum as required in production. Use wrappers from `lib/gum.sh`, not raw `gum` calls in project code.
- Gum documentation is primarily its built-in help output: use `gum --help`, then `gum <command> --help`.
- Use `agent-tui` for validating interactive Gum/TUI flows, not for basic help lookup.
- `gum confirm` does not accept `--prompt`; the wrapper converts it to a positional prompt.
- Current theme-related defaults in `lib/gum.sh` include:
  - `GUM_CHOOSE_CURSOR_FOREGROUND=""`
  - `GUM_CHOOSE_SHOW_HELP="true"`

### JSON and Caches
- `jq` is part of dotfriend's runtime bootstrap, so prefer `jq` in normal repo code.
- Preserve or add non-`jq` fallbacks only in intentionally portable paths such as shared helpers or generated scripts that may run on a fresh Mac before all tooling is present.
- When reading JSON arrays for shell loops, extract scalars, not objects.
- Discovery cache: `~/.cache/dotfriend/discovery.json`
- Selections cache: `~/.cache/dotfriend/selections.json`
- macOS preference selections live at `.macos_preferences.categories`; category IDs come from `lib/macos_preferences.sh`.

### Generated Script Behavior
- Generated restore scripts should soft-fail where practical. One bad brew formula, npm package, or dock command should not abort the whole restore.
- Be careful with `trap` under `set -u`: expand local paths when setting the trap, and clear the trap before returning if needed.
- Never use `rm -rf "${var}/..."` unless `var` is known-safe; prefer `${var:?}` guards.

## Testing

- After changes in `lib/` or `templates/`, run `./tests/verify_fixes.sh`.
- If you touch generation logic or templates, also run `./tests/generate_regressions.sh`.
- If you touch discovery or cask matching logic, run `./tests/discovery_strategy_test.sh`.
- `tests/batch_discovery_test.sh` and `tests/benchmark_approaches.sh` are exploratory/benchmark scripts, not the default regression suite.
- If you change `lib/gum.sh`, test the fallback path with `GUM_AVAILABLE=false` before sourcing it.
- Use `agent-tui` when you need to verify wizard behavior in a real PTY.

## Task Map

| Task | File(s) |
|------|---------|
| Update CLI args or command dispatch | `dotfriend`, `bin/dotfriend.js` |
| Change runtime bootstrapping | `lib/bootstrap.sh` |
| Add or modify wizard steps | `lib/wizard.sh` |
| Change discovery behavior | `lib/discovery.sh`, `lib/cask-map.json`, `lib/agent-tools.json` |
| Change macOS preference backup/restore | `lib/macos_preferences.sh`, `lib/wizard.sh`, `lib/generate.sh`, `templates/install.sh` |
| Change generated repo contents | `lib/generate.sh`, `templates/` |
| Change sync behavior | `lib/sync.sh` |
| Change Gum wrappers or TUI behavior | `lib/gum.sh` |
| Update regression coverage | `tests/` |

## Keep Out of AGENTS

- Long product descriptions
- Full architecture walkthroughs that duplicate `README.md`
- Large troubleshooting tables for one-off historical bugs
- Long `agent-tui` tutorials or smoke-test scripts

If guidance becomes long, move it to a dedicated doc and leave a short pointer here.
