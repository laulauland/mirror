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
    patterns: std.ArrayListUnmanaged([]const u8) = .empty,
    allocator: Allocator,

    fn init(allocator: Allocator) GitignoreRules {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *GitignoreRules) void {
        self.patterns.deinit(self.allocator);
    }

    /// Load .gitignore from the given directory path. Silently succeeds if no
    /// .gitignore exists.
    fn load(self: *GitignoreRules, directory_path: []const u8) !void {
        // TODO: Open directory_path/.gitignore, parse each non-comment non-empty
        // line as a pattern, append to self.patterns. Handle negation patterns
        // (lines starting with '!') and directory-only patterns (trailing '/').
        _ = self;
        _ = directory_path;
    }

    fn isIgnored(self: *const GitignoreRules, relative_path: []const u8) bool {
        // TODO: Check relative_path against all loaded patterns.
        // Return true if the path matches any non-negated pattern.
        _ = self;
        _ = relative_path;
        return false;
    }
};

// ---------------------------------------------------------------------------
// Glob matching
// ---------------------------------------------------------------------------

/// Match a glob pattern against a path. Supports '*' (any chars except '/'),
/// '**' (any chars including '/'), and '?' (single char).
fn matchGlob(pattern: []const u8, path: []const u8) bool {
    // TODO: Implement glob matching with support for:
    //   '*'  — matches any sequence of non-'/' characters
    //   '**' — matches any sequence of characters including '/'
    //   '?'  — matches exactly one character
    // Use a two-pointer or recursive approach.
    _ = pattern;
    _ = path;
    return false;
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
        \\  init    Interactive setup — pick output dir and source directories
        \\  sync    One-shot scan: create/remove symlinks based on config
        \\  watch   Foreground FSEvents watcher (both directions)
        \\  up      Start watcher as a background daemon
        \\  down    Stop the background daemon
        \\  help    Show this message
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

    // TODO: Interactive TUI for directory selection.
    // Switch terminal to raw mode via posix.tcgetattr / posix.tcsetattr.
    // Display numbered list with [x]/[ ] checkboxes.
    // Handle key input: arrow up/down to move cursor, space to toggle, enter to confirm.
    // Use ANSI escape codes for cursor movement and clearing lines.
    // For now, select all directories as a placeholder.
    const selected = try allocator.alloc(bool, directory_entries.items.len);
    defer allocator.free(selected);
    @memset(selected, true);

    std.debug.print("Directories to mirror (all selected by default):\n", .{});
    for (directory_entries.items, 0..) |entry, index| {
        const marker: u8 = if (selected[index]) 'x' else ' ';
        std.debug.print("  [{c}] {s}\n", .{ marker, entry.name });
    }

    // TODO: Prompt for output directory name (default: _notes).
    // Read a line from stdin, trim whitespace, use default if empty.
    const output_directory = "_notes";

    // Build config
    var selected_directories: std.ArrayListUnmanaged([]const u8) = .empty;
    defer selected_directories.deinit(allocator);
    for (directory_entries.items, 0..) |entry, index| {
        if (selected[index]) {
            try selected_directories.append(allocator, entry.name);
        }
    }

    const config = Config{
        .root = output_directory,
        .directories = selected_directories.items,
    };

    // Create output directory if it doesn't exist
    fs.makeDirAbsolute(try fs.path.join(allocator, &.{ cwd_path, output_directory })) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write config
    const config_path = try fs.path.join(allocator, &.{ cwd_path, output_directory, config_filename });
    defer allocator.free(config_path);
    try writeConfig(config, config_path, allocator);

    std.debug.print("\nConfig written to {s}/{s}\n", .{ output_directory, config_filename });

    // Run initial sync
    try runSyncWithConfig(allocator, config, cwd_path);

    std.debug.print("Initial sync complete.\n", .{});
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

    try runSyncWithConfig(allocator, config, cwd_path);
}

fn runSyncWithConfig(allocator: Allocator, config: Config, cwd_path: []const u8) !void {
    const output_directory = try fs.path.join(allocator, &.{ cwd_path, config.root });
    defer allocator.free(output_directory);

    // Phase 1: Scan source directories and create symlinks for .md files
    var gitignore_rules = GitignoreRules.init(allocator);
    defer gitignore_rules.deinit();

    const markdown_files = try scanMarkdownFiles(
        allocator,
        cwd_path,
        config.directories,
        &gitignore_rules,
        config.include,
        config.exclude,
        config.root,
    );
    defer {
        for (markdown_files) |path| allocator.free(path);
        allocator.free(markdown_files);
    }

    var created_count: usize = 0;
    for (markdown_files) |relative_path| {
        const did_create = try createSymlink(cwd_path, output_directory, relative_path, allocator);
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

    // Initial sync before starting watch
    try runSyncWithConfig(allocator, config, cwd_path);

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
    const config = parsed_config.value;

    const pid_path = try fs.path.join(allocator, &.{ cwd_path, config.root, pid_filename });
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

    const parsed_config = try readConfig(allocator, config_path);
    defer parsed_config.deinit();
    const config = parsed_config.value;

    const pid_path = try fs.path.join(allocator, &.{ cwd_path, config.root, pid_filename });
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

test "matchGlob placeholder" {
    // TODO: Add tests once matchGlob is implemented
    try std.testing.expect(!matchGlob("*.md", "foo.md"));
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
        .root = "_notes",
        .directories = &.{ "src", "docs" },
    };

    try writeConfig(original, config_path, allocator);

    const parsed_loaded = try readConfig(allocator, config_path);
    defer parsed_loaded.deinit();
    const loaded = parsed_loaded.value;

    try std.testing.expectEqualStrings("_notes", loaded.root);
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
        .root = "_output",
        .directories = &.{"project_a"},
        .include = &.{"dist/generated/**/*.md"},
        .exclude = &.{"**/CHANGELOG.md"},
    };

    try writeConfig(original, config_path, allocator);

    const parsed_loaded = try readConfig(allocator, config_path);
    defer parsed_loaded.deinit();
    const loaded = parsed_loaded.value;

    try std.testing.expectEqualStrings("_output", loaded.root);
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

    const config = Config{
        .root = "_output",
        .directories = &.{ "project_a", "project_b" },
    };
    try writeConfig(config, config_path, allocator);

    // Run sync
    try runSyncWithConfig(allocator, config, tmp_path);

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

    const config = Config{
        .root = "_output",
        .directories = &.{ "project_a", "project_b" },
    };

    // First sync
    try runSyncWithConfig(allocator, config, tmp_path);

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
        config.root,
    );
    defer {
        for (markdown_files) |path| allocator.free(path);
        allocator.free(markdown_files);
    }

    const output_directory = try fs.path.join(allocator, &.{ tmp_path, config.root });
    defer allocator.free(output_directory);

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
