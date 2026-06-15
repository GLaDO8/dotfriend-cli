# dotfriend

A macOS CLI that turns your Mac into a version-controlled dotfiles repo — automatically.

Built with bash and [Gum](https://github.com/charmbracelet/gum) (by Charm). No compilation, no package manager needed for the tool itself.

## What it does

**`dotfriend start`** — An interactive wizard that scans your Mac, lets you pick what to back up, and generates a complete `dotfiles` repository. It detects your apps, Homebrew packages, npm globals, shell configs, editor settings, agentic tool configs, selected Mac settings, and even your Dock layout.

**`dotfriend sync`** — Keeps your repo in sync with your machine. Detects new brew packages, changed config files, and updated agent settings. Optionally commits and pushes to GitHub.

The generated repo includes a `bootstrap.sh` for brand-new Macs and an `install.sh` for full restoration - so you can go from a fresh macOS install to a fully configured machine in one command.

Generated repos also include `.dotfriend/restore-manifest.json`, `.dotfriend/agent-artifacts.json`, `.dotfriend/selections.json`, and `.dotfriend/agent-tools.json`. The restore manifest is the file/path contract for install, status, plan, sync, and backup. The agent artifact manifest is the contract for managed MCPs, instructions, rules, skills, commands, and shared stores. When Mac settings are selected, generated repos also include `macos/defaults.json` and `scripts/apply-macos-defaults.sh`.

## Installation

```bash
npx dotfriend start
```

Or clone and run directly:

```bash
git clone https://github.com/GLaDO8/dotfriend.git
cd dotfriend
./dotfriend start
```

Homebrew and Gum are installed automatically if missing.

## Human commands

| Command | Description |
|---------|-------------|
| `dotfriend start` | Interactive wizard. Scans your Mac and generates the dotfiles repo. |
| `dotfriend start --dry-run` | Preview what would be generated without writing files. |
| `dotfriend sync` | Incremental sync. Update the repo with changes from your machine. |
| `dotfriend sync --dry-run` | Preview what would change without applying. |
| `dotfriend sync --no-commit` | Apply changes but don't commit. |
| `dotfriend sync --quick` | Non-interactive sync. Skip prompts and commit with a default message. |
| `dotfriend --help` | Show usage. |
| `dotfriend --version` | Show version. |

## Backend/app-safe commands

These commands are stable for app callers. `--json` prints one JSON object. `--events` prints newline-delimited JSON. Human logs go to stderr.

| Command | Description |
|---------|-------------|
| `dotfriend preflight --json` | Report runtime readiness and planned bootstrap work without changing machine state. |
| `dotfriend discover --json` | Run discovery and return the structured discovery cache. |
| `dotfriend discover --json --cached` | Return the existing structured discovery cache without running discovery. |
| `dotfriend discover --events` | Stream discovery progress as JSON events. |
| `dotfriend generate --events --target <path> --no-push --force` | Generate selected repo contents for an app-managed first sync without prompting or pushing. |
| `dotfriend plan --json` | Report planned sync actions from the manifest. |
| `dotfriend status --json` | Report generated repo, manifest, and drift status. |
| `dotfriend sync --events` | Stream sync progress as JSON events. |
| `dotfriend agent status --json` | Report selected agent tools, shared stores, artifact count, and drift. |
| `dotfriend agent check --json` | Validate `.dotfriend/agent-artifacts.json`. |
| `dotfriend agent sync --dry-run --json` | Preview managed agent artifact writes. |
| `dotfriend agent suggest --json` | Detect local agent config candidates and return proposed artifacts without writing. |

## Safety model

dotfriend writes only generated repo content and selected restore targets. It does not intentionally back up secrets, chat history, caches, logs, TCC/privacy grants, app logins, iCloud session state, Keychain items, or opaque app databases.

Mac settings discovery is curated. dotfriend reads only the scalar settings listed in `lib/macos-defaults.json`; it does not export whole defaults domains or scrape settings at runtime. Safe and reversible settings can be selected by default. Settings marked `attention` or `risky` are shown for review but require explicit opt-in.

Managed agent config is partial by default:

- Personal JSON entries are preserved.
- Managed JSON entries carry `_managed_by: "dotfriend"` and `_dotfriend_artifact_id`.
- Managed Markdown uses `<!-- dotfriend:start id="..." -->` and `<!-- dotfriend:end id="..." -->` markers.
- Whole-file overwrite requires explicit `ownership: "dotfriend_full_file"`.
- Backend write paths have a dry-run, status, or check command so an app can ask before applying changes.

## What gets backed up

### System & packages
- **Homebrew** — taps, formulae, casks, Mac App Store apps (via `mas`)
- **npm** — globally installed packages
- **Dock layout** — app list (restorable via `dockutil`)
- **Mac settings** — selected scalar settings from the curated catalog, currently covering Dock, Finder, Desktop, Screenshots, Menu Bar, Keyboard, Mouse, Trackpad, Mission Control, Safari, TextEdit, Xcode, Simulator, Activity Monitor, Messages, and Time Machine

### Config files
- Shell configs (`.zshrc`, `.bashrc`, `.gitconfig`, `.tmux.conf`, etc.)
- `~/.config/` directories for detected apps
- Editor settings (VS Code, Cursor — including extensions)

### Mac settings details

Selected Mac settings are written to `macos/defaults.json` with the reviewed values. `install.sh` applies them through `scripts/apply-macos-defaults.sh`, which uses typed `defaults write` calls and backs up affected preference domains before writing. Ongoing sync refreshes only the selected entries; it does not add newly discovered settings without another review.

Validate a generated repo with:

```bash
./scripts/validate.sh --all
```

The validation script checks that `macos/defaults.json` is valid JSON, uses schema version 1, contains only supported scalar value types, and has an executable apply script.

### Agentic tools (selective, smart backup)
Only config files are backed up — never chat history, cache, or logs.

| Tool | What gets backed up |
|------|---------------------|
| **Claude Code** | `CLAUDE.md`, `settings.json`, `hooks/`, `rules/`, `plugins/` |
| **OpenAI Codex** | `AGENTS.md`, `RTK.md`, `CLAUDE.md`, `skills/`, `agent-docs/` |
| **Cursor** | `settings.json`, `mcp.json`, `keybindings.json`, `extensions.txt`, `rules/` |
| **Aider** | `.aider.conf.yml`, `.aider.model.settings.yml`, `.aiderignore` |
| **Continue.dev** | `config.json`, `config.ts`, `.prompts/` |
| **GitHub Copilot CLI** | `~/.config/github-copilot/` |
| **Zed** | `settings.json`, `keymap.json`, `themes/` |
| **Windsurf** | `settings.json`, `keybindings.json`, `extensions/` |
| **Cline** | `settings.json` |
| **Trae** | `settings.json`, `keybindings.json`, `extensions/` |

## Requirements

- macOS (Apple Silicon or Intel)
- bash 4+

`dotfriend` automatically installs **Homebrew** and **Gum** if they're not present. Optional enhancements come from `jq`, `gh`, `mas`, and `npm` if you have them.

## Why dotfriend?

Most dotfiles tools expect you to hand-write your config. `dotfriend` starts from your *actual* machine state and builds the repo for you. It's designed for people who:

- Want a dotfiles repo but haven't gotten around to making one
- Frequently set up new Macs and want a one-command restore
- Use multiple agentic AI tools and want their configs versioned
- Prefer bash + Gum over compiled binaries for transparency and hackability

## License

MIT
