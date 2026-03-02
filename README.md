# mirror

Maintains a directory of symlinks to `.md` files from selected source directories. Open the output directory as an Obsidian vault or in any editor — edits go straight to the real files.

Built to work around Obsidian choking on large monorepos (500k+ files). Instead of opening the whole repo, mirror creates a lightweight view of just the markdown.

## Usage

```
mirror init          # interactive setup (TUI) or flag-driven
mirror sync          # one-shot sync
mirror watch         # foreground file watcher
mirror up            # start background daemon
mirror down          # stop daemon
```

### Init

Interactive when run in a TTY — lists subdirectories sorted by last modified, toggle with space, confirm with enter. Prompts for output directory name (default `_notes`).

Programmatic when piped or flags are provided:

```
mirror init --root /path/to/code --directories project_a,project_b --output _notes
```

### Sync

Walks selected source directories, creates symlinks for every `.md` file preserving directory structure. Removes stale symlinks and cleans empty directories.

### Watch

FSEvents-based watcher (macOS). Picks up new/renamed/deleted `.md` files and updates symlinks in real time.

## Config

Written to `.mirror.json` in the output directory:

```json
{
  "root": "/Users/you/Code/work",
  "directories": ["project_a", "project_b"],
  "include": ["dist/generated/**/*.md"],
  "exclude": ["**/CHANGELOG.md"]
}
```

- **include** overrides `.gitignore` (force-include paths that would otherwise be ignored)
- **exclude** overrides everything (force-exclude regardless of other rules)
- `.gitignore` is respected by default

Priority: `exclude` > `include` > `.gitignore`

## Building

Requires Zig 0.15.2 and macOS (uses CoreServices for FSEvents).

```
zig build
zig build run -- sync
zig build test
```

## How it works

Symlinks use absolute targets: `_notes/project/docs/guide.md` → `/abs/path/project/docs/guide.md`. Parent directories are created as needed.

The scanner guards against recursion — it skips `.git`, the output directory itself, and detects symlink cycles by tracking visited real paths.
