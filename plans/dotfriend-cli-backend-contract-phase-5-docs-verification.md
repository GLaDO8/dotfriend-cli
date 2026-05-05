# Phase 5: Documentation, UX, and Verification

## Objective

Document the new backend contract and prove the implementation with fake-machine tests. Keep the user-facing story understandable for a future menu bar app.

## Files

1. `README.md`
2. `lib/generate.sh`
3. generated repo `README.md`
4. generated repo `.dotfriend/README.md`
5. `templates/scripts/validate.sh`
6. all new test files from earlier phases

## Documentation Updates

Top-level `README.md` must separate:

1. Human commands.
2. Backend/app-safe commands.
3. Generated repo contents.
4. Safety model.

Backend command table must include:

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

Generated repo README must explain:

1. `.dotfriend/restore-manifest.json`
2. `.dotfriend/agent-artifacts.json`
3. `.dotfriend/selections.json`
4. what dotfriend owns
5. what dotfriend will not touch
6. how to run dry-run/status/check

Add a managed config safety section:

1. Personal config is preserved.
2. Managed JSON entries use `_managed_by: "dotfriend"`.
3. Managed Markdown uses dotfriend block markers.
4. Full-file overwrite requires explicit manifest ownership.

## Validation Updates

`templates/scripts/validate.sh` must check:

1. Restore manifest exists when expected.
2. Restore manifest schema version is supported.
3. Every `repo_path` is relative and safe.
4. Every `target_path` is allowed.
5. `agent-artifacts.json` schema is valid when present.
6. Managed files do not contain obvious plaintext secret values.

## Required Verification Commands

Run:

```bash
bash -n dotfriend lib/*.sh templates/*.sh templates/scripts/*.sh tests/*.sh
./tests/verify_fixes.sh
./tests/generate_regressions.sh
./tests/discovery_strategy_test.sh
```

Run all new tests:

```bash
./tests/api_contract_test.sh
./tests/preflight_contract_test.sh
./tests/discovery_contract_test.sh
./tests/manifest_contract_test.sh
./tests/sync_manifest_test.sh
./tests/generated_backup_agent_metadata_test.sh
./tests/agent_artifact_manifest_test.sh
./tests/managed_merge_test.sh
```

## Test Safety Rules

All new tests must:

1. Use fake `HOME`.
2. Use fake `PATH`.
3. Use fake `brew`, `npm`, `mas`, `gh`, `code`, `cursor`, and agent tool shims where needed.
4. Avoid real Dock/defaults writes.
5. Avoid real `~/.claude`, `~/.codex`, `~/.cursor`, `~/.agents`.
6. Avoid network access.
7. Assert generated files with `jq`, `bash -n`, and specific path checks.

## Implementation Completion Checklist

1. `lib/api.sh` exists and powers JSON/event output.
2. `preflight --json` reports planned actions without writes.
3. Discovery cache is schema version 2 and structured.
4. Legacy discovery cache fixtures still work.
5. Generated repos contain `.dotfriend/restore-manifest.json`.
6. Manifest validation rejects unsafe paths.
7. `status --json`, `plan --json`, and `sync --events` work.
8. Generated backup reads `canonical_dir` from `.dotfriend/agent-tools.json`.
9. Shared agent stores sync once from `~/.agents`.
10. Agent artifact manifest exists when agents are selected.
11. Managed JSON merge preserves unmanaged entries.
12. Managed Markdown merge preserves unmanaged text.
13. Documentation describes safety and backend commands.
14. All required tests pass.

## Handoff Notes for Implementing Agents

1. Start with Phase 1. Do not begin managed merge work until JSON/event output exists.
2. Do not remove existing human CLI behavior while adding backend mode.
3. Keep every write path paired with dry-run/status/check coverage.
4. Prefer narrow shell helpers over large rewrites.
5. Use `jq` for JSON reads and writes in repo code.
6. Use `apply_patch` for manual edits.
7. If touching `lib/` or `templates/`, run `./tests/verify_fixes.sh`.
8. If touching generation logic or templates, also run `./tests/generate_regressions.sh`.
9. If touching discovery, also run `./tests/discovery_strategy_test.sh`.
