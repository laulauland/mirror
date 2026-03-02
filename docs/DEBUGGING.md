# Debugging

Memory tools and debugging strategies for mirror, ordered by frequency of use.

## Tier 1: DebugAllocator (always)

In Debug builds detects: leaks (with stack traces), double-free, use-after-free, buffer overflows.

```zig
var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .init;
defer _ = gpa_instance.deinit();
const allocator = gpa_instance.allocator();
```

For tests: `std.testing.allocator` automatically fails on leak.

## Tier 2: LLDB (crashes)

Zig produces standard DWARF debug info. Debug builds have excellent stack traces already.

```bash
lldb ./zig-out/bin/mirror -- sync
```

## Tier 3: perf / Tracy (profiling)

Not needed initially. Zig has Tracy integration via `std.debug.trace`.
