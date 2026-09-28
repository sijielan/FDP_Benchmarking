# Running the RocksDB experiments

Build steps, run scripts, and workload configs for the RocksDB experiments (YCSB and db_bench), on XFS or on TorFS.

```
RocksDB/
├── compile/     RocksDB v7.2.2 write-hint patch and build steps (rocksdbjni + YCSB)
├── scripts/     run scripts + monitors
├── workloads/   YCSB workload files and the RocksDB OPTIONS file
└── TorFS/       TorFS plugin (git submodule)
```

## Scripts

| Script | What it runs | File system | Modes |
|---|---|---|---|
| `single_testYcsb_xfs.sh` | YCSB workload A (40M records load, 200M ops run) | XFS, `mount -o discard` | FDP, then Conv., in one invocation |
| `single_testYcsb.sh` | YCSB workload E (40M records load, 50M ops run) | XFS, `mount -o discard` | FDP, then Conv., in one invocation |
| `single_testYcsb_torfs.sh` | YCSB workload A (40M / 200M) | TorFS on the raw char device | FDP only |
| `single_testDBbench.sh` | db_bench `fillrandom`, 200M keys × 10 KiB values, 32 threads, no WAL, no compression | XFS or TorFS | one mode per invocation: `fdp`, `nofdp`, `torfs` |

The three YCSB scripts are the same script with different defaults (`WORKLOAD_TYPE`, `RUN_OPERATION_COUNT`, `ENABLE_TORFS_MODE`),
which are set at the top of each file:

| Variable | Meaning |
|---|---|
| `WORKLOAD_TYPE` | Picks `workloads/workload<type>` (`a` or `e`) |
| `LOAD_RECORD_COUNT` | Records inserted in the load phase (written into the workload file with `sed -i`) |
| `RUN_OPERATION_COUNT` | Operations in the run phase (written into the workload file with `sed -i`) |
| `ENABLE_TORFS_MODE` | `true`: RocksDB on TorFS, no file system, Conv. round skipped |

Monitors started by the run scripts:

| Script | Output |
|---|---|
| `measure_dev` (**not included** in this repository) | WAF every `INTERVAL` (600 s) → `<mode>_waf.stat` |
| `getDfAndNvme.sh` | NVMe used bytes and `df` used KB every 600 s → `<mode>_cap.stat` |
| `getRUHWrite.sh` | Writes and reclaim-unit resets per placement ID every 5 s → `RUH_Write.stat` (FDP only) |
| `disk_monitor.sh` | `df` of `/mnt/test` (or `nvme list` in TorFS mode) every 120 s |
| `waf_monitor.sh` | Standalone WAF monitor (smart-log + OCP log); not called by the run scripts, can replace `measure_dev` |

`workloads/workloade/RUH_Write.stat` is example output of `getRUHWrite.sh` from a workload E run.

## Requirements

- Linux (patched 6.9 kernel from [`../kernel_compile`](../kernel_compile)), root, an FDP-capable NVMe SSD with 8 placement IDs.
- `nvme-cli` with `fdp` support, `xfsprogs`, `psmisc` (`fuser`).
- The patched RocksDB v7.2.2, built as described in [`compile/readme.md`](compile/readme.md):
  - YCSB: the `rocksdbjni` jar and the YCSB RocksDB binding. For `single_testYcsb_torfs.sh`, build the jar with `ROCKSDB_PLUGINS=torfs`.
  - db_bench: also build db_bench in the same source tree:
    ```bash
    DEBUG_LEVEL=0 ROCKSDB_DISABLE_JEMALLOC=true make -j32 db_bench
    # With TorFS (needed for the torfs mode):
    DEBUG_LEVEL=0 ROCKSDB_PLUGINS=torfs ROCKSDB_DISABLE_JEMALLOC=true make -j32 db_bench
    ```
- The mount point `/mnt/test` must exist.

## Configure

The scripts contain paths and device values from the original test machine. Edit them at the top of each script:

| Setting | Where | Set it to |
|---|---|---|
| `BASE_PATH` | YCSB scripts | Extracted YCSB binding, e.g. `.../YCSB/ycsb-rocksdb-binding-0.18.0-SNAPSHOT` |
| `REPO_BASE` | all scripts | Working directory (layout below); results go to `${REPO_BASE}/results/` |
| `ROCKSDB_PATH` | `single_testDBbench.sh` | RocksDB source tree containing `db_bench` |
| `FW` | all scripts | Firmware revision of your SSD (`FW Rev` column of `nvme list`). The scripts find the device with `nvme list \| grep nvme<N> \| grep $FW`, so a wrong value means no device is found. |
| `-c 7` | `nvme attach-ns` / `detach-ns` calls | Your controller ID (`nvme id-ctrl /dev/nvme<N> \| grep cntlid`) |
| `MAX_RUAMW` | `getRUHWrite.sh` | Detected from the model for the four PM9D3a models listed in the script; for other SSDs pass it as the 2nd argument (from `nvme fdp status`) |

The YCSB scripts expect this layout under `REPO_BASE`, and are run from a directory that also holds the monitors:

```
${REPO_BASE}/
├── OPTIONS-000009                     <- workloads/workloada/OPTIONS-000009 (A and E use the same file)
├── workloads/workloada                <- workloads/workloada/workloada
├── workloads/workloade                <- workloads/workloade/workloade
├── single_testYcsb.sh (and the _xfs / _torfs variants)   <- scripts/
├── getDfAndNvme.sh  getRUHWrite.sh  disk_monitor.sh       <- scripts/
└── measure_dev                                            (not included)
```

`single_testDBbench.sh` calls the monitors as `./tools/<name>` instead, so put them in a `tools/` directory next to it.

## Run

> **Warning:** the scripts `nvme format` the device, delete and recreate namespace 1, run `mkfs.xfs`, and mount it at `/mnt/test`.
> Only run them on a dedicated test drive.

The argument is the NVMe **controller** number (`/dev/nvme<N>`); the scripts always use namespace 1.

**YCSB** (FDP and Conv. back to back):

```bash
cd ${REPO_BASE}
sudo ./single_testYcsb_xfs.sh 2      # workload A on /dev/nvme2
sudo ./single_testYcsb.sh 2          # workload E on /dev/nvme2
sudo ./single_testYcsb_torfs.sh 2    # workload A on TorFS, FDP only
```

For each mode the script formats the device, recreates the namespace with FDP on (8 placement IDs) or off,
starts the monitors, creates the file system (XFS only), runs `ycsb load` and then `ycsb run` with `OPTIONS-000009`,
and stops the monitors. A run stops with an error if its results directory already exists; delete it or change the counts to rerun.

**db_bench** (one mode per invocation):

```bash
sudo ./single_testDBbench.sh 2 fdp     # XFS, FDP on
sudo ./single_testDBbench.sh 2 nofdp   # XFS, Conv.
sudo ./single_testDBbench.sh 2 torfs   # TorFS on /dev/ng2n1, FDP on
```

After `fillrandom` finishes, the script waits for all background compactions before stopping the monitors.

## Results

| Run | Directory |
|---|---|
| YCSB | `${REPO_BASE}/results/WL<type>_LOAD_<n>M_RUN_<m>M_SMRC31_{base,BASE}_256/{xfs,torfs}/` |
| db_bench | `${REPO_BASE}/results/DB_BENCH_fillrandom/{fdp,nofdp,torfs}/` |

YCSB files are prefixed `fdp_` or `nofdp_`/`nfdp_` (Conv.):

| File | Content |
|---|---|
| `fdp_load.log`, `fdp_run.log` (and `nofdp_*`) | YCSB throughput and latency percentiles |
| `fdp_waf.stat`, `nfdp_waf.stat` | WAF over time from `measure_dev` |
| `fdp_cap.stat`, `nfdp_cap.stat` | NVMe vs file-system used capacity |
| `RUH_Write.stat` | Per-RUH writes and reclaim-unit resets (FDP only) |
| `workload<type>`, `OPTIONS-000009`, `single_testYcsb.sh` | Copies of the configs used |

db_bench writes `<fdp|nfdp>_fillrandom_max_waf.log` (throughput, compaction stats, level stats), `<fdp|nfdp>_waf.stat`,
`<fdp|nfdp>_cap.stat`, `<fdp|nfdp>_disk_usage.log`, and `timeline.log`.
