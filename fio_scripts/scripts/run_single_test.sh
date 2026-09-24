#!/bin/bash

# Example usage:
# ./run_single_test.sh -j ./fio_workloads/fdp/3.84t/16j_u_2h.fio
# ./run_single_test.sh -j ./fio_workloads/cns/7.52t/16j_u_2h.fio
#
# Device type (fdp/cns) is inferred automatically from the job file path.

# ======== Editable config =========
SYNC_WAIT_TIME=5        # seconds to wait after FIO before stopping monitors
MEASURE_INTERVAL=600    # measure_dev sampling interval (seconds)
# ==================================

if [[ -x "/usr/local/bin/fio" ]]; then
    FIO_BIN="/usr/local/bin/fio"
elif command -v fio &>/dev/null; then
    FIO_BIN=$(command -v fio)
else
    FIO_BIN="fio"
fi

log() {
    local level=$1; shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "${CURRENT_LOG_FILE:-/dev/stdout}"
}
log_info()  { log "INFO"  "$@"; }
log_error() { log "ERROR" "$@"; }

collect_fdp_stats() {
    local device=$1 endpoint=$2 output_file=$3
    local stats
    stats=$(sudo nvme fdp stats "$device" -e "$endpoint" 2>&1)
    if [[ $? -ne 0 ]]; then
        log_error "Failed to collect FDP stats from $device"
        return 1
    fi
    local hbmw mbmw
    hbmw=$(echo "$stats" | awk -F': ' '/Host Bytes with Metadata Written/ {print $2}')
    mbmw=$(echo "$stats" | awk -F': ' '/Media Bytes with Metadata Written/ {print $2}')
    echo "{\"hbmw\": ${hbmw:-0}, \"mbmw\": ${mbmw:-0}}" > "$output_file"
}

calculate_waf() {
    local pre_hbmw=$1 post_hbmw=$2 pre_mbmw=$3 post_mbmw=$4
    local delta_hbmw=$((post_hbmw - pre_hbmw))
    local delta_mbmw=$((post_mbmw - pre_mbmw))
    if [[ "$delta_hbmw" -gt 0 ]]; then
        awk "BEGIN { printf \"%.3f\", $delta_mbmw / $delta_hbmw }"
    else
        echo "N/A"
    fi
}

usage() {
    echo "Usage: $0 -j <fio_job>"
    echo "  -j: FIO job file path (must be under fdp/ or cns/ directory)"
    echo ""
    echo "  Device type (fdp/cns) is inferred from the file path automatically."
    echo "  Example: ./run_single_test.sh -j ./fio_workloads/fdp/3.84t/16j_u_2h.fio"
    exit 1
}

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        -j) FIO_JOB="$2"; shift 2;;
        *)  shift;;
    esac
done

[[ -z "$FIO_JOB" ]] && usage

if [[ ! -f "$FIO_JOB" ]]; then
    echo "ERROR: FIO job file not found: $FIO_JOB" >&2
    exit 1
fi

# ── Derive device type from file path ─────────────────────────────────────────
if [[ "$FIO_JOB" == */fdp/* ]]; then
    DEVICE_TYPE="fdp"
elif [[ "$FIO_JOB" == */cns/* ]]; then
    DEVICE_TYPE="cns"
else
    echo "ERROR: cannot determine device type from path: $FIO_JOB" >&2
    echo "       File must be under a 'fdp/' or 'cns/' directory." >&2
    exit 1
fi

# ── Auto-detect device from fio job file ──────────────────────────────────────
# The fio job's "filename=" field (e.g. /dev/ng3n1) is authoritative.
NG_DEV=$(grep -E '^\s*filename\s*=' "$FIO_JOB" | head -1 \
         | sed 's/.*=\s*//' | tr -d '[:space:]')

if [[ -z "$NG_DEV" ]]; then
    echo "ERROR: could not find 'filename=' in $FIO_JOB" >&2
    exit 1
fi

# /dev/ngXnY  →  controller X, namespace Y
CTRL_NUM=$(echo "$NG_DEV" | grep -oP '(?<=/dev/ng)\d+')
NS_NUM=$(echo  "$NG_DEV" | grep -oP '(?<=n)\d+$')

if [[ -z "$CTRL_NUM" || -z "$NS_NUM" ]]; then
    echo "ERROR: cannot parse controller/namespace from device '$NG_DEV'" >&2
    exit 1
fi

BASE_DEVICE="/dev/nvme${CTRL_NUM}"
DEVICE="$NG_DEV"
NVME_NS_DEV="${BASE_DEVICE}n${NS_NUM}"

# ── Device info ───────────────────────────────────────────────────────────────
DEVICE_BYTES=$(sudo blockdev --getsize64 "$NVME_NS_DEV" 2>/dev/null || echo 0)
SIZE_LABEL=$(awk "BEGIN{printf \"%.2f\", $DEVICE_BYTES/1e12}")

ENDPOINT=0
[[ "$DEVICE_TYPE" == "fdp" ]] && ENDPOINT=1

# ── Session directory and log file ───────────────────────────────────────────
FIO_SIZE=$(basename "$(dirname "$FIO_JOB")")   # e.g. 3.84t
FIO_NAME=$(basename "$FIO_JOB" .fio)          # e.g. 16j_u_2h
SESSION_DIR="logs/$(date +%Y-%m-%d_%H%M%S)_${DEVICE_TYPE}_${FIO_SIZE}_${FIO_NAME}"
mkdir -p "$SESSION_DIR"

export CURRENT_LOG_FILE="$SESSION_DIR/test.log"
MEASURE_LOG="$SESSION_DIR/waf_measurements.csv"
OCP_MEASURE_LOG="$SESSION_DIR/ocp_waf_measurements.csv"
CPU_LOG="$SESSION_DIR/cpu_util.log"
IO_BW_LOG="$SESSION_DIR/io_bandwidth.log"
RUH_LOG="$SESSION_DIR/ruh_writes.csv"

FIO_LOG_DIR="$SESSION_DIR/fio_logs"
mkdir -p "$FIO_LOG_DIR"
FIO_LOG="$FIO_LOG_DIR/fio_output.log"

# ── Log test configuration ────────────────────────────────────────────────────
log_info "=========================================="
log_info "FIO job file   : $FIO_JOB"
log_info "Device type    : $DEVICE_TYPE"
log_info "ng device      : $NG_DEV  (parsed from fio file)"
log_info "nvme controller: $BASE_DEVICE"
log_info "nvme namespace : $NVME_NS_DEV"
log_info "Device size    : ${SIZE_LABEL} TB"
log_info "Session dir    : $SESSION_DIR"
log_info "=========================================="

cat > "$SESSION_DIR/metadata.json" <<EOF
{
    "device_type": "$DEVICE_TYPE",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "fio_job": "$FIO_JOB",
    "ng_device": "$NG_DEV",
    "nvme_device": "$BASE_DEVICE",
    "nvme_ns_device": "$NVME_NS_DEV",
    "device_bytes": $DEVICE_BYTES
}
EOF

# ── Initialize device ─────────────────────────────────────────────────────────
# set_dev.sh auto-detects NSZE, NCAP, PHNDLS, NPHNDLS, CTRLID from the device.
log_info "Initializing device $BASE_DEVICE"
if [[ "$DEVICE_TYPE" == "fdp" ]]; then
    sudo ./tools/set_dev.sh -d "$BASE_DEVICE" -f 1
else
    sudo ./tools/set_dev.sh -d "$BASE_DEVICE" -f 0
fi

if [[ "$DEVICE_TYPE" == "fdp" ]]; then
    log_info "Collecting initial FDP statistics"
    collect_fdp_stats "$BASE_DEVICE" "$ENDPOINT" "$SESSION_DIR/pre_stats.json"
    PRE_HBMW=$(jq -r '.hbmw' "$SESSION_DIR/pre_stats.json" 2>/dev/null || echo "0")
    PRE_MBMW=$(jq -r '.mbmw' "$SESSION_DIR/pre_stats.json" 2>/dev/null || echo "0")
fi

# ── Start background monitors ─────────────────────────────────────────────────
log_info "Starting background monitors"
sudo ./tools/measure_dev -d "$DEVICE" -i "$MEASURE_INTERVAL" \
    >> "$MEASURE_LOG" 2>>"$SESSION_DIR/measure_dev_error.log" &
MEASURE_DEV_PID=$!

sudo ./tools/waf_monitor.sh "$BASE_DEVICE" 9999 10 "$OCP_MEASURE_LOG" \
    2>>"$SESSION_DIR/measure_dev_error.log" &
WAF_MONITOR_PID=$!

LC_ALL=C mpstat 30 >> "$CPU_LOG" 2>&1 &
CPU_MON_PID=$!

if [[ "$DEVICE_TYPE" == "fdp" ]]; then
    sudo ./tools/getRUHWrite.sh "${BASE_DEVICE}n1" >> "$RUH_LOG" 2>&1 &
    RUH_MON_PID=$!
fi

(
    printf '%-12s %12s %12s\n' "Timestamp" "Write_MiBps" "Read_MiBps"
    get_units() {
        sudo nvme smart-log "$BASE_DEVICE" 2>/dev/null \
            | awk '/Data Units Written/{gsub(/,/,""); for(i=1;i<=NF;i++) if($i~/^[0-9]{4,}$/) {w=$i} }
                   /Data Units Read/{gsub(/,/,""); for(i=1;i<=NF;i++) if($i~/^[0-9]{4,}$/) {r=$i} }
                   END{print w, r}'
    }
    read prev_w prev_r < <(get_units)
    while true; do
        sleep 30
        read curr_w curr_r < <(get_units)
        ts=$(date '+%H:%M:%S')
        write_mib=$(awk "BEGIN{printf \"%.2f\", ($curr_w - $prev_w) * 512000 / 30 / 1048576}")
        read_mib=$(awk  "BEGIN{printf \"%.2f\", ($curr_r - $prev_r) * 512000 / 30 / 1048576}")
        printf '%-12s %12s %12s\n' "$ts" "$write_mib" "$read_mib"
        prev_w=$curr_w
        prev_r=$curr_r
    done
) >> "$IO_BW_LOG" 2>&1 &
IO_MON_PID=$!

# ── Run FIO ───────────────────────────────────────────────────────────────────
# Run fio from inside FIO_LOG_DIR so that relative log paths in the .fio file
# (write_bw_log=./compare_fdp_seq_bw etc.) land directly in the session directory.
log_info "Running FIO workload: $FIO_JOB"
FIO_JOB_ABS=$(realpath "$FIO_JOB")
FIO_LOG_ABS=$(realpath "$FIO_LOG")
(cd "$FIO_LOG_DIR" && sudo "$FIO_BIN" "$FIO_JOB_ABS" \
    --output="$FIO_LOG_ABS" \
    --output-format=normal)

if [[ -f "$FIO_LOG" ]]; then
    log_info "FIO completed, log saved to $FIO_LOG"
else
    log_error "FIO log not created at $FIO_LOG"
fi

# ── Stop monitors ─────────────────────────────────────────────────────────────
sleep $SYNC_WAIT_TIME
log_info "Stopping monitors"
sudo kill "$MEASURE_DEV_PID"  2>/dev/null
sudo kill "$WAF_MONITOR_PID"  2>/dev/null
sudo pkill -f "measure_dev"   2>/dev/null
sudo pkill -f "waf_monitor.sh" 2>/dev/null
kill "$CPU_MON_PID"           2>/dev/null
kill "$IO_MON_PID"            2>/dev/null
[[ -n "$RUH_MON_PID" ]] && sudo kill "$RUH_MON_PID" 2>/dev/null
sudo pkill -f "getRUHWrite.sh" 2>/dev/null

log_info "Syncing filesystem"
sync; sleep 2; sync

# ── Collect final FDP stats and WAF ──────────────────────────────────────────
if [[ "$DEVICE_TYPE" == "fdp" ]]; then
    log_info "Collecting final FDP statistics"
    collect_fdp_stats "$BASE_DEVICE" "$ENDPOINT" "$SESSION_DIR/post_stats.json"
    POST_HBMW=$(jq -r '.hbmw' "$SESSION_DIR/post_stats.json" 2>/dev/null || echo "0")
    POST_MBMW=$(jq -r '.mbmw' "$SESSION_DIR/post_stats.json" 2>/dev/null || echo "0")
    WAF=$(calculate_waf "$PRE_HBMW" "$POST_HBMW" "$PRE_MBMW" "$POST_MBMW")
    cat > "$SESSION_DIR/waf_result.json" <<EOF
{
    "pre_hbmw": $PRE_HBMW,
    "post_hbmw": $POST_HBMW,
    "delta_hbmw": $((POST_HBMW - PRE_HBMW)),
    "pre_mbmw": $PRE_MBMW,
    "post_mbmw": $POST_MBMW,
    "delta_mbmw": $((POST_MBMW - PRE_MBMW)),
    "waf": "$WAF"
}
EOF
fi

cp "$FIO_JOB" "$SESSION_DIR/" 2>/dev/null || true

log_info "Test completed. Results saved to $SESSION_DIR"
