# Phase 4: Agent Artifacts and Managed Merge

## Objective

Represent agent configuration as explicit artifacts and apply those artifacts through safe merge adapters instead of blind full-file copies.

## Files

1. new `lib/agent-artifacts.sh`
2. new `lib/agent-adapters.sh`
3. new `lib/merge-json.sh`
4. new `lib/merge-markdown.sh`
5. `lib/agent-tools.json`
6. `lib/generate.sh`
7. `lib/sync.sh`
8. `templates/install.sh`
9. `templates/scripts/backup.sh`
10. new `tests/agent_artifact_manifest_test.sh`
11. new `tests/managed_merge_test.sh`

## Agent Artifact Manifest

Generate this file when agent configs are selected:

```bash
.dotfriend/agent-artifacts.json
```

Schema:

```json
{
  "schema_version": 1,
  "artifacts": [
    {
      "id": "github-mcp",
      "kind": "mcp",
      "name": "GitHub MCP",
      "tools": ["claude", "codex", "cursor"],
      "scope": "user",
      "source": {"type":"inline_json","repo_path":"agents/artifacts/github-mcp.json"},
      "install": {"strategy":"managed_json_merge"},
      "targets": [
        {"tool":"cursor","path":"~/.cursor/mcp.json","json_path":"mcpServers.github"}
      ],
      "managed_by": "dotfriend",
      "secret_refs": [{"name":"GITHUB_TOKEN","provider":"env_or_1password"}]
    }
  ]
}
```

Allowed `kind` values:

1. `mcp`
2. `skill`
3. `instruction`
4. `rule`
5. `command`
6. `agent`
7. `secret_ref`

Allowed `scope` values:

1. `user`
2. `project`
3. `shared`

Allowed install strategies:

1. `managed_json_merge`
2. `managed_markdown_block`
3. `copy_managed_file`
4. `rsync_managed_dir`
5. `symlink_shared_store`
6. `manual_followup`

## Agent Commands

Add:

```bash
dotfriend agent status --json
dotfriend agent check --json
dotfriend agent sync --dry-run --json
dotfriend agent suggest --json
```

Rules:

1. `agent status` reports selected tools, shared stores, artifact count, and drift.
2. `agent check` validates `agent-artifacts.json`.
3. `agent sync --dry-run --json` previews artifact writes.
4. `agent suggest --json` detects local MCPs/skills/rules and emits proposed artifacts only. It must not write.

## JSON Merge Adapter

Add `lib/merge-json.sh`.

Behavior:

1. Read existing target JSON.
2. Validate target JSON parses.
3. Backup previous file before write.
4. Write atomically through a temp file plus `mv`.
5. Preserve unmanaged entries.
6. Replace entries carrying `_managed_by: "dotfriend"` when the artifact id matches.
7. Add missing managed entries only when approved.
8. Never log or copy plaintext secret values.

Example managed MCP entry:

```json
{
  "command": "github-mcp-server",
  "env": {"GITHUB_TOKEN": "${GITHUB_TOKEN}"},
  "_managed_by": "dotfriend",
  "_dotfriend_artifact_id": "github-mcp"
}
```

## Markdown Merge Adapter

Add `lib/merge-markdown.sh`.

Managed block format:

```markdown
<!-- dotfriend:start id="global-instructions" -->
managed content
<!-- dotfriend:end id="global-instructions" -->
```

Behavior:

1. Replace only matching managed block.
2. Append block if missing and approved.
3. Preserve all text outside the block.
4. Refuse ambiguous duplicate block ids unless `--repair` is explicitly added later.

## Skills, Rules, and Commands Adapter

Add logic in `lib/agent-adapters.sh`.

Rules:

1. Managed shared skills live under `~/.agents/skills`.
2. Managed shared docs live under `~/.agents/agent-docs`.
3. Tool-specific skills dirs should be symlink mirrors when safe.
4. Never delete unmarked local files.
5. Only delete managed files when manifest/artifact explicitly says they were removed.

## Full-File Ownership

Full-file overwrite is forbidden unless the manifest item says:

```json
{"ownership":"dotfriend_full_file"}
```

Default ownership is:

```json
{"ownership":"managed_partial"}
```

## Tests

`tests/agent_artifact_manifest_test.sh`:

1. Generated repo includes `agent-artifacts.json`.
2. Artifact schema validates.
3. `agent check --json` reports invalid schema.
4. `agent suggest --json` writes nothing.
5. Secret values are not copied into artifacts.

`tests/managed_merge_test.sh`:

1. Cursor `mcp.json` with personal server plus managed server preserves personal server.
2. Updating managed MCP replaces only managed entry.
3. Markdown adapter preserves user text outside managed block.
4. Invalid JSON blocks write and returns structured error.
5. Full-file overwrite requires explicit `dotfriend_full_file` ownership.

## Done When

1. Agent configs are artifact-driven.
2. Managed JSON/Markdown updates preserve user config.
3. Skills/rules/commands sync through canonical shared stores.
