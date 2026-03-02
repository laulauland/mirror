# CLAUDE.md — Agent Instructions for mirror

## What

mirror maintains a directory of symlinks to `.md` files from selected source directories. It lets you open the symlink directory as an Obsidian vault while editing real files in-place.

## Stack

- Language: Zig 0.15.2
- macOS FSEvents via DynLib (CoreServices) for file watching
- No external dependencies

## Read before coding

- Architecture and design: `docs/DESIGN.md`
- Zig gotchas: `docs/ZIG_PITFALLS.md`
- Debugging memory issues: `docs/DEBUGGING.md`

## Zig Conventions

- Arena allocator per command lifecycle
- DebugAllocator in Debug builds for leak detection
- Every `try alloc` except the last needs `errdefer free`
- No `anyerror` in public APIs — explicit error sets
- `zig fmt` enforced
- All tests use `std.testing.allocator` (auto leak detection)

## Config

`.mirror.json` in the output directory:
```json
{
  "root": "/path/to/source",
  "directories": ["project_a", "project_b"],
  "include": ["dist/generated/**/*.md"],
  "exclude": ["**/CHANGELOG.md"]
}
```

Priority: exclude > include > .gitignore

## Commands

- `mirror init` — dual-mode setup: interactive TUI when TTY, flag-driven (`--root`, `--directories`, `--output`) when piped or flags present
- `mirror sync` — one-shot sync
- `mirror watch` — foreground FSEvents watcher
- `mirror up` — start daemon
- `mirror down` — stop daemon

## Recursion Guards

`scanMarkdownFiles` has three protections against infinite recursion:
1. Path component check — skips `.git` and output directory in any path component
2. Symlink cycle detection — tracks visited real paths, skips revisits
3. Output directory exclusion — output dir name always skipped by the scanner

## Testing

- `zig build test` runs all tests
- All tests use `std.testing.allocator` (auto leak detection)
- Integration tests exercise full sync pipeline with tmpDir
