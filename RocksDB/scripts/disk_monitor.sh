#!/bin/bash

########################################
# Disk / NVMe Usage Monitoring Script
#
# Usage examples:
#   1) Normal mode (df -h) + auto filename:
#      ./monitor_disk.sh
#
#   2) Normal mode + custom output file:
#      ./monitor_disk.sh disk.log
#
#   3) TORFS mode (nvme list + grep nvmeX):
#      ./monitor_disk.sh torfs-mode=1 n=1 torfs_nvme1.log
#      ./monitor_disk.sh torfs-mode=1 namespace=3
#      (If no output file is given, it will be auto-generated)
#
# Notes:
#   - When torfs-mode=1, you must provide n=NUMBER or namespace=NUMBER
#   - The first non-option argument is treated as OUTPUT_FILE
########################################

# ===== Default configuration =====
MOUNT_POINT="/mnt/test/"
INTERVAL=120               # 5 minutes
DURATION=$((48 * 3600))     # 48 hours
COUNT=$((DURATION / INTERVAL))

TORFS_MODE=0
NS_NUM=""
OUTPUT_FILE=""

# ===== Parse command-line arguments =====
for arg in "$@"; do
    case "$arg" in
        torfs-mode=1)
            TORFS_MODE=1
            ;;
        torfs-mode=0)
            TORFS_MODE=0
            ;;
        n=*|namespace=*)
            NS_NUM="${arg#*=}"
            ;;
        *)
            # The first non-config argument is treated as output filename
            if [ -z "$OUTPUT_FILE" ]; then
                OUTPUT_FILE="$arg"
            fi
            ;;
    esac
done

# If no output file is specified, generate one automatically
if [ -z "$OUTPUT_FILE" ]; then
    if [ "$TORFS_MODE" -eq 1 ] && [ -n "$NS_NUM" ]; then
        OUTPUT_FILE="torfs_nvme${NS_NUM}_$(date +%Y%m%d_%H%M%S).log"
    else
        OUTPUT_FILE="disk_usage_$(date +%Y%m%d_%H%M%S).log"
    fi
fi

# TORFS mode requires namespace/n parameter
if [ "$TORFS_MODE" -eq 1 ] && [ -z "$NS_NUM" ]; then
    echo "Error: torfs-mode=1 requires n=NUMBER or namespace=NUMBER"
    exit 1
fi

# ===== Startup information =====
echo "Starting monitoring..."
echo "Mode: $([ "$TORFS_MODE" -eq 1 ] && echo "TORFS (nvme list)" || echo "Normal (df -h)")"
if [ "$TORFS_MODE" -eq 1 ]; then
    echo "Target NVMe: nvme${NS_NUM}"
else
    echo "Mount point: $MOUNT_POINT"
fi
echo "Output file: $OUTPUT_FILE"
echo "Interval: $INTERVAL sec (≈ $((INTERVAL / 60)) min)"
echo "Total duration: $((DURATION / 3600)) hours"
echo "Expected iterations: $COUNT"
echo "----------------------------------------"

# ===== Write header to log =====
{
    echo "Monitoring Log"
    if [ "$TORFS_MODE" -eq 1 ]; then
        echo "Mode: TORFS (sudo nvme list | grep nvme${NS_NUM})"
    else
        echo "Mode: df -h"
        echo "Mount point: $MOUNT_POINT"
    fi
    echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo
} > "$OUTPUT_FILE"

# ===== Main loop =====
for i in $(seq 1 "$COUNT"); do
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$i/$COUNT] $ts" >> "$OUTPUT_FILE"

    if [ "$TORFS_MODE" -eq 1 ]; then
        # Record only the line containing nvme${NS_NUM}
        sudo nvme list | grep "nvme${NS_NUM}" >> "$OUTPUT_FILE"
    else
        df -h "$MOUNT_POINT" >> "$OUTPUT_FILE"
    fi

    echo >> "$OUTPUT_FILE"

    if [ "$i" -lt "$COUNT" ]; then
        sleep "$INTERVAL"
    fi
done

# ===== Write footer to log =====
{
    echo "========================================"
    echo "End time: $(date '+%Y-%m-%d %H:%M:%S')"
} >> "$OUTPUT_FILE"

echo "Monitoring complete! Log saved to $OUTPUT_FILE"