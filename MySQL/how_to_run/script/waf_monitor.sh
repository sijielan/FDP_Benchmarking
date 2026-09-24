#!/bin/bash

# WAF Monitor Script
# Usage: ./waf_monitor.sh <device> [duration_hours] [interval_minutes] [output_csv]
# Example: ./waf_monitor.sh /dev/nvme5
# Example: ./waf_monitor.sh /dev/nvme5 48 10 /path/to/output.csv

# ── Arguments ────────────────────────────────────────────────────────────────
DEVICE="${1}"
DURATION_HOURS="${2:-48}"
INTERVAL_MINUTES="${3:-10}"
DEVICE_NAME=$(basename "$DEVICE")
LOG_FILE="${4:-waf_log_${DEVICE_NAME}_$(date +%Y%m%d_%H%M%S).csv}"

if [[ -z "$DEVICE" ]]; then
    echo "Usage: $0 <device> [duration_hours] [interval_minutes] [output_csv]" >&2
    echo "  device            e.g. /dev/nvme5" >&2
    echo "  duration_hours    default: 48" >&2
    echo "  interval_minutes  default: 10" >&2
    echo "  output_csv        default: waf_log_<device>_<timestamp>.csv" >&2
    exit 1
fi

TOTAL_INTERVALS=$(( DURATION_HOURS * 60 / INTERVAL_MINUTES ))
INTERVAL_SECONDS=$(( INTERVAL_MINUTES * 60 ))

# ── Helpers ───────────────────────────────────────────────────────────────────

get_host_write() {
    sudo nvme smart-log "$DEVICE" 2>/dev/null \
        | grep "Data Units Written" \
        | awk -F: '{print $2}' \
        | awk '{gsub(/,/, "", $1); print $1}'
}

get_nand_write() {
    sudo nvme ocp smart-add-log "$DEVICE" 2>/dev/null \
        | grep -a "Physical media units written" \
        | awk '{print $NF}'
}

to_gib_host() {
    awk "BEGIN { printf \"%.2f\", ($1 * 512000) / (1024^3) }"
}

to_gib_nand() {
    awk "BEGIN { printf \"%.2f\", $1 / (1024^3) }"
}

calc_waf() {
    local nand="$1"
    local host="$2"
    if [[ -z "$host" || "$host" -eq 0 ]]; then
        echo "N/A"
    else
        awk "BEGIN { printf \"%.4f\", $nand / ($host * 512000) }"
    fi
}

# ── Init ──────────────────────────────────────────────────────────────────────
echo "========================================" >&2
echo " WAF Monitor" >&2
echo " Device   : $DEVICE" >&2
echo " Duration : ${DURATION_HOURS}h  (${TOTAL_INTERVALS} samples)" >&2
echo " Interval : ${INTERVAL_MINUTES} min" >&2
echo " Log file : $LOG_FILE" >&2
echo "========================================" >&2

# CSV header → file only
echo "TIMESTAMP,ELAPSED_MIN,HOST_WRITE_RAW,NAND_WRITE_RAW,\
HOST_WRITE_INTERVAL_GiB,NAND_WRITE_INTERVAL_GiB,WAF_INTERVAL,\
HOST_WRITE_TOTAL_GiB,NAND_WRITE_TOTAL_GiB,WAF_FROM_BEGIN" \
    > "$LOG_FILE"

# Baseline (t=0)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Collecting baseline readings..." >&2
HOST0=$(get_host_write)
NAND0=$(get_nand_write)

if [[ -z "$HOST0" || -z "$NAND0" ]]; then
    echo "ERROR: Could not read from $DEVICE. Check device path and permissions." >&2
    exit 1
fi

echo "  Baseline host write  : $HOST0 units ($(to_gib_host $HOST0) GiB)" >&2
echo "  Baseline NAND write  : $NAND0 bytes ($(to_gib_nand $NAND0) GiB)" >&2
echo "" >&2

HOST_PREV=$HOST0
NAND_PREV=$NAND0

# ── Main loop ─────────────────────────────────────────────────────────────────
for (( i=1; i<=TOTAL_INTERVALS; i++ )); do

    sleep "$INTERVAL_SECONDS"

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    ELAPSED_MIN=$(( i * INTERVAL_MINUTES ))

    HOST_NOW=$(get_host_write)
    NAND_NOW=$(get_nand_write)

    if [[ -z "$HOST_NOW" || -z "$NAND_NOW" ]]; then
        echo "[$TIMESTAMP] WARNING: Failed to read counters, skipping sample $i" >&2
        continue
    fi

    # ── Interval deltas
    HOST_DELTA=$(( HOST_NOW - HOST_PREV ))
    NAND_DELTA=$(( NAND_NOW - NAND_PREV ))

    HOST_INTERVAL_GIB=$(to_gib_host $HOST_DELTA)
    NAND_INTERVAL_GIB=$(to_gib_nand $NAND_DELTA)
    WAF_INTERVAL=$(calc_waf $NAND_DELTA $HOST_DELTA)

    # ── Cumulative deltas (from begin)
    HOST_TOTAL=$(( HOST_NOW - HOST0 ))
    NAND_TOTAL=$(( NAND_NOW - NAND0 ))

    HOST_TOTAL_GIB=$(to_gib_host $HOST_TOTAL)
    NAND_TOTAL_GIB=$(to_gib_nand $NAND_TOTAL)
    WAF_FROM_BEGIN=$(calc_waf $NAND_TOTAL $HOST_TOTAL)

    # ── Print to terminal (stderr)
    echo "[$TIMESTAMP] +${ELAPSED_MIN} min  (sample $i / $TOTAL_INTERVALS)" >&2
    echo "  HOST_WRITE_INTERVAL  : ${HOST_INTERVAL_GIB} GiB" >&2
    echo "  NAND_WRITE_INTERVAL  : ${NAND_INTERVAL_GIB} GiB" >&2
    echo "  WAF_INTERVAL         : ${WAF_INTERVAL}" >&2
    echo "  HOST_WRITE_FROM_BEGIN: ${HOST_TOTAL_GIB} GiB" >&2
    echo "  NAND_WRITE_FROM_BEGIN: ${NAND_TOTAL_GIB} GiB" >&2
    echo "  WAF_FROM_BEGIN       : ${WAF_FROM_BEGIN}" >&2
    echo "" >&2

    # ── Append CSV row → file only
    echo "$TIMESTAMP,$ELAPSED_MIN,$HOST_NOW,$NAND_NOW,\
$HOST_INTERVAL_GIB,$NAND_INTERVAL_GIB,$WAF_INTERVAL,\
$HOST_TOTAL_GIB,$NAND_TOTAL_GIB,$WAF_FROM_BEGIN" \
        >> "$LOG_FILE"

    HOST_PREV=$HOST_NOW
    NAND_PREV=$NAND_NOW

done

echo "========================================" >&2
echo " Monitoring complete. Results saved to:" >&2
echo " $LOG_FILE" >&2
echo "========================================" >&2