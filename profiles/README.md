# JamZig Tracy Profiling

This directory contains Tracy profiling captures and related documentation for JamZig performance analysis.

## Directory Structure

```
profiles/
├── README.md           # This file
└── captures/           # Tracy capture files (.tracy)
```

## Quick Start

### 1. Capture Tracy Data

Use the automated script to capture profiling data:

```bash
# Default: 10 iterations, all traces
./scripts/tracy-profile.sh

# Custom: 50 iterations, only safrole trace  
./scripts/tracy-profile.sh 50 safrole

# Custom: 100 iterations, fallback trace
./scripts/tracy-profile.sh 100 fallback
```

Available trace filters: `fallback`, `safrole`, `preimages`, `preimages_light`, `storage`, `storage_light`

### 2. Analyze with Tracy GUI

Open the captured data in Tracy profiler:

```bash
# Open specific capture
tracy-profiler profiles/captures/jamzig-safrole-20250107-104532.tracy

# Or use the GUI File -> Open menu
tracy-profiler
```

## What You'll See in Tracy

### Timeline Views
- **Zones**: All STF transition steps and block import operations
- **Threads**: Worker pool activity and thread naming
- **Frames**: Each block processed appears as one frame
- **Memory**: Allocation tracking (if TracyAllocator is used)

### Key Profiling Zones
- `stf_state_transition` - Overall STF execution
- `stf_accumulate_transition` - Core block accumulation (usually the hottest path)
- `stf_disputes_transition` - Dispute processing
- `stf_assurances_transition` - Assurance validation
- `stf_reports_transition` - Work report processing
- `stf_safrole_transition` - BABE consensus updates
- `block_import_with_root` - Complete block import process

### Performance Analysis Tips

1. **Find Bottlenecks**: Look for the longest zones in the timeline
2. **Thread Utilization**: Check if worker threads are being used effectively
3. **Frame Consistency**: Look for consistent block processing times
4. **Memory Patterns**: If memory tracking is enabled, look for allocation hotspots
5. **Zone Hierarchy**: Use the statistics view to see call counts and timing

## Capture File Management

- Capture files are timestamped automatically
- Files can be large (10MB-1GB+ depending on benchmark duration)
- Files are excluded from git via .gitignore
- Clean up old captures periodically to save disk space

## Troubleshooting

### Tracy-capture not starting
- Check if port 8086 is available: `netstat -ln | grep 8086`
- Try a different port in the script if needed

### No connection from benchmark
- Ensure JamZig was built with `-Denable-tracy=true`
- Check if tracy-capture is still running during benchmark execution

### Large capture files
- Reduce benchmark iterations
- Disable memory tracking if not needed
- Use specific trace filters instead of all traces