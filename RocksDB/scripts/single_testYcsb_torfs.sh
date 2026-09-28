#!/bin/bash -x

# ========== Configuration ==========
NS=$1

if [ -z "$NS" ]; then
  echo "Error: Namespace number is required!"
  echo "Usage: $0 <namespace_number>"
  echo "Example: $0 1"
  exit 1
fi

# Test configuration
INTERVAL=600
FW=LDD5502Q

# TORFS Mode configuration
# Set to "true" to enable TORFS mode, "false" to disable
ENABLE_TORFS_MODE=true

# Workload configuration
WORKLOAD_TYPE="a"           # Workload type: a, b, c, d, e, f, etc.
LOAD_RECORD_COUNT=40000000  # Number of records to load (e.g., 60000000 = 60M)
RUN_OPERATION_COUNT=200000000 # Number of operations to run (e.g., 20000000 = 20M)

# Base paths
BASE_PATH=/home/fdp-research/YCSB/ycsb-rocksdb-binding-0.18.0-SNAPSHOT
REPO_BASE=/home/fdp-research/git_repo/fdp_evaluation/rocksdb_eval

# Tool paths
YCSB=${BASE_PATH}/bin/ycsb.sh
OPTION=${REPO_BASE}/OPTIONS-000009
TEST_SCRIPT=${REPO_BASE}/single_testYcsb.sh

# Workload file path
LOAD_CONFIG=${REPO_BASE}/workloads/workload${WORKLOAD_TYPE}
UPDATE_CONFIG=${LOAD_CONFIG}

# Check if workload file exists
if [ ! -f "$LOAD_CONFIG" ]; then
    echo "Error: Workload file not found: $LOAD_CONFIG"
    echo "Please check WORKLOAD_TYPE configuration."
    exit 1
fi

# Update workload file with configured counts
echo "Updating workload file: $LOAD_CONFIG"
sed -i "s/^recordcount=.*/recordcount=${LOAD_RECORD_COUNT}/" "$LOAD_CONFIG"
sed -i "s/^operationcount=.*/operationcount=${RUN_OPERATION_COUNT}/" "$LOAD_CONFIG"

# Convert to millions (M) for display
LOAD_SIZE_M=$((LOAD_RECORD_COUNT / 1000000))
RUN_SIZE_M=$((RUN_OPERATION_COUNT / 1000000))

# Determine filesystem mode name
if [[ "$ENABLE_TORFS_MODE" == "true" ]]; then
    FS_MODE="torfs"
else
    FS_MODE="xfs"
fi

# Generate log path: results/WLx_LOAD_xxM_RUN_xxM/torfs_or_xfs/
WORKLOAD_DIR="WL${WORKLOAD_TYPE}_LOAD_${LOAD_SIZE_M}M_RUN_${RUN_SIZE_M}M_SMRC31_BASE_256"
LOG_PATH=${REPO_BASE}/results/${WORKLOAD_DIR}/${FS_MODE}

# Device paths
DEV_NVME="/dev/nvme${NS}"
DEV_NVME_NS="${DEV_NVME}n1"
DEV_NG="/dev/ng${NS}n1"

# ========== Functions ==========

# Get device info from nvme list
get_device_info() {
    local filter="grep nvme${NS} | grep ${FW}"
    bdev=$(nvme list | eval $filter | head -1 | awk '{print $1}')
    cdev=$(nvme list | eval $filter | head -1 | awk '{print $2}')
}

# Wait for device capacity to stabilize
wait_for_capacity_stable() {
    local LCAP=0
    while true; do
        CAP=$(nvme list | grep "nvme${NS}" | grep ${FW} | awk '{print $7}')
        if [[ "$CAP" == '0.00' || "$CAP" == "$LCAP" ]]; then
            break
        fi
        LCAP="$CAP"
        sleep 60
    done
}

# Cleanup device and unmount
cleanup_device() {
    fuser -mkv ${bdev}
    umount ${DEV_NVME}n1 2>/dev/null || true
    umount ${DEV_NVME}n2 2>/dev/null || true
    umount ${DEV_NVME}n3 2>/dev/null || true
    export -n ZNS_ENV
    nvme format -f ${bdev} -s 1
    ulimit -n 1048576
}

# Get and calculate namespace capacity
get_namespace_capacity() {
    CAPS=$(nvme id-ctrl ${DEV_NVME} | grep tnvmcap | awk '{print $3}')
    CAPS_NUM=$(echo ${CAPS} | tr -d ',')
    CAPS_SEC=$((CAPS_NUM/4096))
}

# Setup namespace with FDP
setup_fdp_namespace() {
    nvme detach-ns ${DEV_NVME} -n 1 -c 7
    nvme delete-ns ${DEV_NVME} -n 1
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
}

# Setup namespace without FDP
setup_nofdp_namespace() {
    nvme detach-ns ${DEV_NVME} -n 1 -c 7
    nvme delete-ns ${DEV_NVME} -n 1
    nvme admin-passthru ${DEV_NVME} --opcode=0x9 --cdw10=0x8000001D --cdw11=0x1 --cdw12=0x0
    nvme create-ns ${DEV_NVME} -s ${CAPS_SEC} -c ${CAPS_SEC} -b 4096 -e 1
    nvme attach-ns ${DEV_NVME} -n 1 -c 7
    sleep 5
}

# Start monitoring tools
start_monitoring() {
    local prefix=$1  # "fdp" or "nfdp"

    nohup sudo ./measure_dev -d ${cdev} -i ${INTERVAL} > ${LOG_PATH}/${prefix}_waf.stat 2>&1 &
    sleep 3

    nohup sudo ./getDfAndNvme.sh ${bdev} ${INTERVAL} > ${LOG_PATH}/${prefix}_cap.stat 2>&1 &
    sleep 3

    if [[ "$prefix" == "fdp" ]]; then
        nohup ./getRUHWrite.sh ${bdev} > ${LOG_PATH}/RUH_Write.stat 2>&1 &
        nohup ./disk_monitor.sh ${LOG_PATH}/disk_monitor.stat &
        sleep 5
    fi
}

# Stop monitoring tools
stop_monitoring() {
    sudo pkill -f getRUHWrite
    sudo pkill -f disk_monitor
    sudo pkill -f measure_dev
    sudo pkill -f getDfAndNvme

    # Fallback: kill by PID
    MPID=$(ps -ef | grep measure_dev | grep -v 'grep' | head -1 | awk '{print $2}')
    [[ -n "$MPID" ]] && kill -9 $MPID 2>/dev/null || true

    MPID=$(ps -ef | grep getDfAndNvme | grep -v 'grep' | head -1 | awk '{print $2}')
    [[ -n "$MPID" ]] && kill -9 $MPID 2>/dev/null || true
}

# Prepare filesystem
prepare_filesystem() {
    if [[ "$ENABLE_TORFS_MODE" == "true" ]]; then
        # TORFS mode: Skip mkfs and mount, TORFS manages device directly
        echo "✓ TORFS Mode: Skipping mkfs and mount (TORFS manages device directly)"
        # Only clean /mnt/test/ directory
        rm -rf /mnt/test/*
        sleep 5
    else
        # Standard mode: Create filesystem then mount
        echo "✓ Standard Mode: Creating XFS filesystem and mounting"
        mkfs.xfs ${bdev}
        sleep 5
        mount -o discard ${bdev} /mnt/test/
        # Clean the mount point
        rm -rf /mnt/test/*
        sleep 5
    fi
}

# Run YCSB test
run_ycsb_test() {
    local log_prefix=$1  # "fdp" or "nofdp"

    for c in 1; do
        $YCSB load rocksdb -s -P ${LOAD_CONFIG} \
            -p rocksdb.dir=/mnt/test/ \
            -p rocksdb.optionsfile=${OPTION} \
            > "${LOG_PATH}/${log_prefix}_load.log" 2>&1

        # Uncomment for run phase:
        $YCSB run rocksdb -s -P ${UPDATE_CONFIG} \
            -p rocksdb.dir=/mnt/test/ \
            -p rocksdb.optionsfile=${OPTION} \
            > "${LOG_PATH}/${log_prefix}_run.log" 2>&1
    done
}

# ========== Main Script ==========

# Check if log path already exists
if [ -d "${LOG_PATH}" ]; then
    echo "Error: LOG_PATH already exists: ${LOG_PATH}"
    echo "Please remove it or change CUR_WORKLOAD_CONFIG before rerun."
    exit 1
fi

# Create log directory and copy config files
mkdir -p ${LOG_PATH}
cp ${LOAD_CONFIG} ${LOG_PATH}/
cp ${OPTION} ${LOG_PATH}/
cp ${TEST_SCRIPT} ${LOG_PATH}/

# Get device information
get_device_info

echo "=========================================="
echo "Starting FDP Test"
echo "=========================================="
echo "Workload Type: WL${WORKLOAD_TYPE}"
echo "Workload File: ${LOAD_CONFIG}"
echo "Load Phase: ${LOAD_RECORD_COUNT} records (${LOAD_SIZE_M}M)"
echo "Run Phase: ${RUN_OPERATION_COUNT} operations (${RUN_SIZE_M}M)"
echo "Filesystem Mode: ${FS_MODE}"
echo "Device: ${bdev}"
echo "Char device: ${cdev}"
echo "Log path: ${LOG_PATH}"
echo "=========================================="

# ========== Round 1: FDP Test ==========
cleanup_device
wait_for_capacity_stable
get_namespace_capacity
setup_fdp_namespace
start_monitoring "fdp"
prepare_filesystem
run_ycsb_test "fdp"
stop_monitoring

# Clean up WAL logs
sudo rm -rf /home/fdp-research/git_repo/fdp_research/log_files/wal/*

# ========== Round 2: Non-FDP Test (Skip if TORFS mode) ==========
if [[ "$ENABLE_TORFS_MODE" == "true" ]]; then
    echo "=========================================="
    echo "TORFS Mode: Skipping Non-FDP Test"
    echo "=========================================="
else
    echo "=========================================="
    echo "Starting Non-FDP Test"
    echo "=========================================="

    # Refresh device info
    get_device_info

    cleanup_device
    wait_for_capacity_stable
    get_namespace_capacity
    setup_nofdp_namespace
    start_monitoring "nfdp"
    prepare_filesystem
    run_ycsb_test "nofdp"
    stop_monitoring
fi

echo "=========================================="
echo "Test completed successfully!"
echo "Results saved to: ${LOG_PATH}"
echo "=========================================="
