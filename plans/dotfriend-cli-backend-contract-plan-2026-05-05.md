# dotfriend CLI Backend Contract Plan

Date: 2026-05-05
Status: ready for implementation
Purpose: make the existing Bash CLI a stable backend for a future macOS menu bar app and for safer agent configuration sync.

This is the index plan. Detailed implementation instructions live in the phase files listed below.

## Goal

Turn `dotfriend` from a mostly human-facing Bash/Gum CLI into a dual-mode backend:

1. Human terminal mode stays friendly and interactive.
2. App/backend mode exposes stable JSON outputs, event streams, typed manifests, preflight states, and safe config merge behavior.

The app should never need to parse colored text, Gum prompts, generated shell snippets, or ambiguous newline-delimited cache fields.

## Non-Goals

1. Do not build the SwiftUI menu bar app in this plan.
2. Do not introduce a daemon, HTTP server, Electron shell, or background service.
3. Do not rewrite dotfriend out of Bash.
4. Do not change real user machine state in tests.
5. Do not implement cloud/team/fleet behavior.
6. Do not store plaintext secrets in generated repos or caches.

## Phase Files

Implement in this order:

1. [Phase 1: API Output and Runtime Preflight](./dotfriend-cli-backend-contract-phase-1-api-preflight.md)
2. [Phase 2: Structured Discovery and Restore Manifest](./dotfriend-cli-backend-contract-phase-2-discovery-manifest.md)
3. [Phase 3: Manifest-Driven Sync and Generated Backup](./dotfriend-cli-backend-contract-phase-3-sync-backup.md)
4. [Phase 4: Agent Artifacts and Managed Merge](./dotfriend-cli-backend-contract-phase-4-agent-artifacts-merge.md)
5. [Phase 5: Documentation, UX, and Verification](./dotfriend-cli-backend-contract-phase-5-docs-verification.md)

## Current Problems to Fix

1. `dotfriend start` and `dotfriend sync` directly bootstrap runtime tools before app-grade preflight or consent.
2. `~/.cache/dotfriend/discovery.json` stores many values as multiline strings.
3. Generated repos contain `.dotfriend/selections.json` and generated shell restore blocks, but no durable `.dotfriend/restore-manifest.json`.
4. `lib/generate.sh`, `lib/sync.sh`, and generated `scripts/backup.sh` do not consume one shared manifest contract.
5. `templates/scripts/backup.sh` guesses agent canonical paths as `${HOME}/.${id}` instead of reading `canonical_dir`.
6. Agent config is copied at file/directory level, not represented as managed artifacts.
7. There is no stable JSON/event contract for status, discovery progress, warnings, install plans, sync results, or job failures.

## Compatibility Requirements

Existing commands must keep working:

```bash
dotfriend start
dotfriend start --dry-run
dotfriend sync
dotfriend sync --dry-run
dotfriend sync --no-commit
dotfriend sync --quick
dotfriend --help
dotfriend --version
```

Additional requirements:

1. Existing generated repos without a manifest must still be usable.
2. Existing tests must continue to pass unless updated for a deliberate contract change.
3. Generated Bash must remain readable and mostly flat.
4. Use `jq` for normal repo code.
5. Keep no-`jq` fallbacks only where generated scripts must run before full runtime is available.

## New Backend Command Contract

Add these commands across the phase work:

```bash
dotfriend preflight --json
dotfriend discover --json
dotfriend discover --events
dotfriend plan --json
dotfriend status --json
dotfriend sync --events
dotfriend agent status --json
dotfriend agent check --json
dotfriend agent sync --dry-run --json
dotfriend agent suggest --json
```

Rules:

1. `--json` prints exactly one JSON object to stdout.
2. `--events` prints newline-delimited JSON, one object per line.
3. Human logs go to stderr when `--json` or `--events` is active.
4. No ANSI color, Gum UI, spinners, or progress bars in JSON/event stdout.
5. Any command that can change machine state must support dry-run or plan mode before write mode.
6. JSON fields must be additive and versioned.

## Common JSON Envelope

Every `--json` command returns this shape:

```json
{
  "contract_version": 1,
  "command": "preflight",
  "status": "ok",
  "warnings": [],
  "errors": [],
  "data": {}
}
```

Allowed `status` values:

1. `ok`
2. `warning`
3. `needs_approval`
4. `blocked`
5. `failed`

Warning/error object:

```json
{
  "code": "missing_homebrew",
  "message": "Homebrew is not installed.",
  "details": {}
}
```

## Event Stream Contract

Every `--events` line must be valid JSON:

```json
{"contract_version":1,"event":"job_started","job":"discover","time":"2026-05-05T12:00:00Z"}
{"contract_version":1,"event":"step_started","step":"agent_tools","label":"Scanning agent tools"}
{"contract_version":1,"event":"warning","code":"missing_cursor_config","message":"Cursor is installed but mcp.json was not found."}
{"contract_version":1,"event":"step_finished","step":"agent_tools","status":"ok","counts":{"found":3,"missing":2}}
{"contract_version":1,"event":"job_finished","job":"discover","status":"ok"}
```

Required event names:

1. `job_started`
2. `step_started`
3. `warning`
4. `error`
5. `item_changed`
6. `step_finished`
7. `approval_required`
8. `job_finished`

## Definition of Done

1. A menu bar app can call dotfriend commands and receive stable JSON/event output.
2. Discovery cache is structured and backward compatible.
3. Generated repos contain `.dotfriend/restore-manifest.json`.
4. Generated repos optionally contain `.dotfriend/agent-artifacts.json`.
5. Install, sync, backup, and validate behavior are derived from the manifest when it exists.
6. Agent configs are merged safely instead of overwritten blindly.
7. Generated backup no longer guesses canonical agent paths.
8. Tests prove dry-run/status/event contracts and fake-machine safety.
