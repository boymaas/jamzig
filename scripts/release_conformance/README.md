# JAM Conformance Test Release

This release contains the JAM conformance testing binaries for validating protocol implementations.

## Release Information

- **Release:** `${RELEASE_NAME}`
- **Git SHA:** `${GIT_SHA}`
- **Build Date:** `${BUILD_DATE}`

## Contents

This release includes binaries for two parameter sets:

- **`tiny/`** - Built with TINY_PARAMS for quick testing and development
- **`full/`** - Built with FULL_PARAMS for production conformance testing

Each parameter set includes binaries for:
- Linux x86_64
- Linux aarch64
- macOS aarch64

## Running Conformance Tests

### Quick Start

From this directory, run:

```bash
./run_conformance_test.sh
```

This will automatically:
1. Detect your platform
2. Start the conformance target server
3. Run the fuzzer against it
4. Generate a conformance report

### Manual Execution

You can also run the components separately:

1. **Start the target server:**
   ```bash
   # For tiny params on Linux x86_64
   ./tiny/linux/x86_64/jam_conformance_target --socket /tmp/jam_conformance.sock

   # For full params on macOS aarch64
   ./full/macos/aarch64/jam_conformance_target --socket /tmp/jam_conformance.sock
   ```

2. **Run the fuzzer:**
   ```bash
   # Basic run with 100 blocks
   ./tiny/linux/x86_64/jam_conformance_fuzzer --socket /tmp/jam_conformance.sock --blocks 100

   # With specific seed for reproducible testing
   ./full/macos/aarch64/jam_conformance_fuzzer --socket /tmp/jam_conformance.sock --seed 12345 --blocks 500

   # Save report to file
   ./tiny/linux/x86_64/jam_conformance_fuzzer --socket /tmp/jam_conformance.sock --output report.json
   ```

### Command Line Options

**Target Server Options:**
- `--socket <path>` - Unix socket path (default: /tmp/jam_conformance.sock)
- `--port <number>` - TCP port for network mode (optional)
- `--verbose` - Enable verbose logging
- `--trace-scope <scope>` - Enable tracing for specific scopes

**Fuzzer Options:**
- `--socket <path>` - Unix socket path to connect to
- `--seed <number>` - Random seed for deterministic execution
- `--blocks <number>` - Number of blocks to process (default: 100)
- `--output <file>` - Output report file (JSON format)
- `--verbose` - Enable verbose output

## Parameter Sets

The protocol parameters for each set are available in:
- `tiny/params.json` - Parameters used for tiny builds
- `full/params.json` - Parameters used for full builds

These files contain all JAM protocol constants with their graypaper symbols (e.g., "E" for epoch_length, "C" for core_count).

## Platform Detection

The `run_conformance_test.sh` script automatically detects your platform. If you're in a platform-specific directory (e.g., `linux/x86_64/`), it will use the binaries in that directory.

## Troubleshooting

1. **Permission Denied:**
   ```bash
   chmod +x jam_conformance_fuzzer jam_conformance_target run_conformance_test.sh
   ```

2. **Socket Already in Use:**
   ```bash
   rm -f /tmp/jam_conformance.sock
   ```

3. **Trace Output:**
   Enable detailed tracing with:
   ```bash
   JAM_CONFORMANCE_TARGET_TRACE=fuzz_protocol=debug ./jam_conformance_target --socket /tmp/jam_conformance.sock
   ```

## Conformance Report

The fuzzer generates a JSON report containing:
- Test configuration (seed, blocks processed)
- State root comparisons at each block
- Any protocol violations detected
- Performance metrics

Example report structure:
```json
{
  "version": "1.0",
  "test_config": {
    "seed": 12345,
    "blocks": 100,
    "params_type": "tiny"
  },
  "results": {
    "blocks_processed": 100,
    "state_mismatches": 0,
    "protocol_violations": []
  }
}
```

## Support

For issues or questions about the conformance test suite, please contact the JAM team or file an issue in the repository.