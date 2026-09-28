#!/bin/bash -x

# ========== Configuration ==========
NS=$1
MODE=$2  # "fdp" or "nofdp"

if [ -z "$NS" ]; then
  echo "Error: Namespace number is required!"
  echo "Usage: $0 <namespace_number> <fdp|nofdp>"
  exit 1
fi

if [ -z "$MODE" ] || { [ "$MODE" != "fdp" ] && [ "$MODE" != "nofdp" ] && [ "$MODE" != "torfs" ]; }; then
  echo "Error: Mode must be 'fdp', 'nofdp', or 'torfs'!"
  echo "Usage: $0 <namespace_number> <fdp|nofdp|torfs>"
  exit 1
fi

# ========== Mode settings ==========
if [ "$MODE" == "fdp" ]; then
    PREFIX="fdp"
    LOG_SUBDIR="fdp"
elif [ "$MODE" == "torfs" ]; then
    PREFIX="fdp"
    LOG_SUBDIR="torfs"
else
    PREFIX="nfdp"
    LOG_SUBDIR="nofdp"
fi

# Basic configuration
INTERVAL=600
FW=LDD5502Q

# TORFS Mode configuration
# Automatically enabled when MODE="torfs"
if [ "$MODE" == "torfs" ]; then
    ENABLE_TORFS_MODE=true
else
    ENABLE_TORFS_MODE=false
fi

# ========== Settings to maximize WAF ==========
NUM_KEYS=200000000
VALUE_SIZE=10240
NUM_THREADS=32

LEVEL_COMPACTION_DYNAMIC_LEVEL_BYTES=false
MAX_BYTES_FOR_LEVEL_BASE=$((256*1024*1024))
MAX_BYTES_FOR_LEVEL_MULTIPLIER=10
TARGET_FILE_SIZE_BASE=$((32*1024*1024))
LEVEL0_FILE_NUM_COMPACTION_TRIGGER=2
MAX_BACKGROUND_JOBS=4
WRITE_BUFFER_SIZE=$((128*1024*1024))
MAX_WRITE_BUFFER_NUMBER=4
CACHE_SIZE=$((8*1024*1024*1024))
COMPRESSION_TYPE="none"
DISABLE_WAL=true
SYNC=false
STATS_INTERVAL=300
REPORT_INTERVAL=600

# ========== Paths Configuration ==========
ROCKSDB_PATH=/home/fdp-research/rocksdb
REPO_BASE=/home/fdp-research/git_repo/fdp_evaluation/rocksdb_eval
DB_BENCH=${ROCKSDB_PATH}/db_bench

if [ ! -f "$DB_BENCH" ]; then
    echo "Error: db_bench not found at: $DB_BENCH"
    exit 1
fi

WORKLOAD_DIR="DB_BENCH_fillrandom"
LOG_PATH=${REPO_BASE}/results/${WORKLOAD_DIR}/${LOG_SUBDIR}

DEV_NVME="/dev/nvme${NS}"
DEV_NVME_NS="${DEV_NVME}n1"
DEV_NG="/dev/ng${NS}n1"
DB_DIR="/mnt/test/rocksdb_data"

# ========== Functions ==========

get_device_info() {
    local filter="grep nvme${NS} | grep ${FW}"
    bdev=$(nvme list | eval $filter | head -1 | awk '{print $1}')
    cdev=$(nvme list | eval $filter | head -1 | awk '{print $2}')
}

wait_for_capacity_stable() {
    local LCAP=0
    while true; do
        CAP=$(nvme list | grep "nvme${NS}" | grep ${FW} | awk '{print $7}')
        if [[ "$CAP" == '0.00' || "$CAP" == "$LCAP" ]]; then break; fi
        LCAP="$CAP"
        sleep 10
    done
}

cleanup_device() {
    fuser -mkv ${bdev} || true
    umount ${DEV_NVME}n* 2>/dev/null || true
    { [ "$MODE" == "fdp" ] || [ "$MODE" == "torfs" ]; } && export -n FDP_ENV
    nvme format -f ${bdev} -s 1
    ulimit -n 1048576
}

get_namespace_capacity() {
    CAPS=$(nvme id-ctrl ${DEV_NVME} | grep tnvmcap | awk '{print $3}')
    CAPS_NUM=$(echo ${CAPS} | tr -d ',')
    CAPS_SEC=$((CAPS_NUM/4096))
}

setup_namespace() {
    nvme detach-ns ${DEV_NVME} -n 1 -c 7 || true
    nvme delete-ns ${DEV_NVME} -n 1 || true

    if [ "$MODE" == "fdp" ] || [ "$MODE" == "torfs" ]; then
        echo "Setting up FDP namespace..."
        nvme fdp configs ${DEV_NVME} -e 1
        nvme admin-passthru ${DEV_NVME} --opcode=0x9 --cdw10=0x8000001d --cdw11=0x1 --cdw12=0x1
        nvme create-ns ${DEV_NVME} -s ${CAPS_SEC} -c ${CAPS_SEC} -b 4096 --phndls=0,1,2,3,4,5,6,7 -n 8 -e 1
        sleep 3
        nvme attach-ns ${DEV_NVME} -n 1 -c 7
        sudo nvme admin-passthru ${DEV_NVME} --namespace-id=0x1 --opcode=0x19 --cdw11=0x1 --cdw12=0x201
        nvme cmdset-ind-id-ns ${DEV_NVME} -n 1 | grep nsfeat
        nvme fdp-status ${DEV_NVME_NS}

        # TORFS Mode configuration
        if [[ "$ENABLE_TORFS_MODE" == "true" ]]; then
            export FDP_ENV=torfs:xnvme:${DEV_NG}?be=io_uring_cmd
            echo "✓ TORFS Mode ENABLED: FDP_ENV = ${FDP_ENV}"
        else
            unset FDP_ENV
            echo "✗ TORFS Mode DISABLED"
        fi

        sleep 5
    else
        echo "Setting up NoFDP namespace..."
        nvme admin-passthru ${DEV_NVME} --opcode=0x9 --cdw10=0x8000001D --cdw11=0x1 --cdw12=0x0
        nvme create-ns ${DEV_NVME} -s ${CAPS_SEC} -c ${CAPS_SEC} -b 4096 -e 1
        nvme attach-ns ${DEV_NVME} -n 1 -c 7
        sleep 5
    fi
}

start_monitoring() {
    nohup sudo ./tools/measure_dev -d ${cdev} -i ${INTERVAL} > ${LOG_PATH}/${PREFIX}_waf.stat 2>&1 &
    nohup sudo ./tools/getDfAndNvme.sh ${bdev} ${INTERVAL} > ${LOG_PATH}/${PREFIX}_cap.stat 2>&1 &

    if [[ "$ENABLE_TORFS_MODE" == "true" ]]; then
        # TORFS mode: monitor nvme device usage
        nohup ./tools/disk_monitor.sh torfs-mode=1 n=${NS} ${LOG_PATH}/${PREFIX}_disk_usage.log 2>&1 &
    else
        # Standard mode: monitor filesystem mount point
        nohup bash ./tools/disk_monitor.sh ${LOG_PATH}/${PREFIX}_disk_usage.log 2>&1 &
    fi
}

stop_monitoring() {
    sudo pkill -f measure_dev
    sudo pkill -f getDfAndNvme
    sudo pkill -f monitor_disk

}

prepare_filesystem() {
    if [[ "$ENABLE_TORFS_MODE" == "true" ]]; then
        # TORFS mode: Skip mkfs and mount, TORFS manages device directly
        echo "✓ TORFS Mode: Skipping mkfs and mount (TORFS manages device directly)"
        rm -rf /mnt/test/*
        mkdir -p ${DB_DIR}
        sleep 5
    else
        echo "✓ Standard Mode: Creating XFS filesystem and mounting"
        mkfs.xfs -f ${bdev}
        mount -o discard ${bdev} /mnt/test/
        rm -rf /mnt/test/*
        mkdir -p ${DB_DIR}
    fi
}

run_fillrandom_maximum_waf() {
    local BENCH_LOG="${LOG_PATH}/${PREFIX}_fillrandom_max_waf.log"

    echo "=========================================="
    echo "Maximum WAF Test: fillrandom (${MODE^^})"
    echo "Strategy: Continuous new key insertion"
    echo "Target: 2TB of NEW data"
    echo "Configuration:"
    echo "  - level_compaction_dynamic_level_bytes: ${LEVEL_COMPACTION_DYNAMIC_LEVEL_BYTES}"
    echo "  - max_bytes_for_level_base: ${MAX_BYTES_FOR_LEVEL_BASE} bytes"
    echo "  - target_file_size_base: ${TARGET_FILE_SIZE_BASE} bytes"
    echo "  - level0_file_num_compaction_trigger: ${LEVEL0_FILE_NUM_COMPACTION_TRIGGER}"
    echo "  - max_background_jobs: ${MAX_BACKGROUND_JOBS}"
    echo "  - compression_type: ${COMPRESSION_TYPE}"
    echo "=========================================="

    local start_time=$(date +%s)

    # Build optional TORFS fs_uri argument
    local FS_URI_ARG=""
    if [[ "$ENABLE_TORFS_MODE" == "true" ]]; then
        FS_URI_ARG="--fs_uri=torfs:xnvme:${DEV_NG}?be=io_uring_cmd"
    fi

    ${DB_BENCH} \
        --db=${DB_DIR} \
        ${FS_URI_ARG} \
        --benchmarks=fillrandom \
        --use_existing_db=0 \
        --num=${NUM_KEYS} \
        --value_size=${VALUE_SIZE} \
        --threads=${NUM_THREADS} \
        --cache_size=${CACHE_SIZE} \
        --write_buffer_size=${WRITE_BUFFER_SIZE} \
        --max_write_buffer_number=${MAX_WRITE_BUFFER_NUMBER} \
        --target_file_size_base=${TARGET_FILE_SIZE_BASE} \
        --max_background_jobs=${MAX_BACKGROUND_JOBS} \
        --max_bytes_for_level_base=${MAX_BYTES_FOR_LEVEL_BASE} \
        --max_bytes_for_level_multiplier=${MAX_BYTES_FOR_LEVEL_MULTIPLIER} \
        --level0_file_num_compaction_trigger=${LEVEL0_FILE_NUM_COMPACTION_TRIGGER} \
        --level_compaction_dynamic_level_bytes=${LEVEL_COMPACTION_DYNAMIC_LEVEL_BYTES} \
        --compression_type=${COMPRESSION_TYPE} \
        --disable_wal=${DISABLE_WAL} \
        --sync=${SYNC} \
        --statistics \
        --stats_interval_seconds=${STATS_INTERVAL} \
        --report_interval_seconds=${REPORT_INTERVAL} \
        > "${BENCH_LOG}" 2>&1

    local end_time=$(date +%s)
    echo "Test completed in $((end_time - start_time)) seconds" | tee -a ${LOG_PATH}/timeline.log

    echo "Generating final statistics..."
    ${DB_BENCH} --db=${DB_DIR} ${FS_URI_ARG} --benchmarks=stats     >> "${BENCH_LOG}" 2>&1
    ${DB_BENCH} --db=${DB_DIR} ${FS_URI_ARG} --benchmarks=levelstats >> "${BENCH_LOG}" 2>&1
}

wait_for_compaction() {
    local FS_URI_ARG=""
    if [[ "$ENABLE_TORFS_MODE" == "true" ]]; then
        FS_URI_ARG="--fs_uri=torfs:xnvme:${DEV_NG}?be=io_uring_cmd"
    fi

    echo "Waiting for background compactions to complete..."
    ${DB_BENCH} \
        --db=${DB_DIR} \
        ${FS_URI_ARG} \
        --benchmarks=waitforcompaction \
        > "${LOG_PATH}/${PREFIX}_wait_compaction.log" 2>&1
    echo "All compactions completed" | tee -a ${LOG_PATH}/timeline.log
}

# ========== Main Execution ==========

echo "=========================================="
echo "Maximum WAF Test - Mode: ${MODE^^}"
echo "Namespace: ${NS}, Target Device: nvme${NS}"
echo "=========================================="

mkdir -p ${LOG_PATH}
get_device_info

echo "[$(date)] Starting Maximum WAF Test (${MODE^^} Mode)..." | tee ${LOG_PATH}/timeline.log

echo "[$(date)] Step 1: Device cleanup and setup" | tee -a ${LOG_PATH}/timeline.log
cleanup_device
wait_for_capacity_stable
get_namespace_capacity
setup_namespace
get_device_info

echo "Device Info:" | tee -a ${LOG_PATH}/timeline.log
echo "  Block device: ${bdev}" | tee -a ${LOG_PATH}/timeline.log
echo "  Char device: ${cdev}" | tee -a ${LOG_PATH}/timeline.log

echo "[$(date)] Step 2: Filesystem preparation" | tee -a ${LOG_PATH}/timeline.log
prepare_filesystem

echo "[$(date)] Step 3: Starting monitoring" | tee -a ${LOG_PATH}/timeline.log
start_monitoring

echo "[$(date)] Step 4: Running fillrandom with maximum WAF configuration (${MODE^^})" | tee -a ${LOG_PATH}/timeline.log
run_fillrandom_maximum_waf

echo "[$(date)] Step 5: Waiting for all background compactions" | tee -a ${LOG_PATH}/timeline.log
wait_for_compaction

echo "[$(date)] Step 6: Stopping monitoring" | tee -a ${LOG_PATH}/timeline.log
stop_monitoring

# ========== Results Summary ==========
BENCH_LOG="${LOG_PATH}/${PREFIX}_fillrandom_max_waf.log"

echo ""
echo "=========================================="
echo "Test Completed! Results: ${LOG_PATH}/"
echo "=========================================="

if grep -q "Cumulative compaction" "${BENCH_LOG}"; then
    echo "Cumulative Compaction Stats:"
    grep "Cumulative compaction" "${BENCH_LOG}" | tail -1
    echo ""
fi

echo "Key files:"
echo "  - Main log:        ${PREFIX}_fillrandom_max_waf.log"
echo "  - WAF statistics:  ${PREFIX}_waf.stat"
echo "  - Capacity stats:  ${PREFIX}_cap.stat"
echo "  - Timeline:        timeline.log"
echo ""
echo "To analyze:"
echo "  grep -A 20 'Cumulative compaction' ${BENCH_LOG} | tail -30"
echo "  tail -50 ${LOG_PATH}/${PREFIX}_waf.stat"
echo "  grep -A 30 'Level Files Size' ${BENCH_LOG} | tail -40"
echo ""
echo "Compare FDP vs NoFDP:"
echo "  tail -20 ${REPO_BASE}/results/${WORKLOAD_DIR}/fdp/fdp_waf.stat"
echo "  tail -20 ${REPO_BASE}/results/${WORKLOAD_DIR}/nofdp/nfdp_waf.stat"
echo ""
echo "[$(date)] All done!" | tee -a ${LOG_PATH}/timeline.log