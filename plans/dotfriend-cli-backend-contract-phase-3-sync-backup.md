# Phase 3: Manifest-Driven Sync and Generated Backup

## Objective

Make install, sync, backup, status, and validate consume the restore manifest when it exists. Fix generated backup agent path drift.

## Files

1. `lib/sync.sh`
2. new `lib/status.sh`
3. `lib/generate.sh`
4. `templates/install.sh`
5. `templates/scripts/backup.sh`
6. `templates/scripts/validate.sh`
7. `dotfriend`
8. new `tests/sync_manifest_test.sh`
9. new `tests/generated_backup_agent_metadata_test.sh`

## Manifest-Driven Sync

Add `_load_restore_manifest` to `lib/sync.sh`.

Behavior:

1. If `.dotfriend/restore-manifest.json` exists, sync only manifest-owned paths.
2. If no manifest exists, use current legacy behavior and emit a warning.
3. Do not copy unselected discovered configs.
4. Do not delete live files unless the manifest explicitly allows deletion.

Drift codes:

1. `missing_live_target`
2. `missing_repo_source`
3. `changed_live_file`
4. `changed_repo_file`
5. `untracked_discovered_config`
6. `manifest_schema_error`

## Status Command

Add:

```bash
dotfriend status --json
dotfriend plan --json
```

`status --json` data shape:

```json
{
  "managed_repo": "/Users/name/dotfiles",
  "manifest_found": true,
  "manifest_schema_version": 1,
  "last_sync": {},
  "counts": {"items": 42, "warnings": 1, "drift": 3},
  "drift": []
}
```

`plan --json` must show what restore or sync would do without writing.

## Sync Events

Add:

```bash
dotfriend sync --events
```

Required item-level event example:

```json
{"contract_version":1,"event":"item_changed","item_id":"agent:codex:AGENTS.md","change":"updated","repo_path":"codex/AGENTS.md"}
```

## Generated Backup Agent Metadata Fix

Current broken behavior in `templates/scripts/backup.sh`:

```bash
canonical_dir="${HOME}/.${id}"
```

Replace with metadata lookup:

```bash
canonical_dir="$(jq -r --arg id "$id" '.agentic_tools[] | select(.id == $id) | .canonical_dir // empty' "$agents_file")"
canonical_dir="${canonical_dir/#\~/${HOME}}"
```

Required metadata reads:

1. `canonical_dir`
2. `important_files`
3. `important_dirs`
4. `symlinks_to_skip`

Required shared store behavior:

1. Sync `~/.agents/skills` to `agents/skills` once.
2. Sync `~/.agents/agent-docs` to `agents/agent-docs` once.
3. Do not separately sync `~/.codex/skills` if it is a symlink mirror.
4. Do not separately sync `~/.claude/skills` if it is a symlink mirror.

Add metadata if useful:

```json
{
  "shared_stores": [
    {"id":"skills","source":"~/.agents/skills","repo_path":"agents/skills","restore_mode":"rsync"},
    {"id":"agent-docs","source":"~/.agents/agent-docs","repo_path":"agents/agent-docs","restore_mode":"rsync"}
  ]
}
```

## Generated Install and Validate

When manifest exists:

1. `install.sh` must dispatch restore behavior from manifest items.
2. `validate.sh` must validate manifest presence, schema, repo paths, target paths, and missing sources.
3. `backup.sh` must sync manifest-owned paths.

When manifest does not exist:

1. Scripts must use legacy behavior.
2. Scripts must print a clear warning.

## Tests

`tests/sync_manifest_test.sh`:

1. Fake generated repo with manifest.
2. Fake `HOME`.
3. Dry-run sync reports only manifest-owned paths.
4. Unselected config dirs are not copied.
5. Missing live target returns structured drift.
6. Legacy repo without manifest still syncs with warning.

`tests/generated_backup_agent_metadata_test.sh`:

1. Fake `zed` config under `~/.config/zed` syncs correctly.
2. Fake `copilot` config under `~/.config/github-copilot` syncs correctly.
3. Fake `codex/skills` symlink is skipped.
4. Fake `~/.agents/skills` syncs once to `agents/skills`.
5. Dry-run output does not claim `${HOME}/.zed` or `${HOME}/.copilot`.

## Done When

1. Sync/status/plan are manifest-aware.
2. Generated backup script no longer guesses agent paths.
3. Generated scripts remain backward compatible with legacy repos.
