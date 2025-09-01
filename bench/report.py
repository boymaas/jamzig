#!/usr/bin/env python3
"""Simple benchmark visualization script using only standard library"""

import json
import os
import sys
from datetime import datetime
from pathlib import Path

BENCH_DIR = "bench"

def ns_to_ms(ns_value):
    """Convert nanoseconds to milliseconds"""
    try:
        return float(ns_value) / 1_000_000
    except (ValueError, TypeError):
        return 0.0

def extract_trace_data(data, trace_name, metric):
    """Extract trace data from JSON"""
    for result in data.get('results', []):
        if result.get('trace_name') == trace_name:
            return result.get(metric, 0)
    return 0

def generate_report():
    """Generate benchmark report"""
    print("=== JamZig Benchmark Performance Report ===")
    print()
    
    bench_path = Path(BENCH_DIR)
    if not bench_path.exists():
        print(f"Error: {BENCH_DIR} directory not found")
        print("Run benchmarks first with: zig build bench-block-import")
        return
    
    json_files = sorted(bench_path.glob("*.json"))
    
    if not json_files:
        print(f"No JSON files found in {BENCH_DIR}/")
        return
    
    print(f"Found {len(json_files)} benchmark file(s)")
    print()
    
    file_data = []
    
    # Process each file
    for file_path in json_files:
        print(f"Processing: {file_path.name}", file=sys.stderr)
        
        try:
            with open(file_path) as f:
                data = json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            print(f"Error reading {file_path}: {e}", file=sys.stderr)
            continue
        
        # Extract metadata
        timestamp = data.get('timestamp', 0)
        git_commit = data.get('git_commit', 'unknown')
        params = data.get('params', 'unknown')
        
        # Convert timestamp to date
        date_str = "unknown"
        if timestamp and timestamp != "null":
            try:
                date_str = datetime.fromtimestamp(int(timestamp)).strftime('%Y-%m-%d %H:%M:%S')
            except (ValueError, OSError):
                date_str = "unknown"
        
        print(f"Benchmark: {file_path.name}")
        print(f"  Date: {date_str}")
        print(f"  Git Commit: {git_commit}")
        print(f"  Parameters: {params}")
        print()
        
        # Extract unique trace names
        trace_names = sorted(set(result.get('trace_name', '') for result in data.get('results', [])))
        
        print("  Performance Results:")
        print(f"  {'Trace':<15} {'Min(ms)':>10} {'Median(ms)':>10} {'Mean(ms)':>10} {'Max(ms)':>10}")
        print("  " + "-" * 70)
        
        for trace in trace_names:
            if not trace:
                continue
                
            min_ns = extract_trace_data(data, trace, "min_ns")
            median_ns = extract_trace_data(data, trace, "median_ns")
            mean_ns = extract_trace_data(data, trace, "mean_ns")
            max_ns = extract_trace_data(data, trace, "max_ns")
            
            min_ms = ns_to_ms(min_ns)
            median_ms = ns_to_ms(median_ns)
            mean_ms = ns_to_ms(mean_ns)
            max_ms = ns_to_ms(max_ns)
            
            print(f"  {trace:<15} {min_ms:>10.2f} {median_ms:>10.2f} {mean_ms:>10.2f} {max_ms:>10.2f}")
        
        print()
        print()
        
        file_data.append((file_path, data))
    
    # Generate summary comparison if multiple files
    if len(file_data) > 1:
        print("=== Performance Trends ===")
        print()
        
        first_file, first_data = file_data[0]
        last_file, last_data = file_data[-1]
        
        first_timestamp = first_data.get('timestamp', 0)
        last_timestamp = last_data.get('timestamp', 0)
        
        first_date = "unknown"
        last_date = "unknown"
        
        try:
            if first_timestamp:
                first_date = datetime.fromtimestamp(int(first_timestamp)).strftime('%Y-%m-%d')
            if last_timestamp:
                last_date = datetime.fromtimestamp(int(last_timestamp)).strftime('%Y-%m-%d')
        except (ValueError, OSError):
            pass
        
        print(f"Comparison between {first_date} and {last_date}:")
        print()
        
        # Get trace names from last file
        trace_names = sorted(set(result.get('trace_name', '') for result in last_data.get('results', [])))
        
        print(f"{'Trace':<15} {'First(ms)':>12} {'Latest(ms)':>12} {'Change%':>10}")
        print("-" * 55)
        
        for trace in trace_names:
            if not trace:
                continue
                
            first_median = extract_trace_data(first_data, trace, "median_ns")
            last_median = extract_trace_data(last_data, trace, "median_ns")
            
            if first_median and last_median:
                first_ms = ns_to_ms(first_median)
                last_ms = ns_to_ms(last_median)
                
                # Calculate percentage change
                try:
                    change_pct = ((last_median - first_median) / first_median) * 100
                    change_str = f"{change_pct:.1f}%"
                except ZeroDivisionError:
                    change_str = "N/A"
                
                print(f"{trace:<15} {first_ms:>12.2f} {last_ms:>12.2f} {change_str:>10}")
        
        print()

if __name__ == "__main__":
    generate_report()