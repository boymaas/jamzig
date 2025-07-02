#!/bin/bash

# JAM Conformance Test Runner
# This script orchestrates running the conformance test between fuzzer and target

set -e  # Exit on error

# Configuration
SOCKET_PATH="/tmp/jam_conformance.sock"
NUM_BLOCKS=100
SEED=""
OUTPUT_FILE=""
VERBOSE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--socket)
            SOCKET_PATH="$2"
            shift 2
            ;;
        -b|--blocks)
            NUM_BLOCKS="$2"
            shift 2
            ;;
        -S|--seed)
            SEED="--seed $2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="--output $2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE="--verbose"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  -s, --socket PATH    Unix socket path (default: /tmp/jam_conformance.sock)"
            echo "  -b, --blocks N       Number of blocks to process (default: 100)"
            echo "  -S, --seed N         Random seed for deterministic execution"
            echo "  -o, --output FILE    Output report file"
            echo "  -v, --verbose        Enable verbose output"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}JAM Conformance Test Runner${NC}"
echo "============================"
echo "Socket: $SOCKET_PATH"
echo "Blocks: $NUM_BLOCKS"
echo ""

# Check if executables exist
if [ ! -f "./zig-out/bin/jam_conformance_target" ]; then
    echo -e "${RED}Error: jam_conformance_target not found${NC}"
    echo "Please build the project first: zig build"
    exit 1
fi

if [ ! -f "./zig-out/bin/jam_conformance_fuzzer" ]; then
    echo -e "${RED}Error: jam_conformance_fuzzer not found${NC}"
    echo "Please build the project first: zig build"
    exit 1
fi

# Clean up any existing socket
rm -f "$SOCKET_PATH"

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "Cleaning up..."
    if [ ! -z "$TARGET_PID" ]; then
        kill $TARGET_PID 2>/dev/null || true
        wait $TARGET_PID 2>/dev/null || true
    fi
    rm -f "$SOCKET_PATH"
}

# Set up trap to cleanup on exit
trap cleanup EXIT INT TERM

# Start the target server in background
echo "Starting target server..."
./zig-out/bin/jam_conformance_target --trace "stf=trace,fuzz_protocol=trace,pvm=trace,accumulate=trace" --socket "$SOCKET_PATH" $VERBOSE &
TARGET_PID=$!

# Wait for target to be ready
echo "Waiting for target to be ready..."
for i in {1..50}; do
    if [ -S "$SOCKET_PATH" ]; then
        echo -e "${GREEN}Target server ready${NC}"
        break
    fi
    if ! kill -0 $TARGET_PID 2>/dev/null; then
        echo -e "${RED}Target server failed to start${NC}"
        exit 1
    fi
    sleep 0.1
done

if [ ! -S "$SOCKET_PATH" ]; then
    echo -e "${RED}Timeout waiting for target server${NC}"
    exit 1
fi

# Small additional delay to ensure server is fully ready
sleep 0.5

# Run the fuzzer
echo ""
echo "Running conformance fuzzer..."
echo "----------------------------"

./zig-out/bin/jam_conformance_fuzzer \
    --socket "$SOCKET_PATH" \
    --blocks "$NUM_BLOCKS" \
    $SEED \
    $OUTPUT_FILE \
    $VERBOSE

FUZZER_EXIT_CODE=$?

# Report results
echo ""
echo "----------------------------"
if [ $FUZZER_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Conformance test PASSED${NC}"
    exit 0
else
    echo -e "${RED}✗ Conformance test FAILED${NC}"
    exit $FUZZER_EXIT_CODE
fi
