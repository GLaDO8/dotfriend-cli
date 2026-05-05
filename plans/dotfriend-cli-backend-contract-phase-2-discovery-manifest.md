# Phase 2: Structured Discovery and Restore Manifest

## Objective

Replace app-hostile multiline discovery fields with structured arrays, then generate a durable restore manifest in generated repos.

## Files

1. `lib/discovery.sh`
2. `lib/wizard.sh`
3. `lib/generate.sh`
4. new `lib/manifest.sh`
5. `templates/install.sh`
6. `templates/scripts/validate.sh`
7. `tests/discovery_strategy_test.sh`
8. `tests/generate_regressions.sh`
9. new `tests/discovery_contract_test.sh`
10. new `tests/manifest_contract_test.sh`

## Structured Discovery Cache

Keep the existing cache path:

```bash
~/.cache/dotfriend/discovery.json
```

Change the cache to schema version 2:

```json
{
  "schema_version": 2,
  "generated_at": "2026-05-05T12:00:00Z",
  "apps": [{"name":"Cursor","path":"/Applications/Cursor.app","cask":"cursor","source":"cask"}],
  "formulae": [{"name":"git","description":"Distributed revision control system"}],
  "casks": [{"token":"cursor","name":"Cursor"}],
  "taps": [{"name":"homebrew/cask"}],
  "npm_globals": [{"name":"typescript","version":"5.9.0"}],
  "agents": [{"id":"codex","name":"OpenAI Codex","config_dir":"~/.codex","status":"found","skill_count":28}],
  "dotfiles": [{"path":".zshrc","status":"found"}],
  "config_dirs": [{"name":"zed","path":"~/.config/zed","status":"found"}],
  "editors": {
    "vscode": {"settings_path":"", "extensions":[]},
    "cursor": {"settings_path":"", "extensions":[]}
  },
  "dock": {"apps":[]}
}
```

Implementation:

1. Add `write_discovery_v2`.
2. Add `load_discovery_v2`.
3. Keep `load_discovery_legacy` for old cache files.
4. Update wizard reads to use v2 arrays when available.
5. Keep legacy split logic only behind the legacy loader.
6. Add:

```bash
dotfriend discover --json
dotfriend discover --events
```

Acceptance tests:

1. Discovery cache validates with `jq`.
2. `agents` is an array, not a newline string.
3. Wizard can read v2 cache fixtures.
4. Wizard can read legacy cache fixtures.
5. Event discovery emits parseable JSON lines.

## Restore Manifest

Generate this file into every generated repo:

```bash
.dotfriend/restore-manifest.json
```

Keep `.dotfriend/selections.json` for provenance, but do not treat it as the primary restore contract.

Schema:

```json
{
  "schema_version": 1,
  "generated_by": "dotfriend",
  "generated_at": "2026-05-05T12:00:00Z",
  "source_machine": {"hostname":"", "os":"darwin"},
  "items": [
    {
      "id": "dotfile:zshrc",
      "type": "dotfile",
      "restore_mode": "symlink",
      "repo_path": "zsh/.zshrc",
      "target_path": "~/.zshrc",
      "selected": true,
      "requires_approval": false
    }
  ],
  "manual_followups": []
}
```

Allowed `type` values:

1. `dotfile`
2. `config_dir`
3. `app_config`
4. `agent_config`
5. `agent_shared_store`
6. `editor_extensions`
7. `homebrew_formula`
8. `homebrew_cask`
9. `mas_app`
10. `npm_global`
11. `dock_layout`
12. `macos_defaults`
13. `generated_file`
14. `manual_followup`

Allowed `restore_mode` values:

1. `symlink`
2. `copy`
3. `rsync`
4. `managed_json_merge`
5. `managed_markdown_block`
6. `defaults_import`
7. `install_only`
8. `generated`
9. `manual_followup`

Manifest validation rules:

1. `repo_path` must be relative.
2. `repo_path` must not contain `..`.
3. `target_path` must start with `~/`, `$HOME/`, or be an explicitly allowed macOS absolute path.
4. `restore_mode` must be in the allowlist.
5. Destructive modes require non-empty `repo_path`.

Implementation:

1. Add `lib/manifest.sh`.
2. Add `manifest_add_item`.
3. Add `manifest_write`.
4. Add `manifest_validate`.
5. Make `lib/generate.sh` build the manifest while copying files.
6. Initially keep generated `install.sh` behavior unchanged, but assert it corresponds to manifest entries.

Acceptance tests:

1. Generated repo contains `.dotfriend/restore-manifest.json`.
2. Manifest has entries for selected dotfiles.
3. Manifest has entries for selected agents.
4. Manifest has entries for `agents/skills` and `agents/agent-docs` when present.
5. Manifest has entries for editor extension manifests.
6. Invalid manifest paths are rejected.
7. Existing generation regressions pass.

## Done When

1. Discovery is app-grade structured JSON.
2. Generated repos have a durable restore manifest.
3. Current human generation flow still works.
