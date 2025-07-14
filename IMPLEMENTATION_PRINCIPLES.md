# JamZig Implementation Principles

This document outlines the core implementation principles, coding conventions, and design patterns used throughout the JamZig codebase.

## Core Philosophy

### Memory Management Strategy

The fundamental principle is **caller-controlled memory ownership**. This means:

1. **No Hidden Allocations**: Functions that add data to collections or aggregates NEVER perform `dupe` or `memcpy` internally
2. **Explicit Ownership Transfer**: The caller decides whether to:
   - Move ownership (pass data directly)
   - Keep ownership (explicitly `dupe` at call site)
3. **Transparent Memory Operations**: All allocations are visible at the call site

Example:
```zig
// BAD: Hidden allocation
pub fn addItem(self: *Collection, item: []const u8) !void {
    const copy = try self.allocator.dupe(u8, item); // Hidden!
    try self.items.append(copy);
}

// GOOD: Caller controls ownership
pub fn addItem(self: *Collection, item: []const u8) !void {
    try self.items.append(item); // Caller decides if item needs duping
}

// Usage:
collection.addItem(owned_string); // Move ownership
collection.addItem(try allocator.dupe(u8, borrowed_string)); // Explicit copy
```

## Naming Conventions

### Functions
- **Format**: `camelCase`
- **Examples**: `processBlock`, `validateTransaction`, `buildNextEpoch`
- **Prefixes**:
  - `init`/`deinit`: Stack-based initialization/cleanup
  - `create`/`destroy`: Heap allocation/deallocation
  - `build`: Constructing complex objects
  - `process`: Transforming data
  - `validate`: Checking correctness

### Types and Structs
- **Format**: `PascalCase`
- **Examples**: `JamState`, `WorkReport`, `ServiceAccount`
- **Abbreviations**: Keep uppercase (`PVM`, `STF`, `RNG`)
- **Generic Types**: Descriptive names like `Deserialized(T)`, `Connection(T)`

### Constants
- **Format**: `SCREAMING_SNAKE_CASE`
- **Examples**: `MAX_GAS_LIMIT`, `B_S`, `B_I`, `FUZZ_PARAMS`
- **Organization**: Group at module top

### Variables
- **Format**: `snake_case`
- **Examples**: `work_report`, `gas_remaining`, `peer_endpoint`
- **Special Cases**:
  - Allocators: Always named `allocator`
  - Iteration variables: Short names (`i`, `idx`)
  - Temporary variables: Descriptive but concise

### Error Types
- **Format**: `PascalCase` for enum values
- **Examples**: `OutOfGas`, `InvalidSignature`, `StateMismatch`

## Memory Management Patterns

### Mandatory Cleanup Methods
**Every struct that holds owned memory MUST implement an appropriate `deinit` or `destroy` method.** This is non-negotiable for memory safety.

```zig
pub const MyStruct = struct {
    allocator: Allocator,
    owned_data: []u8,        // Owned memory
    owned_list: ArrayList(Item), // Contains owned memory
    
    // REQUIRED: deinit method to free all owned memory
    pub fn deinit(self: *MyStruct) void {
        self.allocator.free(self.owned_data);
        self.owned_list.deinit();
        self.* = undefined; // Catch use-after-free
    }
};
```

### Create/Destroy Pattern
For heap-allocated objects, prefer `create`/`destroy` over `init`/`deinit`:

```zig
pub fn create(allocator: std.mem.Allocator, params: Params) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    
    self.* = .{
        .field = try initField(allocator, params),
        // ...
    };
    errdefer self.deinit(allocator);
    
    return self;
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.deinit(allocator);
    allocator.destroy(self);
}
```

### Arena Allocator Usage
For temporary operations with many allocations:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const temp_allocator = arena.allocator();
// Use temp_allocator for all temporary allocations
```

### Deep Clone Pattern
When copying complex structures:

```zig
pub fn deepClone(self: @This(), allocator: std.mem.Allocator) !@This() {
    return @This(){
        .simple_field = self.simple_field,
        .owned_slice = try allocator.dupe(T, self.owned_slice),
        .optional_slice = if (self.optional_slice) |s|
            try allocator.dupe(T, s)
        else
            null,
    };
}
```

## Code Organization

### File Structure Template
```zig
//! Module documentation

const std = @import("std");

// External imports (sorted)
const external = @import("external");

// Internal imports (sorted)
const types = @import("../types.zig");
const utils = @import("../utils.zig");

// Type aliases
const Allocator = std.mem.Allocator;

// Module constants
pub const CONSTANT = 42;

// Tracing setup
const trace = @import("../tracing.zig").scoped(.module_name);

// Main implementation
pub const MainType = struct {
    // Fields first
    allocator: Allocator,
    data: []u8,
    
    // Lifecycle methods
    pub fn init(allocator: Allocator) !Self { }
    pub fn deinit(self: *Self) void { }
    
    // Core functionality
    pub fn process(self: *Self) !void { }
    
    // Helper methods (private)
    fn helper(self: Self) void { }
};

// Tests at bottom
test "module: specific test" { }
```

### Import Organization Rules
1. Standard library first
2. External dependencies (alphabetically)
3. Internal imports (by dependency depth)
4. Type aliases
5. Constants
6. Tracing setup

## Error Handling

### Error Union Usage
```zig
// Explicit error types
pub const ProcessError = error{
    InvalidInput,
    ResourceExhausted,
    StateCorrupted,
};

// Function signatures
pub fn process() ProcessError!Result { }

// Error handling with context
const result = operation() catch |err| {
    const span = trace.span(.error_handler);
    defer span.deinit();
    span.err("Operation failed: {s}", .{@errorName(err)});
    return err;
};
```

### Cleanup Patterns
```zig
// Basic cleanup
var resource = try Resource.init(allocator);
defer resource.deinit();

// Error cleanup
var resource = try Resource.init(allocator);
errdefer resource.deinit();
try resource.riskyOperation();
// resource.deinit() only called on error after this point
```

### Deinit Safety Pattern
Always set the object to undefined after cleanup to catch use-after-free bugs:

```zig
pub fn deinit(self: *Self) void {
    // Clean up owned resources
    self.allocator.free(self.data);
    if (self.optional_data) |data| {
        self.allocator.free(data);
    }
    
    // IMPORTANT: Set to undefined to catch use-after-free
    self.* = undefined;
}
```

This pattern helps debug builds catch use-after-free errors by making any access to deinitialized objects immediately obvious.

## Zig-Specific Patterns

### Comptime Type Generation
```zig
pub fn StateType(comptime params: Params) type {
    return struct {
        const capacity = params.max_size;
        data: [capacity]u8,
    };
}
```

### Generic Functions
```zig
pub fn serialize(
    comptime T: type,
    writer: anytype,
    value: T,
) @TypeOf(writer).Error!void {
    // Implementation
}
```

### Optional Handling
```zig
// Pattern matching
if (optional_value) |value| {
    // Use value
} else {
    // Handle null
}

// With capture
const result = optional orelse return error.NotFound;
```

## Testing Principles

### Test Naming
Test names should use lowercase with underscores (snake_case) for better readability:
```zig
test "decode_work_report_with_invalid_signature" {
    // Test implementation
}

test "state_transition_empty_block" {
    // Test implementation
}

test "pvm_fuzzer_memory_allocation" {
    // Test implementation
}
```

### Test Organization
- Unit tests in same file as implementation
- Integration tests in separate test files
- Test vectors in `jamtestvectors/`
- Fuzz tests in dedicated fuzzing modules

## Documentation

### Function Documentation
```zig
/// Processes the work report according to graypaper (§5.3).
/// Returns error.InvalidSignature if verification fails.
pub fn processWorkReport(report: WorkReport) !void {
    // Implementation
}
```

### Graypaper References
Always include section references:
```zig
// (§4.2) Block production rules
// (eq. 251) State transition function
```

## Performance Considerations

### Allocation Strategies
1. Prefer stack allocation when size is known
2. Use arena allocators for batch operations
3. Reuse buffers where possible
4. Clear ownership boundaries to prevent leaks

### Data Structure Choices
- `ArrayList` for dynamic arrays
- `HashMap` with appropriate context
- `StaticBitSet` for fixed-size bit operations
- Custom structures for domain-specific needs

## Debugging and Tracing

### Tracing Levels
```zig
span.debug("High-level operation info");
span.trace("Detailed execution flow");
span.info("Important state changes");
span.err("Error conditions with context");
```

### Trace Scoping
```zig
pub fn complexOperation() !void {
    const span = trace.span(.complex_operation);
    defer span.deinit();
    
    span.debug("Starting with {} items", .{count});
    // Operation logic
}
```

## Concurrency Patterns

### Thread Safety
- Immutable by default
- Explicit mutexes for shared state
- Message passing preferred over shared memory
- Clear ownership boundaries between threads

## Version Control Practices

### Commit Style
- Atomic commits (one logical change)
- Descriptive messages
- Reference issues/PRs when applicable
- Include test updates with implementation

This document represents the collective coding wisdom embedded in the JamZig codebase and should be followed to maintain consistency and quality.