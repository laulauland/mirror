---
drift:
  files:
    - src/main.zig#Config
    - src/main.zig#main
    - src/main.zig#runInit
    - src/main.zig#runSync
    - src/main.zig#runWatch
    - src/main.zig#scanMarkdownFiles
    - src/main.zig#createSymlink
    - src/main.zig#ResolvedSymbols
---

# mirror — Design

mirror maintains a directory of symlinks to `.md` files from selected source directories. Open the output as an Obsidian vault, edit files in Zed — changes go to the real files since symlinks point to them.

## Commands

### `mirror init`

Two modes, guarded by `isatty(stdin)`:

**Interactive (TTY):** Terminal UI with arrow keys and checkboxes. Lists subdirectories of CWD sorted by most recently modified first. User toggles selection with space, confirms with enter. Prompts for output directory name (default: `_notes`).

**Programmatic (flags/pipe):** `mirror init --root /path --directories project_a,project_b --output _notes`. When flags are provided they take precedence regardless of TTY. When stdin is not a TTY and no flags given, exits with error.

After setup, writes config and runs initial sync.

### `mirror sync`

One-shot sync. Three phases:

1. **Scan** — walk selected source directories, collect `.md` file paths. Respects `.gitignore`, config `include`/`exclude` patterns. Skips output directory and `.git` to prevent recursion. Tracks visited real paths to detect symlink cycles.
2. **Create** — for each `.md` file, create a symlink in the output directory preserving relative path structure. Idempotent: skips if symlink already exists with correct target.
3. **Clean** — remove broken/stale symlinks, then remove empty directories bottom-up.

### `mirror watch`

Foreground FSEvents watcher. Bidirectional:

- **Source -> output:** new `.md` file creates symlink, deleted `.md` removes symlink
- **Output -> source:** renamed symlink renames source file and updates symlink target, deleted symlink optionally deletes source

Uses macOS CoreServices FSEvents via `std.DynLib` (same pattern as Zig stdlib's `std/Build/Watch/FsEvents.zig`). Loads symbols at runtime, no compile-time framework headers needed.

### `mirror up` / `mirror down`

Daemon management. `up` spawns `mirror watch` as detached process, writes PID to `.mirror.pid`. `down` reads PID, sends SIGTERM, cleans up PID file.

## Config

Stored as `.mirror.json` in the output directory:

```json
{
  "root": "/Users/you/Code/work",
  "directories": ["project_a", "project_b"],
  "include": ["dist/generated/**/*.md"],
  "exclude": ["**/CHANGELOG.md"]
}
```

Filter priority: `exclude` > `include` > `.gitignore`

- **root** — absolute path to source root
- **directories** — subdirectories of root to scan
- **include** — glob patterns that override `.gitignore` (force-include)
- **exclude** — glob patterns that override everything (force-exclude)

## Recursion Guards

Three protections in @./src/main.zig#scanMarkdownFiles:

1. Path component check — skips entries containing `.git` or the output directory name in any path component
2. Symlink cycle detection — resolves real paths of symlinked directories, tracks visited set, skips revisits
3. Output directory exclusion — the output dir name is passed to the scanner and always skipped

## FSEvents Architecture

CoreServices types and symbols defined in @./src/main.zig#ResolvedSymbols, loaded at runtime via `std.DynLib`. The watcher:

1. Registers FSEventStream for source directories + output directory
2. Callback receives per-file events with flags (created, removed, renamed, is_symlink)
3. Source events trigger symlink create/remove
4. Output events on symlinks trigger source-side propagation (rename detection via target matching within debounce window)
5. Latency: 0.1s (batches events for efficiency)

## Symlink Convention

Symlinks use absolute targets: `_notes/project/docs/guide.md -> /abs/path/project/docs/guide.md`. Parent directories created recursively as needed.
