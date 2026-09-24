#!/bin/bash -x
#==============================================================================
# Combined TPC-C (MySQL/InnoDB) + YCSB (RocksDB) concurrent benchmark
#
# Usage: ./combined_test.sh [nvme_ctrl_num] [mode]
#   nvme_ctrl_num: NVMe controller index (default: 0 → /dev/nvme0)
#   mode:          fdp | cns  (default: fdp)
#
# Both workloads run simultaneously on the same device under /mnt/test:
#   /mnt/test/tpcc/   → MySQL InnoDB data
#   /mnt/test/ycsb/   → RocksDB data
#==============================================================================

script_dir=$(cd $(dirname $0); pwd)

NS=${1:-0}
MODE=${2:-fdp}

#------------------------------------------------------------------------------
# Workload switches — set to 0 to disable a workload
# Default: both run in parallel
# RocksDB: 0,2,3,4,5 MySql: user tablespace ->1, all -> 6
#------------------------------------------------------------------------------
RUN_MYSQL=1      # 1 = run MySQL/TPC-C,  0 = skip
RUN_ROCKSDB=0    # 1 = run RocksDB/YCSB, 0 = skip

#------------------------------------------------------------------------------
# Filesystem options
#------------------------------------------------------------------------------
FS_TYPE="ext4"   # ext4 | xfs
DISCARD=1        # 1 = enable discard/TRIM at mkfs + mount, 0 = disable

#------------------------------------------------------------------------------
# Validation
#------------------------------------------------------------------------------
if [[ "${MODE}" != "fdp" && "${MODE}" != "cns" ]]; then
    echo "Error: mode must be 'fdp' or 'cns', got '${MODE}'"
    exit 1
fi

if [[ $RUN_MYSQL -eq 0 && $RUN_ROCKSDB -eq 0 ]]; then
    echo "Error: at least one of RUN_MYSQL or RUN_ROCKSDB must be 1"
    exit 1
fi

if [[ "${FS_TYPE}" != "ext4" && "${FS_TYPE}" != "xfs" ]]; then
    echo "Error: FS_TYPE must be 'ext4' or 'xfs', got '${FS_TYPE}'"
    exit 1
fi

#------------------------------------------------------------------------------
# Device paths
#------------------------------------------------------------------------------
NVME_CTRL="/dev/nvme${NS}"
NVME_BLK="${NVME_CTRL}n1"
NVME_CHR="/dev/ng${NS}n1"
MOUNT_POINT="/mnt/test"
TPCC_DIR="${MOUNT_POINT}/tpcc"
YCSB_DIR="${MOUNT_POINT}/ycsb"
INTERVAL=600

#------------------------------------------------------------------------------
# TPC-C parameters
#------------------------------------------------------------------------------
mysql_root="/usr/local/mysql/bin"
data_dir="${TPCC_DIR}/datadir"
tpcc_dir="$(dirname "${script_dir}")"

DBHOST=127.0.0.1
DBPORT=3306
WAREHOUSE=6000
WARMUP=300
TPCCHOUR=10
TPCCTIME=$((TPCCHOUR * 3600))
CONNECTIONS=128
DATABASE="tpcc"

#------------------------------------------------------------------------------
# YCSB parameters
#------------------------------------------------------------------------------
WORKLOAD_TYPE="a"
LOAD_RECORD_COUNT=20000000
RUN_OPERATION_COUNT=60000000
ROCKSDB_TARGET_OPS=-1   # ops/sec rate limit for YCSB load+run; -1 = unlimited

YCSB_BASE=/home/fdp-research/YCSB/ycsb-rocksdb-binding-0.18.0-SNAPSHOT
REPO_BASE=/home/fdp-research/git_repo/fdp_evaluation/rocksdb_eval
YCSB=${YCSB_BASE}/bin/ycsb.sh
OPTION=${REPO_BASE}/OPTIONS-000009
LOAD_CONFIG=${REPO_BASE}/workloads/workload${WORKLOAD_TYPE}

LOAD_SIZE_M=$((LOAD_RECORD_COUNT / 1000000))
RUN_SIZE_M=$((RUN_OPERATION_COUNT / 1000000))

#------------------------------------------------------------------------------
# Log directory — label reflects which workloads are active
#------------------------------------------------------------------------------
if [[ $RUN_MYSQL -eq 1 && $RUN_ROCKSDB -eq 1 ]]; then
    BENCH_LABEL="combined"
elif [[ $RUN_MYSQL -eq 1 ]]; then
    BENCH_LABEL="mysql_only"
else
    BENCH_LABEL="rocksdb_only"
fi

ts=$(date +"%Y%m%d_%H_%M_%S")

# Build the directory name from only the parts relevant to the workloads
# that actually run (avoids misleading tpcc/ycsb params in the name when
# a workload is disabled), tagged with the controller so parallel runs
# against different NVMe devices never collide, timestamp-first for
# chronological `ls` sorting.
NAME_PARTS=("nvme${NS}" "${MODE}" "${BENCH_LABEL}")
[[ $RUN_MYSQL   -eq 1 ]] && NAME_PARTS+=("tpccW${WAREHOUSE}_${TPCCHOUR}hr")
[[ $RUN_ROCKSDB -eq 1 ]] && NAME_PARTS+=("ycsbWL${WORKLOAD_TYPE}")
LOG_DIR="${tpcc_dir}/results/${ts}_$(IFS=_; echo "${NAME_PARTS[*]}")"
MYSQL_LOG_DIR="${LOG_DIR}/mysql"
ROCKSDB_LOG_DIR="${LOG_DIR}/rocksdb"
mkdir -p "${LOG_DIR}"
[[ $RUN_MYSQL    -eq 1 ]] && mkdir -p "${MYSQL_LOG_DIR}"
[[ $RUN_ROCKSDB  -eq 1 ]] && mkdir -p "${ROCKSDB_LOG_DIR}"
cp "$0" "${LOG_DIR}/"

echo "=========================================="
echo "Benchmark (${MODE^^}): ${BENCH_LABEL^^}"
echo "Controller: ${NVME_CTRL}  Block: ${NVME_BLK}  Char: ${NVME_CHR}"
echo "Filesystem: ${FS_TYPE}  Discard: $([[ $DISCARD -eq 1 ]] && echo enabled || echo disabled)"
[[ $RUN_MYSQL   -eq 1 ]] && echo "TPC-C: ${WAREHOUSE} warehouses, ${TPCCHOUR}h, ${CONNECTIONS} connections → ${TPCC_DIR}"
[[ $RUN_ROCKSDB -eq 1 ]] && echo "YCSB:  workload${WORKLOAD_TYPE}, load=${LOAD_SIZE_M}M, run=${RUN_SIZE_M}M → ${YCSB_DIR}"
echo "Log: ${LOG_DIR}"
echo "Timestamp: ${ts}"
echo "=========================================="

#==============================================================================
# Device helpers
#==============================================================================

terminate_mysql() {
    local pids
    pids=$(ps -ef | grep mysqld | grep -v grep | awk '{print $2}')
    for id in $pids; do
        kill -9 "$id" 2>/dev/null && echo "killed mysqld $id"
    done
    sleep 2
}

wait_for_capacity_stable() {
    local LCAP=0
    while true; do
        CAP=$(nvme list | grep "nvme${NS}n1" | awk '{print $7}')
        if [[ "$CAP" == '0.00' || "$CAP" == "$LCAP" ]]; then
            break
        fi
        LCAP="$CAP"
        sleep 60
    done
}

get_namespace_capacity() {
    CAPS=$(nvme id-ctrl ${NVME_CTRL} | grep tnvmcap | awk '{print $3}')
    CAPS_NUM=$(echo ${CAPS} | tr -d ',')
    CAPS_SEC=$((CAPS_NUM / 4096))
}

cleanup_device() {
    terminate_mysql
    fuser -mkv ${NVME_BLK} 2>/dev/null || true
    umount ${NVME_BLK} 2>/dev/null || true
    nvme format -f ${NVME_BLK} -s 1
    ulimit -n 1048576
}

setup_fdp_namespace() {
    echo "--- Setting up FDP namespace ---"
    nvme detach-ns ${NVME_CTRL} -n 1 -c 7
    nvme delete-ns ${NVME_CTRL} -n 1
    nvme fdp configs ${NVME_CTRL} -e 1
    nvme admin-passthru ${NVME_CTRL} --opcode=0x9 --cdw10=0x8000001d --cdw11=0x1 --cdw12=0x1
    nvme create-ns ${NVME_CTRL} -s ${CAPS_SEC} -c ${CAPS_SEC} -b 4096 --phndls=0,1,2,3,4,5,6,7 -n 8 -e 1
    sleep 3
    nvme attach-ns ${NVME_CTRL} -n 1 -c 7
    nvme admin-passthru ${NVME_CTRL} --namespace-id=0x1 --opcode=0x19 --cdw11=0x1 --cdw12=0x201
    nvme cmdset-ind-id-ns ${NVME_CTRL} -n 1 | grep nsfeat
    nvme fdp-status ${NVME_BLK}
    sleep 5
}

setup_cns_namespace() {
    echo "--- Setting up CNS (non-FDP) namespace ---"
    nvme detach-ns ${NVME_CTRL} -n 1 -c 7
    nvme delete-ns ${NVME_CTRL} -n 1
    nvme admin-passthru ${NVME_CTRL} --opcode=0x9 --cdw10=0x8000001D --cdw11=0x1 --cdw12=0x0
    nvme create-ns ${NVME_CTRL} -s ${CAPS_SEC} -c ${CAPS_SEC} -b 4096 -e 1
    nvme attach-ns ${NVME_CTRL} -n 1 -c 7
    sleep 5
}

setup_namespace() {
    if [[ "${MODE}" == "fdp" ]]; then
        setup_fdp_namespace
    else
        setup_cns_namespace
    fi
}

capture_device_state() {
    local tag=$1 log_dir=$2
    nvme fdp status ${NVME_BLK}    | grep RUAMW > "${log_dir}/ruamw_${tag}.log" 2>&1 || true
    nvme ocp smart-add-log ${NVME_BLK}          > "${log_dir}/smart_${tag}.log" 2>&1
    nvme smart-log ${NVME_BLK}                  > "${log_dir}/smart_basic_${tag}.log" 2>&1
}

#==============================================================================
# MySQL helpers
#==============================================================================

create_mysql_dirs() {
    rm -rf /tmp/*
    rm -rf "${data_dir}"
    mkdir -pv "${data_dir}/temp/"
    mkdir -pv "${data_dir}/log/"
    mkdir -pv "${data_dir}/data/"
    mkdir -pv "${data_dir}/tmp/"
    touch "${data_dir}/log/err.log"
    chown -R root:root "${data_dir}"
}

generate_mycnf() {
    cat > /etc/my.cnf <<EOF
[client]
port=3306
socket=${data_dir}/temp/mysqld-8.0.sock

[mysqld]
innodb_buffer_pool_size = 64G
innodb_doublewrite_pages = 512
innodb_redo_log_capacity = 34359738368
max_prepared_stmt_count=1048576
max_connections=8192
innodb_thread_concurrency=48
innodb_read_io_threads=16
innodb_write_io_threads=16
innodb_flush_log_at_trx_commit=2
innodb_io_capacity=6000
innodb_io_capacity_max=16000
innodb_flush_method=O_DIRECT
user=root
default_authentication_plugin=mysql_native_password
character_set_server=utf8mb4
collation_server=utf8mb4_unicode_ci
skip-mysqlx
log-error=${data_dir}/log/err.log
log_error_verbosity=3
port=3306
datadir=${data_dir}/data
socket=${data_dir}/temp/mysqld-8.0.sock
pid-file=${data_dir}/temp/mysqld1.pid
tmpdir=${data_dir}/tmp
basedir=/usr/local/mysql
EOF
}

wait_for_mysql_ready() {
    local mysqld_safe_pid=$1
    local socket="${data_dir}/temp/mysqld-8.0.sock"
    local timeout_sec=300
    local waited=0

    echo "Waiting for mysqld socket ${socket} to appear ..."
    while [[ ! -S "${socket}" ]]; do
        if ! kill -0 "${mysqld_safe_pid}" 2>/dev/null; then
            echo "ERROR: mysqld_safe (pid ${mysqld_safe_pid}) exited before becoming ready" >&2
            return 1
        fi
        if (( waited >= timeout_sec )); then
            echo "ERROR: mysqld did not become ready within ${timeout_sec}s" >&2
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    echo "mysqld socket ready after ${waited}s"
}

#==============================================================================
# Step 1: Device setup + mount
#==============================================================================

echo "--- Step 1: Device setup ---"
cleanup_device
wait_for_capacity_stable
get_namespace_capacity
setup_namespace

case "${FS_TYPE}" in
    ext4)
        mkfs.ext4 -E discard ${NVME_BLK}
        ;;
    xfs)
        mkfs.xfs -f ${NVME_BLK}
        ;;
esac
sleep 5
if [[ $DISCARD -eq 1 ]]; then
    mount -o discard ${NVME_BLK} ${MOUNT_POINT}
else
    mount ${NVME_BLK} ${MOUNT_POINT}
fi
sleep 180

[[ $RUN_MYSQL   -eq 1 ]] && mkdir -p "${TPCC_DIR}"
[[ $RUN_ROCKSDB -eq 1 ]] && mkdir -p "${YCSB_DIR}"

#==============================================================================
# Step 2: MySQL init (skipped when RUN_MYSQL=0)
#==============================================================================

if [[ $RUN_MYSQL -eq 1 ]]; then
    echo "--- Step 2: MySQL init ---"
    create_mysql_dirs
    generate_mycnf
    ${mysql_root}/mysqld --initialize \
                         --datadir="${data_dir}/data" \
                         --user=root
    ${mysql_root}/mysqld_safe --defaults-file=/etc/my.cnf &
    wait_for_mysql_ready $!

    pawd=$(grep 'temporary password' "${data_dir}/log/err.log" | awk '{print $NF}')
    echo "Temp password: ${pawd}"
    ${mysql_root}/mysqladmin -u root -p"${pawd}" password ''
    ${mysql_root}/mysqladmin -u root create ${DATABASE}
    ${mysql_root}/mysql -u root ${DATABASE} < "${tpcc_dir}/create_table.sql"
else
    echo "--- Step 2: MySQL init skipped (RUN_MYSQL=0) ---"
fi

#==============================================================================
# Step 3: Start WAF monitor, then load phase
#==============================================================================

echo "--- Step 3: Start WAF monitor ---"
capture_device_state "before_load" "${LOG_DIR}"

# WAF monitor
nohup ${script_dir}/measure_dev -d ${NVME_CHR} -i ${INTERVAL} \
      > "${LOG_DIR}/${MODE}_waf.stat" 2>&1 &
MEASURE_PID=$!
echo "measure_dev PID: ${MEASURE_PID}"

# Long-running host/NAND WAF CSV logger (waf_monitor.sh). Duration is padded
# well beyond TPCCHOUR to cover load+warmup and any longer-running RocksDB
# pipeline; the monitor is killed explicitly in Step 5 regardless.
WAF_MON_INTERVAL_MIN=$(( INTERVAL / 60 ))
WAF_MON_DURATION_HOURS=24
nohup ${script_dir}/waf_monitor.sh ${NVME_CTRL} ${WAF_MON_DURATION_HOURS} ${WAF_MON_INTERVAL_MIN} \
      "${LOG_DIR}/${MODE}_waf_monitor.csv" > "${LOG_DIR}/${MODE}_waf_monitor.log" 2>&1 &
WAF_MON_PID=$!
echo "waf_monitor PID: ${WAF_MON_PID}"

# FDP per-placement-identifier write monitor (getRUHWrite.sh)
nohup ${script_dir}/rocksdb/getRUHWrite.sh ${NVME_BLK} \
    > "${LOG_DIR}/${MODE}_RuhWrite.log" 2>&1 &
RUAMW_PID=$!
echo "getRUHWrite PID: ${RUAMW_PID}"

# Disk usage monitor (disk_monitor.sh) — logs df output for /mnt/test
nohup ${script_dir}/disk_monitor.sh "${LOG_DIR}/${MODE}_disk_usage.log" \
    > /dev/null 2>&1 &
DISK_MON_PID=$!
echo "disk_monitor PID: ${DISK_MON_PID}"

# CPU usage monitor — mpstat every 10 s, all cores + summary
mpstat 60 > "${LOG_DIR}/cpu_usage.log" 2>&1 &
CPU_MON_PID=$!
echo "cpu_monitor PID: ${CPU_MON_PID}"

# Memory usage monitor — free -m every 10 s
(while true; do
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="
    free -m
    echo
    sleep 10
done) > "${LOG_DIR}/mem_usage.log" 2>&1 &
MEM_MON_PID=$!
echo "mem_monitor PID: ${MEM_MON_PID}"

# Disk bandwidth monitor — iostat every 1 s for the target device
iostat -x -m -d -t 60 ${NVME_BLK} > "${LOG_DIR}/disk_bw.log" 2>&1 &
DISK_BW_PID=$!
echo "disk_bw_monitor PID: ${DISK_BW_PID}"
sleep 3

echo "--- Step 3/4: Parallel load→run pipelines ---"
capture_device_state "start" "${LOG_DIR}"

MYSQL_PIPELINE_PID=""
ROCKSDB_PIPELINE_PID=""

if [[ $RUN_MYSQL -eq 1 ]]; then
    cp /etc/my.cnf "${MYSQL_LOG_DIR}/"
    (
        echo "--- TPC-C load start at $(date '+%Y-%m-%d %H:%M:%S') ---"
        cd "${tpcc_dir}"
        ./load.sh ${DATABASE} ${WAREHOUSE}
        while ps -ef | grep -w tpcc_load | grep -v grep > /dev/null; do
            sleep 10
        done
        echo "--- TPC-C load done at $(date '+%Y-%m-%d %H:%M:%S') ---"

        echo "--- TPC-C run start ---"
        export LD_LIBRARY_PATH=/usr/local/mysql/lib
        "${tpcc_dir}/tpcc_start" -P ${DBPORT} -h ${DBHOST} -d ${DATABASE} -uroot \
                                  -w ${WAREHOUSE} -c ${CONNECTIONS} \
                                  -r ${WARMUP} -l ${TPCCTIME} \
                                  > "${MYSQL_LOG_DIR}/${MODE}_tpcc_w${WAREHOUSE}.log" 2>&1
        echo "TPC-C done at $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "${LOG_DIR}/finish_time.log"
    ) &
    MYSQL_PIPELINE_PID=$!
    echo "MySQL pipeline PID: ${MYSQL_PIPELINE_PID}"
fi

if [[ $RUN_ROCKSDB -eq 1 ]]; then
    sed -i "s/^recordcount=.*/recordcount=${LOAD_RECORD_COUNT}/" "${LOAD_CONFIG}"
    sed -i "s/^operationcount=.*/operationcount=${RUN_OPERATION_COUNT}/" "${LOAD_CONFIG}"
    cp "${LOAD_CONFIG}" "${ROCKSDB_LOG_DIR}/"
    cp "${OPTION}"      "${ROCKSDB_LOG_DIR}/"
    (
        echo "--- YCSB load start at $(date '+%Y-%m-%d %H:%M:%S') ---"
        ${YCSB} load rocksdb -s -P "${LOAD_CONFIG}" \
            -target ${ROCKSDB_TARGET_OPS} \
            -p rocksdb.dir="${YCSB_DIR}/" \
            -p rocksdb.optionsfile="${OPTION}" \
            -p rocksdb.sync=false \
            > "${ROCKSDB_LOG_DIR}/${MODE}_ycsb_load.log" 2>&1
        echo "--- YCSB load done at $(date '+%Y-%m-%d %H:%M:%S') ---"

        echo "--- YCSB run start ---"
        ${YCSB} run rocksdb -s -P "${LOAD_CONFIG}" \
            -target ${ROCKSDB_TARGET_OPS} \
            -p rocksdb.dir="${YCSB_DIR}/" \
            -p rocksdb.optionsfile="${OPTION}" \
            -p rocksdb.sync=false \
            > "${ROCKSDB_LOG_DIR}/${MODE}_ycsb_run.log" 2>&1
        echo "YCSB done at $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "${LOG_DIR}/finish_time.log"
    ) &
    ROCKSDB_PIPELINE_PID=$!
    echo "RocksDB pipeline PID: ${ROCKSDB_PIPELINE_PID}"
fi

echo "--- Waiting for pipelines to finish ---"
[[ -n "${MYSQL_PIPELINE_PID}"   ]] && wait "${MYSQL_PIPELINE_PID}"
[[ -n "${ROCKSDB_PIPELINE_PID}" ]] && wait "${ROCKSDB_PIPELINE_PID}"

#==============================================================================
# Step 5: Collect final state + cleanup
#==============================================================================

echo "--- Step 5: Collect final state ---"

# Stop all background monitors
kill ${MEASURE_PID}  2>/dev/null || \
    kill $(ps -ef | grep measure_dev | grep -v grep | awk '{print $2}') 2>/dev/null || true
kill ${RUAMW_PID}    2>/dev/null || true
kill ${WAF_MON_PID}  2>/dev/null || true
kill ${DISK_MON_PID} 2>/dev/null || true
kill ${CPU_MON_PID}  2>/dev/null || true
kill ${MEM_MON_PID}  2>/dev/null || true
kill ${DISK_BW_PID}  2>/dev/null || true

capture_device_state "end" "${LOG_DIR}"

if [[ $RUN_MYSQL -eq 1 ]]; then
    terminate_mysql
fi
sleep 5
umount ${NVME_BLK} 2>/dev/null || true

echo "=========================================="
echo "All done. Results: ${LOG_DIR}"
echo "Timestamp: ${ts}"
echo "=========================================="
