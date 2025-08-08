# JamZig Style Guide

This document outlines the core implementation principles, coding conventions, and design patterns used throughout the JamZig codebase.

## Philosophy

This style guide combines JamZig's specific implementation principles with Zig's official naming conventions and community best practices. Remember that **Zig does not enforce these conventions** - the compiler and `zig fmt` allow any naming style. However, following these guidelines will make your code consistent with both the JamZig codebase and the broader Zig ecosystem.

> **Exception Rule**: These are general rules of thumb; if it makes sense to do something different, do what makes sense. For example, if there is an established convention such as `ENOENT`, follow the established convention.

## Core Philosophy

### Memory Management Strategy

The fundamental principle is **caller-controlled memory ownership**. This means:

1. **No Hidden Allocations**: Functions that add data to collections or aggregates NEVER perform `dupe` or `memcpy` internally
2. **References Never Transfer Ownership**: Functions returning `[]T`, `*T`, or `?[]T` never transfer ownership to the caller
3. **Explicit Ownership Transfer**: The caller decides whether to:
   - Move ownership (pass data directly)
   - Keep ownership (explicitly `dupe` at call site)
4. **Transparent Memory Operations**: All allocations are visible at the call site

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

## Core Naming Conventions

### Types (Structs, Unions, Enums, Errors)
- **Use TitleCase/PascalCase**
- **Abbreviations**: Keep uppercase (`PVM`, `STF`, `RNG`)
- **Generic Types**: Descriptive names like `Deserialized(T)`, `Connection(T)`
- Examples: `JamState`, `WorkReport`, `ServiceAccount`, `Point`, `Color`, `FileError`

```zig
const Point = struct { x: i32, y: i32 };
const Color = enum { red, green, blue };
const FileError = error { NotFound, AccessDenied };
const PVM = struct { ... }; // Abbreviations stay uppercase
```

### Functions
- **Use camelCase** for regular functions
- **Use TitleCase** for functions that return types
- **Prefixes**:
  - `init`/`deinit`: Stack-based initialization/cleanup
  - `create`/`destroy`: Heap allocation/deallocation
  - `build`: Constructing complex objects
  - `process`: Transforming data
  - `validate`: Checking correctness

```zig
// Regular functions - camelCase
fn calculateDistance(a: Point, b: Point) f64 { ... }
fn processBlock(block: Block) !void { ... }
fn validateTransaction(tx: Transaction) !void { ... }

// Type-returning functions - TitleCase
fn Point(comptime T: type) type { ... }
fn ArrayList(comptime T: type) type { ... }
fn StateType(comptime params: Params) type { ... }
```

### Variables and Parameters
- **Use snake_case** for regular variables
- **Use TitleCase** for variables that store types
- **Special Cases**:
  - Allocators: Always named `allocator`
  - Iteration variables: Short names (`i`, `idx`)
  - Temporary variables: Descriptive but concise

```zig
// Regular variables - snake_case
const max_connections = 100;
var user_name: []const u8 = "john";
var buffer: [1024]u8 = undefined;
var work_report: WorkReport = .{};
var gas_remaining: u64 = MAX_GAS_LIMIT;

// Type-storing variables - TitleCase
const IntPoint = Point(i32);
const StringList = std.ArrayList([]const u8);
const DefaultHashMap = std.HashMap([]const u8, i32);
```

### Constants
- **Format**: `SCREAMING_SNAKE_CASE` for module-level constants
- **Organization**: Group at module top
- Follow the same rules as variables based on what they contain:
  - **snake_case** for regular values (within structs)
  - **TitleCase** for types
  - **SCREAMING_SNAKE_CASE** for established conventions and module constants

```zig
// Module constants - SCREAMING_SNAKE_CASE
pub const MAX_GAS_LIMIT = 10_000_000;
pub const B_S = 1023; // Number of validators
pub const B_I = 16; // Items per segment
pub const FUZZ_PARAMS = .{ .iterations = 1000 };

// Within structs - snake_case for regular values
const Config = struct {
    const default_timeout = 30;
    const max_retries = 3;
};

// Type constants - TitleCase
const DefaultHashMap = std.HashMap([]const u8, i32);

// Established conventions - SCREAMING_SNAKE_CASE
const ENOENT = error.FileNotFound; // Following POSIX convention
```

### Error Types
- **Format**: `PascalCase` for error enum values
- **Organization**: Group related errors

```zig
pub const ProcessError = error{
    OutOfGas,
    InvalidSignature,
    StateMismatch,
    ResourceExhausted,
    StateCorrupted,
};

const NetworkError = error {
    ConnectionFailed,
    TimeoutExpired,
    InvalidResponse,
};
```

### Namespaces (Zero-field structs)
- **Use snake_case** for structs with 0 fields that are never instantiated

```zig
// Namespace - snake_case
const math_utils = struct {
    pub fn add(a: i32, b: i32) i32 { return a + b; }
    pub fn multiply(a: i32, b: i32) i32 { return a * b; }
};

const string_helpers = struct {
    pub fn trim(s: []const u8) []const u8 { ... }
    pub fn split(s: []const u8, delimiter: u8) [][]const u8 { ... }
};
```

### Files and Directories
- **Use snake_case** for file and directory names
- Exception: main entry files may follow project naming conventions

```
src/
├── main.zig
├── jam_state.zig
├── work_report.zig
├── service_account.zig
└── utils/
    ├── string_helpers.zig
    └── math_operations.zig
```

## Field and Method Naming

### Struct Fields
- **Use snake_case** for fields
- Exception: Error names are always TitleCase

```zig
const User = struct {
    first_name: []const u8,
    last_name: []const u8,
    age: u8,
    is_active: bool,
    service_account: ?ServiceAccount,
};

const WorkReport = struct {
    block_hash: Hash,
    validator_index: u16,
    gas_used: u64,
    state_root: Hash,
};
```

### Methods vs Functions
- **Methods** (functions that take `self`): camelCase
- **Associated functions** (constructors, etc.): camelCase or TitleCase if returning type

```zig
const List = struct {
    items: []Item,
    allocator: Allocator,
    
    // Constructor - camelCase
    pub fn init(allocator: Allocator) List { ... }
    
    // Methods - camelCase
    pub fn append(self: *List, item: Item) void { ... }
    pub fn contains(self: *const List, item: Item) bool { ... }
    pub fn deinit(self: *List) void { ... }
};
```

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

### Avoid Storing Derived Data
Never store data that can be computed from existing state. This principle reduces memory usage, simplifies cleanup, and follows the "no hidden allocations" philosophy:

```zig
// BAD: Storing derived/formatted data
pub const Context = struct {
    path: ArrayList(PathSegment),
    path_string: []u8,  // Derived from path - DON'T STORE!
    
    pub fn updatePath(self: *Context) !void {
        // Hidden allocation for derived data
        self.path_string = try self.formatPath(self.allocator);
    }
};

// GOOD: Generate derived data on-demand
pub const Context = struct {
    path: ArrayList(PathSegment),
    
    pub fn formatPath(self: *const Context, writer: anytype) !void {
        // Generate formatted path when needed
        for (self.path.items) |segment| {
            try writer.print("{}", .{segment});
        }
    }
};
```

Key principles:
- **Generate formatting strings on-demand** rather than storing them
- **Compute derived values when needed** instead of caching
- **Store only the essential state** from which other values can be derived
- This reduces allocations, simplifies memory management, and prevents data inconsistency

## Function Parameter Ordering

To maintain consistency and predictability across the codebase, follow this parameter ordering:

### Parameter Order (from first to last):

1. **Self parameter** (`self`, `*self`, `*const self`)
2. **Compile-time parameters** (`comptime` params)
   - Can use structs to group related compile-time parameters
   - Example: `comptime params: DecoderParams` instead of multiple individual parameters
3. **Allocator** (if needed)
   - Only include if the function needs an allocator for its own allocations
   - Do NOT include if the struct already has an allocator member
   - Do NOT include if using types that manage their own allocation (e.g., std.AutoArrayHashMap)
4. **Context objects** (e.g., `DecodingContext`, `EncodingContext`, `ValidationContext`)
   - Objects that provide context, error handling, or tracking throughout the operation
   - Usually passed as pointers to allow mutation
5. **State components** (in canonical order when dealing with blockchain state):
   - Alpha (α) - Authorizations
   - Beta (β) - Recent blocks
   - Gamma (γ) - Safrole state
   - Delta (δ) - Service accounts
   - Eta (η) - Entropy
   - Theta (θ) - Work reports ready
   - Iota (ι) - Validator keys
   - Kappa (κ) - Judgments
   - Lambda (λ) - Assurances
   - Xi (ξ) - Accumulated reports
   - Phi (φ) - Authorizer queue
   - Chi (χ) - Service privileges
   - Psi (ψ) - Preimage storage
   - Rho (ρ) - Pending reports
   - Tau (τ) - Time/timestamp
6. **Configuration objects** (e.g., `Config`, `Options`, `Settings`)
7. **Runtime parameters** (e.g., `validators_count`, `core_count` when not compile-time)
8. **Primary data to be processed** (e.g., `reports`, `transfers`, `blocks`)
9. **Secondary/derived parameters** (e.g., `gas_limit`, `slot_in_epoch`)
10. **Output parameters** (if any)
11. **Reader/Writer** (`reader: anytype`, `writer: anytype`)
    - Always comes last as the data source/sink
    - Consistent with Zig stdlib patterns

### Examples:

```zig
// GOOD: Following parameter order
pub fn processReports(
    self: *Self,
    allocator: std.mem.Allocator,
    context: *ProcessingContext,    // Context object
    xi: *state.Xi,                  // State component
    theta: *state.Theta,            // State component  
    reports: []WorkReport,          // Data to process
    gas_limit: u64,                 // Secondary parameter
) !Result { ... }

// GOOD: Decoder with grouped compile-time params
pub fn decode(
    comptime params: DecoderParams, // Grouped compile-time params
    allocator: std.mem.Allocator,
    context: *DecodingContext,      // Context for error tracking
    reader: anytype,                // Reader comes last
) !MyType { ... }

// GOOD: Function with runtime parameters
pub fn validate(
    allocator: std.mem.Allocator,
    context: *ValidationContext,    // Context object
    validator_count: u32,           // Runtime parameter
    data: []const u8,               // Primary data
    strict_mode: bool,              // Secondary parameter
) !ValidationResult { ... }

// BAD: Inconsistent ordering
pub fn processReports(
    self: *Self,
    reports: []WorkReport,          // Should come after state
    xi: *state.Xi,
    allocator: std.mem.Allocator,  // Should come earlier
    gas_limit: u64,
) !Result { ... }
```

### Rationale:
- **Predictability**: Developers know where to find parameters
- **Compile-time first**: Zig requires compile-time parameters to come first
- **Context early**: Context objects often needed throughout the operation for error handling
- **State-first**: Emphasizes state management in blockchain context
- **Data flow**: Parameters flow from context (state) to data to modifiers
- **Reader/Writer last**: Data sources/sinks come at the end, matching Zig stdlib patterns
- **Consistency**: Same ordering across all functions reduces cognitive load

## Formatting Rules

### Indentation
- **Use 4 spaces** (not tabs)
- Let `zig fmt` handle most formatting automatically

### Line Length
- No strict limit, but aim for readability
- Break long function signatures and calls across multiple lines when needed

## Language-Enforced Rules

### No Unused Variables
- Zig requires all variables to be used
- Use `_ = variable;` to explicitly mark as intentionally unused
- Use `_` as parameter name for intentionally unused parameters

```zig
fn processData(data: []const u8, _: bool) void {
    // Process data, ignore second parameter
    _ = data; // If not using data, mark as unused
}
```

### No Variable Shadowing
- Cannot use the same identifier name in nested scopes
- Choose distinct names instead of short, meaningless alternatives

```zig
// Bad - would cause compile error
fn read(stream: std.net.Stream) ![]const u8 {
    const read = try stream.read(&buf); // Error: shadows function name
}

// Good - use descriptive names
fn read(stream: std.net.Stream) ![]const u8 {
    const bytes_read = try stream.read(&buf);
}
```

## Anti-patterns to Avoid

### Avoid Vague Suffixes
Avoid these meaningless suffixes that don't clarify the class's purpose:

- **Manager** - What does it manage? How?
- **Handler** - Unless it specifically handles events/errors
- **Helper** - What kind of help?
- **Util/Utils** - Be more specific
- **Data** - Everything contains data
- **Info** - Be more specific about what information

### Better Alternatives

Instead of vague suffixes, use descriptive names:

```zig
// Bad
const ConnectionManager = struct { ... };
const FileHandler = struct { ... };
const StringHelper = struct { ... };

// Good
const ConnectionPool = struct { ... };
const FileReader = struct { ... };  // or FileWriter, FileParser
const StringFormatter = struct { ... };  // or StringValidator, StringConverter
```

### Common Descriptive Suffixes
When appropriate, use these more specific suffixes:

- **Builder** - Constructs instances step by step
- **Factory** - Creates instances
- **Reader/Writer** - Reads from/writes to something
- **Parser** - Parses data formats
- **Formatter** - Formats data for output
- **Validator** - Validates data
- **Container** - Holds collections of items
- **Registry** - Stores registered items
- **Repository** - Manages data storage/retrieval
- **Dispatcher** - Routes/dispatches events or messages

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

### Import Naming
- Imported modules follow namespace rules (snake_case)
- Standard library typically imported as `std`

```zig
const std = @import("std");
const json_parser = @import("json_parser.zig");
const http_client = @import("http_client.zig");
const work_report = @import("work_report.zig");
```

### Module Structure
- Keep related functionality together
- Use clear, descriptive module names
- Expose clean public APIs

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

### Zig-Specific API Patterns
- Follow these Zig-specific patterns:
  - Use `writeInt(type, value, .little)` instead of deprecated `writeIntLittle(type, value)`
  - For error logging, create inner spans: 
    ```zig
    const inner_span = trace.span(.handle_error);
    defer inner_span.deinit();
    inner_span.err("Error message: {s}", .{@errorName(err)});
    ```
  - Always use explicit format specifiers with `fmt.fmtSliceHexLower`:
    - Use `{s}` for string/slice output (e.g., `std.fmt.fmtSliceHexLower(&hash)`)
    - Use `{d}` for numeric output
    - Never use `{}` without a specifier

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
- Whenever you create a new test file add it to `@src/tests.zig` so it can be found when running `zig build test`
- Never make standalone tests, add the generated tests to `src/tests.zig` or if its a test of a subsystem the tests file of that subsystem like `src/repl/tests.zig`

## Documentation and Comments

### Doc Comments
- Use `///` for documentation comments
- Write in clear, concise English
- Document public APIs thoroughly
- **IMPORTANT**: DO NOT ADD ***ANY*** COMMENTS unless asked

```zig
/// Calculates the distance between two points using the Euclidean formula.
/// Returns the distance as a floating-point number.
pub fn calculateDistance(a: Point, b: Point) f64 {
    // Implementation...
}
```

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

## Final Notes

- **Consistency is key** - Pick a style and stick to it throughout your project
- **Readability trumps brevity** - Choose clear names over short ones
- **Context matters** - Consider how names will read at the call site
- **When in doubt, be explicit** - Zig values clarity over cleverness

Remember: these guidelines help create maintainable, readable code that integrates well with both the JamZig codebase and the broader Zig ecosystem, but the language gives you the freedom to adapt them to your specific needs.

This document represents the collective coding wisdom embedded in the JamZig codebase and should be followed to maintain consistency and quality.
