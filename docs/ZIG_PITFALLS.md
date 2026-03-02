# Zig Pitfalls

Patterns to avoid and patterns to use when working on mirror.

## Patterns to AVOID

### Missing `errdefer` on partial init

The #1 Zig bug. If a function does multiple allocations and a later one fails, earlier allocations leak.

```zig
// BAD: if items alloc fails, name leaks
const name = try allocator.dupe(u8, input);
const items = try allocator.alloc(Item, 16);

// GOOD:
const name = try allocator.dupe(u8, input);
errdefer allocator.free(name);
const items = try allocator.alloc(Item, 16);
```

Rule: every `try alloc` except the last needs `errdefer free`.

### Returning slices to stack-local data

Dangling pointer. Zig won't warn you. The slice looks valid until the stack frame is reused.

### ArrayList when arena suffices

ArrayLists need explicit `deinit`. For ephemeral data within a command lifecycle, use arena allocation instead. The arena frees everything at once.

### Ignoring DebugAllocator's `deinit()` return

```zig
// BAD:
gpa.deinit();

// GOOD:
if (gpa.detectLeaks()) std.process.exit(1);
```

### `@intCast` without bounds in ReleaseFast

Safety checks are disabled in ReleaseFast. Always build CI with ReleaseSafe.

### Holding pointers into ArrayList across appends

`append` may realloc, invalidating all pointers. Copy the data or use indices instead.

### Mixing allocators

Allocating with one allocator, freeing with another is undefined behavior. Store the allocator alongside the data when ownership transfers.

### Comptime overuse

Error messages from deeply nested comptime types are terrible. Use runtime dispatch (tagged unions) for anything varying by user input. Reserve comptime for genuinely static things.

## Patterns to USE

### Arena per command

One arena per CLI invocation. All ephemeral allocations use it. One `deinit()` frees everything.

### Explicit error sets

Use explicit error sets over `anyerror` in public APIs. Callers can switch on specific errors.

### `defer` immediately after resource acquisition

```zig
const file = try std.fs.cwd().openFile(path, .{});
defer file.close();
```

## CI / Linting

| Check | How |
|---|---|
| Memory leaks | DebugAllocator in all tests |
| Unused variables/params | Compiler error (Zig enforces) |
| Format | `zig fmt --check` in CI |
| Undefined behavior | Build + test in `Debug` mode |
| Dead code | Build in `ReleaseSafe` |
