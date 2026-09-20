#!/usr/bin/env bash
# ioping-exporter.sh - A Prometheus textfile collector for ioping
#
# Description:
# Runs ioping continuously against a target directory, parsing its output
# to maintain a Prometheus histogram of I/O latency.
#
# Usage:
#   INTERVAL=1 WRITE_EVERY=10 PROM_FILE=/var/lib/prometheus/node-exporter/ioping.prom ./ioping-exporter.sh /mnt/target
#
# Paul Reece <paulreece42@gmail.com> 2026-09-19
#
# Created by prompting Gemini to "think like a statician", then "think like a storage expert"
#

set -euo pipefail

# Configuration with defaults
TARGET_DIR="${1:-.}"
PROM_FILE="${PROM_FILE:-ioping.prom}"
INTERVAL="${INTERVAL:-1}"
WRITE_EVERY="${WRITE_EVERY:-10}"
IOPING_BIN="${IOPING_BIN:-ioping}"

# Storage Expert defaults: 
# -G: Read-write ping-pong mode (alternates reads and writes)
# -D: Direct I/O (bypass read page cache) - Linux only!
# -Y: Sync I/O (bypass write cache and force commit)
# (Remove -D if on macOS or an unsupported filesystem like ZFS/BTRFS sometimes)
IOPING_OPTS="${IOPING_OPTS:--G -D -Y}"

if ! command -v "$IOPING_BIN" &> /dev/null; then
    echo "Error: $IOPING_BIN not found in PATH" >&2
    exit 1
fi

echo "Starting ioping Prometheus exporter..."
echo "Target directory: $TARGET_DIR"
echo "Prometheus file: $PROM_FILE"
echo "Ping interval: $INTERVAL seconds"
echo "Write interval: every $WRITE_EVERY pings"
echo "ioping options: $IOPING_OPTS"

# Start ioping continuously and parse its output line-by-line using awk.
exec "$IOPING_BIN" $IOPING_OPTS -i "$INTERVAL" "$TARGET_DIR" | awk -v outfile="$PROM_FILE" -v write_every="$WRITE_EVERY" -v target="$TARGET_DIR" '
BEGIN {
    # Initialize high-resolution histogram buckets (in seconds)
    # Optimized for network-attached storage (Ceph RBD, NFS over Ethernet)
    # Granular resolution in the 1ms to 500ms range where network storage fluctuates,
    # and upper bounds extending to 60s for severe NFS stalls.
    bucket_str = "0.00025 0.0005 0.00075 0.001 0.0015 0.002 0.003 0.004 0.005 0.0075 0.01 0.015 0.02 0.03 0.04 0.05 0.075 0.1 0.15 0.2 0.3 0.4 0.5 0.75 1 2 5 10 30 60 +Inf"
    num_buckets = split(bucket_str, buckets, " ")
    
    ops[1] = "read"
    ops[2] = "write"
    
    for (o in ops) {
        op = ops[o]
        sum[op] = 0
        total_count[op] = 0
        for (i = 1; i <= num_buckets; i++) {
            counts[op, buckets[i]] = 0
        }
    }
    lines = 0
}

# Match lines containing "time=" which indicates a successful ping
/time=/ {
    # Determine operation type from the ioping direction arrows
    op = "unknown"
    for(i=1; i<=NF; i++) {
        if ($i == "<<<") op = "read"
        else if ($i == ">>>") op = "write"
    }
    
    val = -1
    for(i=1; i<=NF; i++) {
        if ($i ~ /^time=/) {
            split($i, a, "=")
            val = a[2]
            unit = $(i+1)
            
            # Normalize to seconds
            if (unit == "ms") val = val / 1000.0
            else if (unit == "us") val = val / 1000000.0
            else if (unit == "ns") val = val / 1000000000.0
            else if (unit == "s") val = val * 1.0
            else if (unit == "min") val = val * 60.0
            else val = val / 1.0
        }
    }
    
    if (val >= 0 && op != "unknown") {
        sum[op] += val
        total_count[op]++
        
        # Update histogram buckets (cumulative)
        for (i = 1; i <= num_buckets; i++) {
            if (buckets[i] == "+Inf" || val <= (buckets[i] + 0.0)) {
                counts[op, buckets[i]]++
            }
        }
    }
    
    lines++
    if (lines >= write_every) {
        tmpfile = outfile ".tmp"
        
        # Write to temporary file first for atomic replacement
        printf "# HELP ioping_latency_seconds Histogram of ioping latency\n" > tmpfile
        printf "# TYPE ioping_latency_seconds histogram\n" > tmpfile
        
        for (o in ops) {
            op = ops[o]
            for (i = 1; i <= num_buckets; i++) {
                printf "ioping_latency_seconds_bucket{target=\"%s\",operation=\"%s\",le=\"%s\"} %d\n", target, op, buckets[i], counts[op, buckets[i]] > tmpfile
            }
            printf "ioping_latency_seconds_sum{target=\"%s\",operation=\"%s\"} %f\n", target, op, sum[op] > tmpfile
            printf "ioping_latency_seconds_count{target=\"%s\",operation=\"%s\"} %d\n", target, op, total_count[op] > tmpfile
        }
        
        # Freshness timestamp to detect hung I/O
        printf "# HELP ioping_last_update_seconds Unix timestamp of the last successful metric write\n" > tmpfile
        printf "# TYPE ioping_last_update_seconds gauge\n" > tmpfile
        
        # Use date command to get current epoch time since standard awk lacks systime()
        "date +%s" | getline current_time
        close("date +%s")
        printf "ioping_last_update_seconds{target=\"%s\"} %s\n", target, current_time > tmpfile
        
        close(tmpfile)
        
        # Atomically replace the target file
        system("mv " tmpfile " " outfile)
        
        lines = 0
    }
}
'
