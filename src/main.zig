const std = @import("std");
const posix = std.posix;
const json = std.json;
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const config_filename = ".mirror.json";
const pid_filename = ".mirror.pid";

const Config = struct {
    root: []const u8,
    directories: []const []const u8,
    include: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// Gitignore
// ---------------------------------------------------------------------------

const GitignoreRules = struct {
    patterns: std.ArrayListUnmanaged(Pattern) = .empty,
    allocator: Allocator,

    const Pattern = struct {
        text: []const u8,
        negated: bool,
        directory_only: bool,
        anchored: bool, // contains '/' in the middle (not just trailing)
    };

    fn init(allocator: Allocator) GitignoreRules {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *GitignoreRules) void {
        for (self.patterns.items) |p| self.allocator.free(p.text);
        self.patterns.deinit(self.allocator);
    }

    /// Load .gitignore from the given directory path. Silently succeeds if no
    /// .gitignore exists.
    fn load(self: *GitignoreRules, directory_path: []const u8) !void {
        const gitignore_path = try fs.path.join(self.allocator, &.{ directory_path, ".gitignore" });
        defer self.allocator.free(gitignore_path);

        const file = fs.openFileAbsolute(gitignore_path, .{}) catch return;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return;
        defer self.allocator.free(content);

        var line_iter = mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |raw_line| {
            var line = mem.trim(u8, raw_line, &.{ ' ', '\t', '\r' });
            if (line.len == 0 or line[0] == '#') continue;

            var negated = false;
            if (line[0] == '!') {
                negated = true;
                line = line[1..];
                if (line.len == 0) continue;
            }

            // Strip leading '/' (anchors to root but we handle that via anchored flag)
            var anchored = false;
            if (line[0] == '/') {
                anchored = true;
                line = line[1..];
            }

            var directory_only = false;
            if (line.len > 0 and line[line.len - 1] == '/') {
                directory_only = true;
                line = line[0 .. line.len - 1];
            }

            if (line.len == 0) continue;

            // If pattern contains '/' it's anchored to the path structure
            if (!anchored and mem.indexOfScalar(u8, line, '/') != null) {
                anchored = true;
            }

            try self.patterns.append(self.allocator, .{
                .text = try self.allocator.dupe(u8, line),
                .negated = negated,
                .directory_only = directory_only,
                .anchored = anchored,
            });
        }
    }

    fn isIgnored(self: *const GitignoreRules, relative_path: []const u8) bool {
        var ignored = false;
        for (self.patterns.items) |pattern| {
            // directory_only patterns only match directories, but during file scan
            // we check path components, so we match against parent segments too
            if (pattern.directory_only) {
                // Check if any path component matches
                var component_iter = mem.splitScalar(u8, relative_path, '/');
                while (component_iter.next()) |component| {
                    if (matchGlob(pattern.text, component)) {
                        ignored = !pattern.negated;
                        break;
                    }
                }
            } else if (pattern.anchored) {
                // Match against the full relative path
                if (matchGlob(pattern.text, relative_path)) {
                    ignored = !pattern.negated;
                }
            } else {
                // Unanchored: match against basename or full path
                const basename = fs.path.basename(relative_path);
                if (matchGlob(pattern.text, basename) or matchGlob(pattern.text, relative_path)) {
                    ignored = !pattern.negated;
                }
            }
        }
        return ignored;
    }
};

// ---------------------------------------------------------------------------
// Glob matching
// ---------------------------------------------------------------------------

/// Match a glob pattern against a path. Supports '*' (any chars except '/'),
/// '**' (any chars including '/'), and '?' (single char).
fn matchGlob(pattern: []const u8, path: []const u8) bool {
    return matchGlobInner(pattern, path, 0);
}

fn matchGlobInner(pattern: []const u8, path: []const u8, depth: usize) bool {
    if (depth > 100) return false; // guard against degenerate patterns

    var pi: usize = 0;
    var si: usize = 0;

    // For backtracking on single '*'
    var star_pi: ?usize = null;
    var star_si: usize = 0;

    while (si < path.len or pi < pattern.len) {
        if (pi < pattern.len) {
            // Check for '**'
            if (pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*') {
                // Skip the '**' and optional following '/'
                var rest = pattern[pi + 2 ..];
                if (rest.len > 0 and rest[0] == '/') rest = rest[1..];

                // '**' matches zero or more path segments
                var s = si;
                while (s <= path.len) : (s += 1) {
                    if (matchGlobInner(rest, path[s..], depth + 1)) return true;
                }
                return false;
            }

            if (pattern[pi] == '?') {
                if (si < path.len and path[si] != '/') {
                    pi += 1;
                    si += 1;
                    continue;
                }
            } else if (pattern[pi] == '*') {
                star_pi = pi;
                star_si = si;
                pi += 1;
                continue;
            } else if (si < path.len and pattern[pi] == path[si]) {
                pi += 1;
                si += 1;
                continue;
            }
        }

        // Mismatch — backtrack to last '*' if possible
        if (star_pi) |sp| {
            star_si += 1;
            if (star_si <= path.len and (star_si == path.len or path[star_si - 1] != '/')) {
                pi = sp + 1;
                si = star_si;
                continue;
            }
            // '*' can't cross '/' boundaries
            if (star_si <= path.len and path[star_si - 1] == '/') {
                return false;
            }
        }

        return false;
    }

    return true;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (mem.eql(u8, command, "init")) {
        try runInit(allocator);
    } else if (mem.eql(u8, command, "sync")) {
        try runSync(allocator);
    } else if (mem.eql(u8, command, "watch")) {
        try runWatch(allocator);
    } else if (mem.eql(u8, command, "up")) {
        try runDaemonStart(allocator);
    } else if (mem.eql(u8, command, "down")) {
        try runDaemonStop(allocator);
    } else if (mem.eql(u8, command, "add") or mem.eql(u8, command, "remove")) {
        try runModifyDirectories(allocator, args[2..]);
    } else if (mem.eql(u8, command, "help")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    const usage =
        \\Usage: mirror <command>
        \\
        \\Commands:
        \\  init           Interactive setup — pick output dir and source directories
        \\  sync           One-shot scan: create/remove symlinks based on config
        \\  add [dir]...   Toggle directories (interactive picker or explicit args)
        \\  remove [dir].. Alias for add
        \\  watch          Foreground FSEvents watcher (both directions)
        \\  up             Start watcher as a background daemon
        \\  down           Stop the background daemon
        \\  help           Show this message
        \\
    ;
    std.debug.print("{s}", .{usage});
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// Interactive setup: list subdirectories sorted by mtime (most recent first),
/// let the user toggle selections with a terminal UI, pick an output directory,
/// write config, and run initial sync.
fn runInit(allocator: Allocator) !void {
    const cwd_path = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd_path);

    // Collect subdirectories with their modification times
    var directory_entries: std.ArrayListUnmanaged(DirectoryEntry) = .empty;
    defer directory_entries.deinit(allocator);

    var cwd_dir = try fs.openDirAbsolute(cwd_path, .{ .iterate = true });
    defer cwd_dir.close();

    var iterator = cwd_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        // Skip hidden directories and common non-content directories
        if (entry.name[0] == '.') continue;
        if (mem.eql(u8, entry.name, "node_modules")) continue;
        if (mem.eql(u8, entry.name, "zig-out")) continue;
        if (mem.eql(u8, entry.name, "zig-cache")) continue;

        const stat = cwd_dir.statFile(entry.name) catch continue;
        const name_copy = try allocator.dupe(u8, entry.name);
        try directory_entries.append(allocator, .{
            .name = name_copy,
            .modification_time_ns = stat.mtime,
        });
    }

    defer for (directory_entries.items) |entry| allocator.free(entry.name);

    // Sort by modification time descending (most recent first)
    mem.sort(DirectoryEntry, directory_entries.items, {}, struct {
        fn lessThan(_: void, a: DirectoryEntry, b: DirectoryEntry) bool {
            return a.modification_time_ns > b.modification_time_ns;
        }
    }.lessThan);

    if (directory_entries.items.len == 0) {
        std.debug.print("No subdirectories found in current directory.\n", .{});
        return;
    }

    // Check if stdin is a TTY for interactive mode
    if (!posix.isatty(posix.STDIN_FILENO)) {
        // TODO: Support flag-driven mode (--root, --directories, --output)
        std.debug.print("Error: stdin is not a terminal and no flags provided.\n", .{});
        std.debug.print("Run 'mirror init' from an interactive terminal, or use flags (not yet implemented).\n", .{});
        return;
    }

    // Interactive directory selection
    const selected = try allocator.alloc(bool, directory_entries.items.len);
    defer allocator.free(selected);
    @memset(selected, false);

    const names = try allocator.alloc([]const u8, directory_entries.items.len);
    defer allocator.free(names);
    for (directory_entries.items, 0..) |entry, i| {
        names[i] = entry.name;
    }

    runInitCheckboxSelector(names, selected) catch |err| {
        std.debug.print("Terminal error during directory selection: {}\n", .{err});
        return;
    };

    // Check if any directories were selected
    var any_selected = false;
    for (selected) |s| {
        if (s) {
            any_selected = true;
            break;
        }
    }
    if (!any_selected) {
        std.debug.print("No directories selected. Aborting.\n", .{});
        return;
    }

    // Text input for output directory name
    const output_directory = runInitTextPrompt(allocator) catch |err| {
        std.debug.print("Terminal error during text input: {}\n", .{err});
        return;
    };
    defer allocator.free(output_directory);

    // Build config
    var selected_directories: std.ArrayListUnmanaged([]const u8) = .empty;
    defer selected_directories.deinit(allocator);
    for (directory_entries.items, 0..) |entry, index| {
        if (selected[index]) {
            try selected_directories.append(allocator, entry.name);
        }
    }

    const config = Config{
        .root = cwd_path,
        .directories = selected_directories.items,
    };

    // Create output directory if it doesn't exist
    const output_absolute = try fs.path.join(allocator, &.{ cwd_path, output_directory });
    defer allocator.free(output_absolute);
    fs.makeDirAbsolute(output_absolute) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write config
    const config_path = try fs.path.join(allocator, &.{ cwd_path, output_directory, config_filename });
    defer allocator.free(config_path);
    try writeConfig(config, config_path, allocator);

    // Print summary
    std.debug.print("Mirror: {d} directories -> {s}/\n", .{ selected_directories.items.len, output_directory });
    std.debug.print("Config written to {s}/{s}\n", .{ output_directory, config_filename });

    // Run initial sync
    try runSyncWithConfig(allocator, config, output_absolute);

    std.debug.print("Initial sync complete.\n", .{});
}

/// Shared logic for add/remove: shows picker with current config state pre-selected,
/// or applies explicit dir args. Writes updated config and syncs.
fn runModifyDirectories(allocator: Allocator, dir_args: []const []const u8) !void {
    const cwd_path = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd_path);

    const config_path = findConfigFile(allocator, cwd_path) catch {
        std.debug.print("No .mirror.json found. Run 'mirror init' first.\n", .{});
        return;
    };
    defer allocator.free(config_path);

    const output_directory = fs.path.dirname(config_path) orelse return;

    const parsed = try readConfig(allocator, config_path);
    defer parsed.deinit();
    const config = parsed.value;

    // Collect all subdirectories (same logic as init)
    var directory_entries: std.ArrayListUnmanaged(DirectoryEntry) = .empty;
    defer directory_entries.deinit(allocator);

    var cwd_dir = try fs.openDirAbsolute(cwd_path, .{ .iterate = true });
    defer cwd_dir.close();

    var iterator = cwd_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name[0] == '.') continue;
        if (mem.eql(u8, entry.name, "node_modules")) continue;
        if (mem.eql(u8, entry.name, "zig-out")) continue;
        if (mem.eql(u8, entry.name, "zig-cache")) continue;
        // Skip the output directory itself
        const output_basename = fs.path.basename(output_directory);
        if (mem.eql(u8, entry.name, output_basename)) continue;

        const stat = cwd_dir.statFile(entry.name) catch continue;
        const name_copy = try allocator.dupe(u8, entry.name);
        try directory_entries.append(allocator, .{
            .name = name_copy,
            .modification_time_ns = stat.mtime,
        });
    }
    defer for (directory_entries.items) |entry| allocator.free(entry.name);

    mem.sort(DirectoryEntry, directory_entries.items, {}, struct {
        fn lessThan(_: void, a: DirectoryEntry, b: DirectoryEntry) bool {
            return a.modification_time_ns > b.modification_time_ns;
        }
    }.lessThan);

    if (directory_entries.items.len == 0) {
        std.debug.print("No subdirectories found.\n", .{});
        return;
    }

    const names = try allocator.alloc([]const u8, directory_entries.items.len);
    defer allocator.free(names);
    for (directory_entries.items, 0..) |entry, i| {
        names[i] = entry.name;
    }

    // Pre-select directories that are already in config
    const selected = try allocator.alloc(bool, directory_entries.items.len);
    defer allocator.free(selected);
    for (names, 0..) |name, i| {
        selected[i] = false;
        for (config.directories) |tracked| {
            if (mem.eql(u8, name, tracked)) {
                selected[i] = true;
                break;
            }
        }
    }

    if (dir_args.len > 0) {
        // Programmatic: apply explicit args as toggles
        for (dir_args) |arg| {
            for (names, 0..) |name, i| {
                if (mem.eql(u8, name, arg)) {
                    selected[i] = !selected[i];
                    break;
                }
            }
        }
    } else if (posix.isatty(posix.STDIN_FILENO)) {
        // Interactive: show picker with current state
        runInitCheckboxSelector(names, selected) catch |err| {
            std.debug.print("Terminal error: {}\n", .{err});
            return;
        };
    } else {
        std.debug.print("Usage: mirror add|remove <dir> [<dir>...]\n", .{});
        return;
    }

    // Build new directory list from selections
    var new_directories = std.ArrayListUnmanaged([]const u8).empty;
    defer new_directories.deinit(allocator);
    for (names, 0..) |name, i| {
        if (selected[i]) {
            try new_directories.append(allocator, name);
        }
    }

    const new_config = Config{
        .root = config.root,
        .directories = new_directories.items,
        .include = config.include,
        .exclude = config.exclude,
    };

    try writeConfig(new_config, config_path, allocator);
    std.debug.print("Updated to {d} directories. Running sync...\n", .{new_directories.items.len});

    try runSyncWithConfig(allocator, new_config, output_directory);
    std.debug.print("Sync complete.\n", .{});
}

// ---------------------------------------------------------------------------
// Terminal helpers for runInit
// ---------------------------------------------------------------------------

const TerminalState = struct {
    original: posix.termios,
    handle: posix.fd_t,

    fn enterRaw(handle: posix.fd_t) !TerminalState {
        const original = try posix.tcgetattr(handle);
        var raw = original;
        // Disable canonical mode, echo, and signal generation
        // Ctrl+C is handled explicitly in readKeypress
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        // Read one byte at a time, no timeout
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(handle, .NOW, raw);
        return .{ .original = original, .handle = handle };
    }

    fn restore(self: TerminalState) void {
        posix.tcsetattr(self.handle, .NOW, self.original) catch {};
    }
};

const Keypress = enum { up, down, space, enter, toggle_all, backspace, escape, interrupt, char, unknown };

const KeyResult = struct {
    key: Keypress,
    byte: u8,
};

fn writeStderr(bytes: []const u8) void {
    _ = posix.write(posix.STDERR_FILENO, bytes) catch {};
}

fn writeStderrFmt(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const slice = std.fmt.bufPrint(buf, fmt, args) catch return;
    writeStderr(slice);
}

fn readKeypress() !KeyResult {
    var buf: [1]u8 = undefined;
    const bytes_read = try posix.read(posix.STDIN_FILENO, &buf);
    if (bytes_read == 0) return .{ .key = .unknown, .byte = 0 };

    const byte = buf[0];

    if (byte == '\x1b') {
        // Escape sequence -- try to read '[' and the direction byte
        var seq: [2]u8 = undefined;
        const seq_read = posix.read(posix.STDIN_FILENO, &seq) catch return .{ .key = .escape, .byte = 0 };
        if (seq_read == 2 and seq[0] == '[') {
            return switch (seq[1]) {
                'A' => .{ .key = .up, .byte = 0 },
                'B' => .{ .key = .down, .byte = 0 },
                else => .{ .key = .unknown, .byte = 0 },
            };
        }
        return .{ .key = .escape, .byte = 0 };
    }

    return switch (byte) {
        3, 4 => .{ .key = .interrupt, .byte = 0 }, // Ctrl+C, Ctrl+D
        ' ' => .{ .key = .space, .byte = ' ' },
        '\r', '\n' => .{ .key = .enter, .byte = byte },
        'a', 'A' => .{ .key = .toggle_all, .byte = byte },
        127, '\x08' => .{ .key = .backspace, .byte = byte },
        else => .{ .key = .char, .byte = byte },
    };
}

fn getTerminalHeight() usize {
    var winsize: posix.winsize = .{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };
    const rc = posix.system.ioctl(posix.STDERR_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (rc == 0 and winsize.row > 0) return winsize.row;
    return 24; // fallback
}

fn runInitCheckboxSelector(names: []const []const u8, selected: []bool) !void {
    const terminal = try TerminalState.enterRaw(posix.STDIN_FILENO);
    defer terminal.restore();

    var cursor: usize = 0;
    var scroll_offset: usize = 0;
    var fmt_buf: [256]u8 = undefined;

    // Viewport: header + footer + padding = 4 lines reserved
    const term_height = getTerminalHeight();
    const max_visible = if (term_height > 6) term_height - 4 else 4;
    const visible_count = @min(names.len, max_visible);
    // header + visible entries + footer (scroll hint)
    const render_lines = visible_count + 2;

    writeStderr("\x1b[?25l");
    defer writeStderr("\x1b[?25h");

    var first_render = true;

    while (true) {
        if (!first_render) {
            writeStderrFmt(&fmt_buf, "\x1b[{d}A", .{render_lines});
        }
        first_render = false;

        // Header
        var selected_count: usize = 0;
        for (selected) |s| {
            if (s) selected_count += 1;
        }
        writeStderr("\x1b[2K\r");
        writeStderrFmt(&fmt_buf, "\x1b[1mSelect directories ({d}/{d} selected, space=toggle, a=all, enter=confirm):\x1b[0m\n", .{ selected_count, names.len });

        // Visible slice
        for (0..visible_count) |vi| {
            const i = scroll_offset + vi;
            writeStderr("\x1b[2K\r");

            if (i == cursor) {
                writeStderr("\x1b[7m");
            } else if (!selected[i]) {
                writeStderr("\x1b[2m");
            }

            const marker: u8 = if (selected[i]) 'x' else ' ';
            writeStderrFmt(&fmt_buf, "  [{c}] {s}", .{ marker, names[i] });
            writeStderr("\x1b[0m\n");
        }

        // Footer with scroll position
        writeStderr("\x1b[2K\r\x1b[2m");
        if (names.len > visible_count) {
            const at_top = scroll_offset == 0;
            const at_bottom = scroll_offset + visible_count >= names.len;
            if (at_top) {
                writeStderr("  ↓ more below");
            } else if (at_bottom) {
                writeStderr("  ↑ more above");
            } else {
                writeStderr("  ↑↓ scroll for more");
            }
        }
        writeStderr("\x1b[0m\n");

        const result = try readKeypress();
        switch (result.key) {
            .up => {
                if (cursor > 0) {
                    cursor -= 1;
                    if (cursor < scroll_offset) scroll_offset = cursor;
                }
            },
            .down => {
                if (cursor < names.len - 1) {
                    cursor += 1;
                    if (cursor >= scroll_offset + visible_count) scroll_offset = cursor - visible_count + 1;
                }
            },
            .space => {
                selected[cursor] = !selected[cursor];
            },
            .toggle_all => {
                var all_selected = true;
                for (selected) |s| {
                    if (!s) {
                        all_selected = false;
                        break;
                    }
                }
                @memset(selected, !all_selected);
            },
            .enter => {
                clearLines(&fmt_buf, render_lines);
                return;
            },
            .escape, .interrupt => {
                @memset(selected, false);
                clearLines(&fmt_buf, render_lines);
                return;
            },
            else => {},
        }
    }
}

fn clearLines(fmt_buf: []u8, line_count: usize) void {
    writeStderrFmt(fmt_buf, "\x1b[{d}A", .{line_count});
    for (0..line_count) |_| {
        writeStderr("\x1b[2K\n");
    }
    writeStderrFmt(fmt_buf, "\x1b[{d}A", .{line_count});
}

fn runInitTextPrompt(allocator: Allocator) ![]const u8 {
    const terminal = try TerminalState.enterRaw(posix.STDIN_FILENO);
    defer terminal.restore();

    const default_name = "_notes";
    var fmt_buf: [512]u8 = undefined;

    var input: [256]u8 = undefined;
    var length: usize = 0;

    // Show cursor for text input
    writeStderr("\x1b[?25h");

    while (true) {
        // Render prompt
        writeStderr("\x1b[2K\r");
        if (length == 0) {
            writeStderrFmt(&fmt_buf, "Output directory [\x1b[2m{s}\x1b[0m]: ", .{default_name});
        } else {
            writeStderrFmt(&fmt_buf, "Output directory: {s}", .{input[0..length]});
        }

        const result = try readKeypress();
        switch (result.key) {
            .enter => {
                writeStderr("\n");
                if (length == 0) {
                    return try allocator.dupe(u8, default_name);
                }
                return try allocator.dupe(u8, input[0..length]);
            },
            .backspace => {
                if (length > 0) length -= 1;
            },
            .escape, .interrupt => {
                writeStderr("\n");
                return try allocator.dupe(u8, default_name);
            },
            .char, .toggle_all => {
                // toggle_all is 'a'/'A' -- in text prompt context, treat as regular char
                if (length < input.len) {
                    input[length] = result.byte;
                    length += 1;
                }
            },
            else => {},
        }
    }
}

const DirectoryEntry = struct {
    name: []const u8,
    modification_time_ns: i128,
};

/// One-shot sync: read config, create symlinks for matching .md files,
/// remove stale symlinks, clean up empty directories.
fn runSync(allocator: Allocator) !void {
    const cwd_path = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd_path);

    const config_path = try findConfigFile(allocator, cwd_path);
    defer allocator.free(config_path);

    const parsed_config = try readConfig(allocator, config_path);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    // Output directory is the parent of the config file
    const output_directory = fs.path.dirname(config_path) orelse {
        std.debug.print("Error: cannot determine output directory from config path.\n", .{});
        return;
    };

    try runSyncWithConfig(allocator, config, output_directory);
}

fn runSyncWithConfig(allocator: Allocator, config: Config, output_directory: []const u8) !void {
    // Derive the output directory basename for the skip list
    const output_basename = fs.path.basename(output_directory);

    // Phase 1: Scan source directories and create symlinks for .md files
    var gitignore_rules = GitignoreRules.init(allocator);
    defer gitignore_rules.deinit();

    const markdown_files = try scanMarkdownFiles(
        allocator,
        config.root,
        config.directories,
        &gitignore_rules,
        config.include,
        config.exclude,
        output_basename,
    );
    defer {
        for (markdown_files) |path| allocator.free(path);
        allocator.free(markdown_files);
    }

    var created_count: usize = 0;
    for (markdown_files) |relative_path| {
        const did_create = try createSymlink(config.root, output_directory, relative_path, allocator);
        if (did_create) created_count += 1;
    }

    // Phase 2: Remove stale symlinks
    const removed_count = try removeStaleSymlinks(allocator, output_directory);

    // Phase 3: Remove empty directories in output
    try removeEmptyDirectories(output_directory);

    std.debug.print("Sync: {d} created, {d} removed, {d} total\n", .{
        created_count,
        removed_count,
        markdown_files.len,
    });
}

/// Foreground FSEvents watcher. Watches source directories and the output
/// directory bidirectionally. Source .md changes create/remove symlinks.
/// Output symlink changes propagate renames/moves/deletes back to source.
fn runWatch(allocator: Allocator) !void {
    const cwd_path = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd_path);

    const config_path = try findConfigFile(allocator, cwd_path);
    defer allocator.free(config_path);

    const parsed_config = try readConfig(allocator, config_path);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    const output_directory = fs.path.dirname(config_path) orelse {
        std.debug.print("Error: cannot determine output directory from config path.\n", .{});
        return;
    };

    // Initial sync before starting watch
    try runSyncWithConfig(allocator, config, output_directory);

    std.debug.print("Watching for changes... (press Ctrl+C to stop)\n", .{});

    // TODO: Set up FSEvents watcher using CoreServices DynLib pattern.
    //
    // 1. Open CoreServices via std.DynLib:
    //    var core_services = try std.DynLib.open(
    //        "/System/Library/Frameworks/CoreServices.framework/CoreServices"
    //    );
    //
    // 2. Resolve all symbols from ResolvedSymbols struct using inline for
    //    over @typeInfo(ResolvedSymbols).@"struct".fields
    //
    // 3. Build list of paths to watch: all config.directories (absolute) +
    //    the output directory.
    //
    // 4. Create CFString paths via CFStringCreateWithCString, pack into
    //    CFArray via CFArrayCreate.
    //
    // 5. Create dispatch queue and semaphore:
    //    const queue = dispatch_queue_create("mirror-watch", .SERIAL);
    //    const semaphore = dispatch_semaphore_create(0);
    //
    // 6. Create FSEventStream with:
    //    - callback that determines if event is in source or output dir,
    //      and either creates/removes symlinks or propagates changes back
    //    - latency ~0.1s
    //    - flags: .{ .file_events = true, .watch_root = true }
    //    - since_when: FSEventsGetCurrentEventId()
    //
    // 7. Attach stream to dispatch queue, start it.
    //
    // 8. Main loop: dispatch_semaphore_wait in a loop, re-sync on wake.
    //
    // 9. On SIGTERM/SIGINT: stop stream, invalidate, release, clean up.

    // Placeholder: block on stdin read until Ctrl+C
    var buffer: [1]u8 = undefined;
    _ = posix.read(posix.STDIN_FILENO, &buffer) catch {};
}

/// Spawn `mirror watch` as a detached background daemon, write PID to
/// .mirror.pid next to the config file.
fn runDaemonStart(allocator: Allocator) !void {
    const cwd_path = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd_path);

    const config_path = try findConfigFile(allocator, cwd_path);
    defer allocator.free(config_path);

    const parsed_config = try readConfig(allocator, config_path);
    defer parsed_config.deinit();

    const output_directory = fs.path.dirname(config_path) orelse {
        std.debug.print("Error: cannot determine output directory from config path.\n", .{});
        return;
    };

    const pid_path = try fs.path.join(allocator, &.{ output_directory, pid_filename });
    defer allocator.free(pid_path);

    // Check if already running
    if (fs.openFileAbsolute(pid_path, .{})) |file| {
        file.close();
        std.debug.print("Daemon appears to be already running (PID file exists at {s}).\n", .{pid_path});
        std.debug.print("Run 'mirror down' first if it's stale.\n", .{});
        return;
    } else |_| {}

    // TODO: Spawn `mirror watch` as a detached child process.
    //
    // 1. Get path to our own executable via std.fs.selfExePathAlloc or /proc/self/exe.
    //
    // 2. Use std.process.Child to spawn with:
    //    - argv: &.{ self_exe_path, "watch" }
    //    - cwd: cwd_path
    //    - stdin/stdout/stderr: .close (or redirect to log file)
    //
    // 3. The child should be detached from the terminal session.
    //    On macOS, after fork, call setsid() in the child. Since Zig's
    //    Child API doesn't support pre-exec hooks directly, an alternative
    //    is to use posix.fork + posix.execve manually, or accept that the
    //    child is a direct subprocess and handle SIGHUP.
    //
    // 4. Write child PID to pid_path.
    //
    // 5. Print confirmation message.

    std.debug.print("TODO: daemon start not yet implemented\n", .{});
}

/// Read PID from .mirror.pid, send SIGTERM, wait briefly, remove PID file.
fn runDaemonStop(allocator: Allocator) !void {
    const cwd_path = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd_path);

    const config_path = try findConfigFile(allocator, cwd_path);
    defer allocator.free(config_path);

    const output_directory = fs.path.dirname(config_path) orelse {
        std.debug.print("Error: cannot determine output directory from config path.\n", .{});
        return;
    };

    const pid_path = try fs.path.join(allocator, &.{ output_directory, pid_filename });
    defer allocator.free(pid_path);

    const pid_file = fs.openFileAbsolute(pid_path, .{}) catch {
        std.debug.print("No PID file found. Daemon is not running.\n", .{});
        return;
    };
    defer pid_file.close();

    var buffer: [32]u8 = undefined;
    const bytes_read = try pid_file.readAll(&buffer);
    const pid_string = mem.trim(u8, buffer[0..bytes_read], &std.ascii.whitespace);
    const pid = std.fmt.parseInt(posix.pid_t, pid_string, 10) catch {
        std.debug.print("Invalid PID in {s}\n", .{pid_path});
        return;
    };

    // Send SIGTERM
    posix.kill(pid, posix.SIG.TERM) catch |err| {
        if (err == error.ProcessNotFound) {
            std.debug.print("Process {d} not found. Removing stale PID file.\n", .{pid});
        } else {
            std.debug.print("Failed to send SIGTERM to {d}: {}\n", .{ pid, err });
        }
    };

    // Remove PID file
    fs.deleteFileAbsolute(pid_path) catch {};

    std.debug.print("Daemon stopped (PID {d}).\n", .{pid});
}

// ---------------------------------------------------------------------------
// Config I/O
// ---------------------------------------------------------------------------

fn readConfig(allocator: Allocator, path: []const u8) !json.Parsed(Config) {
    const file = try fs.openFileAbsolute(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return try json.parseFromSlice(Config, allocator, content, .{
        .allocate = .alloc_always,
    });
}

fn writeConfig(config: Config, path: []const u8, allocator: Allocator) !void {
    const file = try fs.createFileAbsolute(path, .{});
    defer file.close();

    var output: std.io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try json.Stringify.value(config, .{ .whitespace = .indent_2 }, &output.writer);

    const written = output.written();
    try file.writeAll(written);
}

/// Walk upward from start_path looking for a directory containing .mirror.json.
/// Returns absolute path to the config file.
fn findConfigFile(allocator: Allocator, start_path: []const u8) ![]const u8 {
    // For now, look in the CWD's immediate subdirectories for one containing .mirror.json
    var directory = try fs.openDirAbsolute(start_path, .{ .iterate = true });
    defer directory.close();

    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;

        const candidate = try fs.path.join(allocator, &.{ start_path, entry.name, config_filename });

        if (fs.accessAbsolute(candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }

    // Fallback: check CWD itself
    const direct = try fs.path.join(allocator, &.{ start_path, config_filename });
    if (fs.accessAbsolute(direct, .{})) |_| {
        return direct;
    } else |_| {
        allocator.free(direct);
    }

    return error.ConfigNotFound;
}

// ---------------------------------------------------------------------------
// Sync operations
// ---------------------------------------------------------------------------

/// Check whether any component of `path` matches a name in `skip_names`.
fn pathContainsSkipComponent(path: []const u8, skip_names: []const []const u8) bool {
    var remaining = path;
    while (remaining.len > 0) {
        const separator_index = mem.indexOfScalar(u8, remaining, '/');
        const component = if (separator_index) |index| remaining[0..index] else remaining;
        for (skip_names) |skip| {
            if (mem.eql(u8, component, skip)) return true;
        }
        remaining = if (separator_index) |index| remaining[index + 1 ..] else &.{};
    }
    return false;
}

/// Walk the given source directories under root, collecting relative paths to
/// all .md files that pass gitignore and include/exclude filters.
/// `output_directory_name` is the basename of the output directory to skip
/// during walking (avoids recursing into the symlink output).
fn scanMarkdownFiles(
    allocator: Allocator,
    root: []const u8,
    directories: []const []const u8,
    gitignore_rules: *GitignoreRules,
    include_patterns: []const []const u8,
    exclude_patterns: []const []const u8,
    output_directory_name: []const u8,
) ![]const []const u8 {
    var results: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (results.items) |path| allocator.free(path);
        results.deinit(allocator);
    }

    // Track visited real paths to detect symlink cycles
    var visited_paths: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var key_iterator = visited_paths.keyIterator();
        while (key_iterator.next()) |key| allocator.free(key.*);
        visited_paths.deinit(allocator);
    }

    // Load root .gitignore first
    try gitignore_rules.load(root);

    const skip_names: []const []const u8 = &.{ ".git", output_directory_name };

    for (directories) |directory_name| {
        // Skip the output directory itself and .git at the top level
        if (mem.eql(u8, directory_name, output_directory_name)) continue;
        if (mem.eql(u8, directory_name, ".git")) continue;

        const directory_path = try fs.path.join(allocator, &.{ root, directory_name });
        defer allocator.free(directory_path);

        try gitignore_rules.load(directory_path);

        // Record the real path of the source directory itself for cycle detection
        const source_real_path = fs.realpathAlloc(allocator, directory_path) catch continue;
        const gop = try visited_paths.getOrPut(allocator, source_real_path);
        if (gop.found_existing) {
            allocator.free(source_real_path);
            continue;
        }
        gop.value_ptr.* = {};

        var walker = fs.openDirAbsolute(directory_path, .{ .iterate = true }) catch continue;
        defer walker.close();

        var walk_iterator = try walker.walk(allocator);
        defer walk_iterator.deinit();

        while (try walk_iterator.next()) |entry| {
            // Skip entries whose path traverses a directory we want to avoid
            if (pathContainsSkipComponent(entry.path, skip_names)) continue;

            // For directories (including symlinked ones), check for cycles
            if (entry.kind == .directory or entry.kind == .sym_link) {
                if (entry.kind == .sym_link) {
                    // Resolve the symlink to check if it's a directory we should track
                    const entry_full_path = try fs.path.join(allocator, &.{ directory_path, entry.path });
                    defer allocator.free(entry_full_path);

                    const real_path = fs.realpathAlloc(allocator, entry_full_path) catch continue;
                    const cycle_gop = try visited_paths.getOrPut(allocator, real_path);
                    if (cycle_gop.found_existing) {
                        allocator.free(real_path);
                        continue; // Cycle detected, skip
                    }
                    cycle_gop.value_ptr.* = {};
                }
            }

            if (entry.kind != .file) continue;

            // Only .md files
            if (!mem.endsWith(u8, entry.path, ".md")) continue;

            // Build relative path from project root: directory_name/subpath
            const relative_path = try fs.path.join(allocator, &.{ directory_name, entry.path });

            // Apply gitignore
            if (gitignore_rules.isIgnored(relative_path)) {
                allocator.free(relative_path);
                continue;
            }

            // Apply include filter: if include patterns are specified, file must match at least one
            if (include_patterns.len > 0) {
                var matched = false;
                for (include_patterns) |pattern| {
                    if (matchGlob(pattern, relative_path)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) {
                    allocator.free(relative_path);
                    continue;
                }
            }

            // Apply exclude filter: if file matches any exclude pattern, skip it
            var excluded = false;
            for (exclude_patterns) |pattern| {
                if (matchGlob(pattern, relative_path)) {
                    excluded = true;
                    break;
                }
            }
            if (excluded) {
                allocator.free(relative_path);
                continue;
            }

            try results.append(allocator, relative_path);
        }
    }

    return try results.toOwnedSlice(allocator);
}

/// Create a symlink in output_dir pointing to the source file. Preserves
/// directory structure. Returns true if a new symlink was created.
fn createSymlink(
    source_root: []const u8,
    output_directory: []const u8,
    relative_path: []const u8,
    allocator: Allocator,
) !bool {
    // Absolute path to the real file
    const source_absolute = try fs.path.join(allocator, &.{ source_root, relative_path });
    defer allocator.free(source_absolute);

    // Path where symlink will live in output directory
    const link_path = try fs.path.join(allocator, &.{ output_directory, relative_path });
    defer allocator.free(link_path);

    // Ensure parent directories exist
    if (fs.path.dirname(link_path)) |parent| {
        try makeDirRecursive(parent);
    }

    // Check if symlink already exists and points to the right place
    var link_buffer: [fs.max_path_bytes]u8 = undefined;
    if (fs.readLinkAbsolute(link_path, &link_buffer)) |existing_target| {
        if (mem.eql(u8, existing_target, source_absolute)) {
            return false; // Already correct
        }
        // Wrong target, remove and recreate
        try fs.deleteFileAbsolute(link_path);
    } else |_| {}

    posix.symlink(source_absolute, link_path) catch |err| {
        if (err == error.PathAlreadyExists) {
            try fs.deleteFileAbsolute(link_path);
            try posix.symlink(source_absolute, link_path);
        } else return err;
    };

    return true;
}

fn makeDirRecursive(path: []const u8) !void {
    fs.makeDirAbsolute(path) catch |err| {
        if (err == error.PathAlreadyExists) return;
        if (err == error.FileNotFound) {
            if (fs.path.dirname(path)) |parent| {
                try makeDirRecursive(parent);
                try fs.makeDirAbsolute(path);
                return;
            }
        }
        return err;
    };
}

/// Walk the output directory, remove symlinks whose targets no longer exist.
/// Returns the count of removed symlinks.
fn removeStaleSymlinks(allocator: Allocator, output_directory: []const u8) !usize {
    var removed_count: usize = 0;

    var directory = fs.openDirAbsolute(output_directory, .{ .iterate = true }) catch return 0;
    defer directory.close();

    var walker = try directory.walk(allocator);
    defer walker.deinit();

    // Collect paths to remove (can't modify while iterating)
    var paths_to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths_to_remove.items) |path| allocator.free(path);
        paths_to_remove.deinit(allocator);
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .sym_link) continue;

        const full_path = try fs.path.join(allocator, &.{ output_directory, entry.path });

        // Check if the symlink target exists
        fs.accessAbsolute(full_path, .{}) catch {
            // Target doesn't exist or is broken — mark for removal
            try paths_to_remove.append(allocator, full_path);
            continue;
        };

        allocator.free(full_path);
    }

    for (paths_to_remove.items) |path| {
        fs.deleteFileAbsolute(path) catch continue;
        removed_count += 1;
    }

    return removed_count;
}

/// Remove empty directories under the given path, bottom-up.
fn removeEmptyDirectories(directory_path: []const u8) !void {
    // TODO: Walk directory tree bottom-up and remove any empty directories.
    // Be careful not to remove the output directory root itself.
    // Use fs.openDirAbsolute with iterate, check if directory is empty,
    // and call fs.deleteDirAbsolute if so. Repeat until no more empty
    // directories are found.
    _ = directory_path;
}

// ---------------------------------------------------------------------------
// CoreServices / FSEvents type definitions
// Adapted from std/Build/Watch/FsEvents.zig for use with DynLib
// ---------------------------------------------------------------------------

const dispatch_time_t = enum(u64) {
    now = 0,
    forever = std.math.maxInt(u64),
    _,
};
extern fn dispatch_time(base: dispatch_time_t, delta_ns: i64) dispatch_time_t;

const dispatch_semaphore_t = *opaque {};
extern fn dispatch_semaphore_create(value: isize) dispatch_semaphore_t;
extern fn dispatch_semaphore_wait(dsema: dispatch_semaphore_t, timeout: dispatch_time_t) isize;
extern fn dispatch_semaphore_signal(dsema: dispatch_semaphore_t) isize;

const dispatch_queue_t = *opaque {};
const dispatch_queue_attr_t = ?*opaque {
    const SERIAL: dispatch_queue_attr_t = null;
};
extern fn dispatch_queue_create(label: [*:0]const u8, attr: dispatch_queue_attr_t) dispatch_queue_t;
extern fn dispatch_release(object: *anyopaque) void;

const CFAllocatorRef = ?*const opaque {};
const CFArrayRef = *const opaque {};
const CFStringRef = *const opaque {};
const CFTimeInterval = f64;
const CFIndex = i32;
const CFOptionFlags = enum(u32) { _ };

const CFAllocatorRetainCallBack = *const fn (info: ?*const anyopaque) callconv(.c) *const anyopaque;
const CFAllocatorReleaseCallBack = *const fn (info: ?*const anyopaque) callconv(.c) void;
const CFAllocatorCopyDescriptionCallBack = *const fn (info: ?*const anyopaque) callconv(.c) CFStringRef;
const CFAllocatorAllocateCallBack = *const fn (alloc_size: CFIndex, hint: CFOptionFlags, info: ?*const anyopaque) callconv(.c) ?*const anyopaque;
const CFAllocatorReallocateCallBack = *const fn (ptr: ?*anyopaque, new_size: CFIndex, hint: CFOptionFlags, info: ?*const anyopaque) callconv(.c) ?*const anyopaque;
const CFAllocatorDeallocateCallBack = *const fn (ptr: *anyopaque, info: ?*const anyopaque) callconv(.c) void;
const CFAllocatorPreferredSizeCallBack = *const fn (size: CFIndex, hint: CFOptionFlags, info: ?*const anyopaque) callconv(.c) CFIndex;

const CFAllocatorContext = extern struct {
    version: CFIndex,
    info: ?*anyopaque,
    retain: ?CFAllocatorRetainCallBack,
    release: ?CFAllocatorReleaseCallBack,
    copy_description: ?CFAllocatorCopyDescriptionCallBack,
    allocate: CFAllocatorAllocateCallBack,
    reallocate: ?CFAllocatorReallocateCallBack,
    deallocate: ?CFAllocatorDeallocateCallBack,
    preferred_size: ?CFAllocatorPreferredSizeCallBack,
};

const CFArrayCallBacks = opaque {};

const CFStringEncoding = enum(u32) {
    invalid_id = std.math.maxInt(u32),
    mac_roman = 0,
    windows_latin_1 = 0x500,
    iso_latin_1 = 0x201,
    next_step_latin = 0xB01,
    ascii = 0x600,
    unicode = 0x100,
    utf8 = 0x8000100,
    non_lossy_ascii = 0xBFF,
};

const FSEventStreamRef = *opaque {};
const ConstFSEventStreamRef = *const @typeInfo(FSEventStreamRef).pointer.child;

const FSEventStreamCallback = *const fn (
    stream: ConstFSEventStreamRef,
    client_callback_info: ?*anyopaque,
    num_events: usize,
    event_paths: *anyopaque,
    event_flags: [*]const FSEventStreamEventFlags,
    event_ids: [*]const FSEventStreamEventId,
) callconv(.c) void;

const FSEventStreamContext = extern struct {
    version: CFIndex,
    info: ?*anyopaque,
    retain: ?CFAllocatorRetainCallBack,
    release: ?CFAllocatorReleaseCallBack,
    copy_description: ?CFAllocatorCopyDescriptionCallBack,
};

const FSEventStreamEventId = enum(u64) {
    since_now = std.math.maxInt(u64),
    _,
};

const FSEventStreamCreateFlags = packed struct(u32) {
    use_cf_types: bool = false,
    no_defer: bool = false,
    watch_root: bool = false,
    ignore_self: bool = false,
    file_events: bool = false,
    _: u27 = 0,
};

const FSEventStreamEventFlags = packed struct(u32) {
    must_scan_sub_dirs: bool,
    user_dropped: bool,
    kernel_dropped: bool,
    event_ids_wrapped: bool,
    history_done: bool,
    root_changed: bool,
    mount: bool,
    unmount: bool,
    item_created: bool,
    item_removed: bool,
    item_inode_meta_mod: bool,
    item_renamed: bool,
    item_modified: bool,
    item_finder_info_mod: bool,
    item_change_owner: bool,
    item_xattr_mod: bool,
    item_is_file: bool,
    item_is_dir: bool,
    item_is_symlink: bool,
    _: u13 = 0,
};

/// Symbols resolved at runtime via DynLib from CoreServices framework.
const ResolvedSymbols = struct {
    FSEventStreamCreate: *const fn (
        allocator: CFAllocatorRef,
        callback: FSEventStreamCallback,
        ctx: ?*const FSEventStreamContext,
        paths_to_watch: CFArrayRef,
        since_when: FSEventStreamEventId,
        latency: CFTimeInterval,
        flags: FSEventStreamCreateFlags,
    ) callconv(.c) FSEventStreamRef,
    FSEventStreamSetDispatchQueue: *const fn (stream: FSEventStreamRef, queue: dispatch_queue_t) callconv(.c) void,
    FSEventStreamStart: *const fn (stream: FSEventStreamRef) callconv(.c) bool,
    FSEventStreamStop: *const fn (stream: FSEventStreamRef) callconv(.c) void,
    FSEventStreamInvalidate: *const fn (stream: FSEventStreamRef) callconv(.c) void,
    FSEventStreamRelease: *const fn (stream: FSEventStreamRef) callconv(.c) void,
    FSEventStreamGetLatestEventId: *const fn (stream: ConstFSEventStreamRef) callconv(.c) FSEventStreamEventId,
    FSEventsGetCurrentEventId: *const fn () callconv(.c) FSEventStreamEventId,
    CFRelease: *const fn (cf: *const anyopaque) callconv(.c) void,
    CFArrayCreate: *const fn (
        allocator: CFAllocatorRef,
        values: [*]const usize,
        num_values: CFIndex,
        call_backs: ?*const CFArrayCallBacks,
    ) callconv(.c) CFArrayRef,
    CFStringCreateWithCString: *const fn (
        alloc: CFAllocatorRef,
        c_str: [*:0]const u8,
        encoding: CFStringEncoding,
    ) callconv(.c) CFStringRef,
    CFAllocatorCreate: *const fn (allocator: CFAllocatorRef, context: *const CFAllocatorContext) callconv(.c) CFAllocatorRef,
    kCFAllocatorUseContext: *const CFAllocatorRef,
};

fn loadCoreServices() !struct { lib: std.DynLib, symbols: ResolvedSymbols } {
    var core_services = std.DynLib.open("/System/Library/Frameworks/CoreServices.framework/CoreServices") catch
        return error.OpenFrameworkFailed;
    errdefer core_services.close();

    var resolved: ResolvedSymbols = undefined;
    inline for (@typeInfo(ResolvedSymbols).@"struct".fields) |field| {
        @field(resolved, field.name) = core_services.lookup(field.type, field.name) orelse
            return error.MissingCoreServicesSymbol;
    }

    return .{ .lib = core_services, .symbols = resolved };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "matchGlob" {
    // Basename matching
    try std.testing.expect(matchGlob("*.md", "foo.md"));
    try std.testing.expect(matchGlob("*.md", "README.md"));
    try std.testing.expect(!matchGlob("*.md", "foo.txt"));
    try std.testing.expect(!matchGlob("*.md", "dir/foo.md")); // '*' doesn't cross '/'

    // '?' matches single char
    try std.testing.expect(matchGlob("?.md", "a.md"));
    try std.testing.expect(!matchGlob("?.md", "ab.md"));

    // '**' matches across directories
    try std.testing.expect(matchGlob("**/*.md", "dir/foo.md"));
    try std.testing.expect(matchGlob("**/*.md", "a/b/c.md"));
    try std.testing.expect(matchGlob("**/node_modules", "src/node_modules"));
    try std.testing.expect(matchGlob("**/node_modules", "node_modules"));

    // Exact match
    try std.testing.expect(matchGlob("node_modules", "node_modules"));
    try std.testing.expect(!matchGlob("node_modules", "node_modules2"));

    // Directory patterns
    try std.testing.expect(matchGlob("dist/*", "dist/foo"));
    try std.testing.expect(!matchGlob("dist/*", "dist/sub/foo"));
}

test "config round-trip" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const config_path = try fs.path.join(allocator, &.{ tmp_path, config_filename });
    defer allocator.free(config_path);

    const original = Config{
        .root = "/Users/test/Code/work",
        .directories = &.{ "src", "docs" },
    };

    try writeConfig(original, config_path, allocator);

    const parsed_loaded = try readConfig(allocator, config_path);
    defer parsed_loaded.deinit();
    const loaded = parsed_loaded.value;

    try std.testing.expectEqualStrings("/Users/test/Code/work", loaded.root);
    try std.testing.expectEqual(@as(usize, 2), loaded.directories.len);
    try std.testing.expectEqualStrings("src", loaded.directories[0]);
    try std.testing.expectEqualStrings("docs", loaded.directories[1]);
}

test "config round-trip with include and exclude" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const config_path = try fs.path.join(allocator, &.{ tmp_path, config_filename });
    defer allocator.free(config_path);

    const original = Config{
        .root = "/Users/test/projects",
        .directories = &.{"project_a"},
        .include = &.{"dist/generated/**/*.md"},
        .exclude = &.{"**/CHANGELOG.md"},
    };

    try writeConfig(original, config_path, allocator);

    const parsed_loaded = try readConfig(allocator, config_path);
    defer parsed_loaded.deinit();
    const loaded = parsed_loaded.value;

    try std.testing.expectEqualStrings("/Users/test/projects", loaded.root);
    try std.testing.expectEqual(@as(usize, 1), loaded.directories.len);
    try std.testing.expectEqualStrings("project_a", loaded.directories[0]);
    try std.testing.expectEqual(@as(usize, 1), loaded.include.len);
    try std.testing.expectEqualStrings("dist/generated/**/*.md", loaded.include[0]);
    try std.testing.expectEqual(@as(usize, 1), loaded.exclude.len);
    try std.testing.expectEqualStrings("**/CHANGELOG.md", loaded.exclude[0]);
}

test "sync creates symlinks for md files" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create source directories and files
    try tmp_dir.dir.makePath("project_a");
    try tmp_dir.dir.makePath("project_b/docs");
    try tmp_dir.dir.makePath("_output");

    // Create source files
    {
        var f = try tmp_dir.dir.createFile("project_a/README.md", .{});
        defer f.close();
        try f.writeAll("# Project A");
    }
    {
        var f = try tmp_dir.dir.createFile("project_a/code.zig", .{});
        defer f.close();
        try f.writeAll("const std = @import(\"std\");");
    }
    {
        var f = try tmp_dir.dir.createFile("project_b/docs/guide.md", .{});
        defer f.close();
        try f.writeAll("# Guide");
    }

    // Write config
    const config_path = try fs.path.join(allocator, &.{ tmp_path, "_output", config_filename });
    defer allocator.free(config_path);

    const output_directory = try fs.path.join(allocator, &.{ tmp_path, "_output" });
    defer allocator.free(output_directory);

    const config = Config{
        .root = tmp_path,
        .directories = &.{ "project_a", "project_b" },
    };
    try writeConfig(config, config_path, allocator);

    // Run sync
    try runSyncWithConfig(allocator, config, output_directory);

    // Assert: _output/project_a/README.md exists and is a symlink
    var link_buffer: [fs.max_path_bytes]u8 = undefined;
    const readme_link_path = try fs.path.join(allocator, &.{ tmp_path, "_output", "project_a", "README.md" });
    defer allocator.free(readme_link_path);
    const readme_target = fs.readLinkAbsolute(readme_link_path, &link_buffer) catch |err| {
        std.debug.print("Expected symlink at {s}, got error: {}\n", .{ readme_link_path, err });
        return err;
    };
    const expected_readme_target = try fs.path.join(allocator, &.{ tmp_path, "project_a", "README.md" });
    defer allocator.free(expected_readme_target);
    try std.testing.expectEqualStrings(expected_readme_target, readme_target);

    // Assert: _output/project_b/docs/guide.md exists as symlink
    const guide_link_path = try fs.path.join(allocator, &.{ tmp_path, "_output", "project_b", "docs", "guide.md" });
    defer allocator.free(guide_link_path);
    _ = fs.readLinkAbsolute(guide_link_path, &link_buffer) catch |err| {
        std.debug.print("Expected symlink at {s}, got error: {}\n", .{ guide_link_path, err });
        return err;
    };

    // Assert: no symlink for code.zig (not .md)
    const code_link_path = try fs.path.join(allocator, &.{ tmp_path, "_output", "project_a", "code.zig" });
    defer allocator.free(code_link_path);
    if (fs.readLinkAbsolute(code_link_path, &link_buffer)) |_| {
        return error.TestUnexpectedResult; // Should not exist
    } else |_| {}
}

test "sync removes stale symlinks" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create output directory with a stale symlink
    try tmp_dir.dir.makePath("_output/old");

    const stale_link_path = try fs.path.join(allocator, &.{ tmp_path, "_output", "old", "stale.md" });
    defer allocator.free(stale_link_path);

    // Create symlink pointing to a nonexistent file
    posix.symlink("/nonexistent/path/file.md", stale_link_path) catch |err| {
        std.debug.print("Failed to create test symlink: {}\n", .{err});
        return err;
    };

    // Verify symlink exists before removal
    {
        var verify_buffer: [fs.max_path_bytes]u8 = undefined;
        _ = fs.readLinkAbsolute(stale_link_path, &verify_buffer) catch {
            return error.TestUnexpectedResult; // Symlink should exist
        };
    }

    const output_dir_path = try fs.path.join(allocator, &.{ tmp_path, "_output" });
    defer allocator.free(output_dir_path);

    const removed_count = try removeStaleSymlinks(allocator, output_dir_path);
    try std.testing.expectEqual(@as(usize, 1), removed_count);

    // Verify symlink was removed
    var link_buffer: [fs.max_path_bytes]u8 = undefined;
    if (fs.readLinkAbsolute(stale_link_path, &link_buffer)) |_| {
        return error.TestUnexpectedResult; // Symlink should be gone
    } else |_| {}
}

test "sync is idempotent" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create source directories and files
    try tmp_dir.dir.makePath("project_a");
    try tmp_dir.dir.makePath("project_b/docs");
    try tmp_dir.dir.makePath("_output");

    {
        var f = try tmp_dir.dir.createFile("project_a/README.md", .{});
        defer f.close();
        try f.writeAll("# Project A");
    }
    {
        var f = try tmp_dir.dir.createFile("project_b/docs/guide.md", .{});
        defer f.close();
        try f.writeAll("# Guide");
    }

    const output_directory = try fs.path.join(allocator, &.{ tmp_path, "_output" });
    defer allocator.free(output_directory);

    const config = Config{
        .root = tmp_path,
        .directories = &.{ "project_a", "project_b" },
    };

    // First sync
    try runSyncWithConfig(allocator, config, output_directory);

    // Second sync: scan to count what would be created
    var gitignore_rules = GitignoreRules.init(allocator);
    defer gitignore_rules.deinit();

    const markdown_files = try scanMarkdownFiles(
        allocator,
        tmp_path,
        config.directories,
        &gitignore_rules,
        config.include,
        config.exclude,
        "_output",
    );
    defer {
        for (markdown_files) |path| allocator.free(path);
        allocator.free(markdown_files);
    }

    var created_count: usize = 0;
    for (markdown_files) |relative_path| {
        const did_create = try createSymlink(tmp_path, output_directory, relative_path, allocator);
        if (did_create) created_count += 1;
    }

    // Second call should create 0 new symlinks
    try std.testing.expectEqual(@as(usize, 0), created_count);
}

test "scanner skips output directory" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create directories
    try tmp_dir.dir.makePath("project");
    try tmp_dir.dir.makePath("_output");

    // Create .md file inside output dir (should not be found)
    {
        var f = try tmp_dir.dir.createFile("_output/should_not_find.md", .{});
        defer f.close();
        try f.writeAll("# Should not find");
    }
    // Create .md file inside project dir (should be found)
    {
        var f = try tmp_dir.dir.createFile("project/found.md", .{});
        defer f.close();
        try f.writeAll("# Found");
    }

    var gitignore_rules = GitignoreRules.init(allocator);
    defer gitignore_rules.deinit();

    // Scan with both directories listed, but _output should be skipped
    const markdown_files = try scanMarkdownFiles(
        allocator,
        tmp_path,
        &.{ "project", "_output" },
        &gitignore_rules,
        &.{},
        &.{},
        "_output",
    );
    defer {
        for (markdown_files) |path| allocator.free(path);
        allocator.free(markdown_files);
    }

    // Only project/found.md should be found
    try std.testing.expectEqual(@as(usize, 1), markdown_files.len);
    try std.testing.expectEqualStrings("project/found.md", markdown_files[0]);
}

test "symlink cycle protection" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create a project directory with a .md file
    try tmp_dir.dir.makePath("project");
    {
        var f = try tmp_dir.dir.createFile("project/readme.md", .{});
        defer f.close();
        try f.writeAll("# Readme");
    }

    // Create a symlink inside project/ pointing back to the tmp dir root (cycle)
    const cycle_link_path = try fs.path.join(allocator, &.{ tmp_path, "project", "cycle_back" });
    defer allocator.free(cycle_link_path);
    posix.symlink(tmp_path, cycle_link_path) catch |err| {
        std.debug.print("Failed to create cycle symlink: {}\n", .{err});
        return err;
    };

    var gitignore_rules = GitignoreRules.init(allocator);
    defer gitignore_rules.deinit();

    // This should complete without infinite loop thanks to cycle detection
    const markdown_files = try scanMarkdownFiles(
        allocator,
        tmp_path,
        &.{"project"},
        &gitignore_rules,
        &.{},
        &.{},
        "_output",
    );
    defer {
        for (markdown_files) |path| allocator.free(path);
        allocator.free(markdown_files);
    }

    // Should find the readme.md but not infinitely recurse
    try std.testing.expectEqual(@as(usize, 1), markdown_files.len);
    try std.testing.expectEqualStrings("project/readme.md", markdown_files[0]);
}
