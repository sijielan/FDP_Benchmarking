# Running the fio microbenchmarks (Sec 3.1–3.5)

fio job files for the microbenchmarks, plus one driver script that resets the SSD, runs a job, and records WAF.

```
fio_scripts/
├── scripts/
│   ├── run_single_test.sh     driver: reset device -> start monitors -> run fio -> compute WAF
│   └── tools/
│       ├── set_dev.sh         delete all namespaces, enable/disable FDP, create + attach one namespace
│       ├── waf_monitor.sh     WAF every 10 min from smart-log (host) and OCP smart-add-log (NAND)
│       └── getRUHWrite.sh     per-RUH (placement ID 0–7) writes every 5 s, FDP only
├── sec_3.1_sequentual_workloads/        8 sequential writers, even / uneven LBA split
├── sec_3.2share_Sequential_Workloads/   8/16/32/64 sequential writers sharing 8 RUHs
├── sec_3.3_varyrandom/                  8 writers, mix of sequential / random (8S, 7S1R, 6S2R, 4S4R, 8R)
├── sec_3.4prefill/                      hot/cold isolation, prefill 50–99% (see its own README)
├── sec_3.5skewness/                     uniform + Zipf regions, 3 splits x 5 skews
└── Appendix/Homogeneous_Heterogeneous_RUH/
    ├── fio_scripts/                     24/32/48/64 jobs on 8 RUHs, equal vs. mixed job sizes per RUH
    └── raw_data/                        results of those runs
```

Every experiment has an FDP and a Conv. job file (`*_fdp.fio` / `*_nofdp.fio`, or `fdp.fio` / `nofdp.fio`).
The only difference is `fdp=1` + `fdp_pli=<n>` vs `fdp=0`.

## Experiments

| Section | Job files | Workload | Stop condition |
|---|---|---|---|
| 3.1 | `8_seq_{even,uneven}_{fdp,nofdp}.fio` | 8 jobs, 128K seq write, iodepth 256; job *i* → `fdp_pli=i-1`. Even: 8 equal LBA ranges. Uneven: 2/5/8/11/14/17/20/23% of the device | `runtime=8h` |
| 3.2 | `wl{8,16,32,64}_{fdp,nofdp}.fio` | 8/16/32/64 seq-write jobs, 128K, iodepth 256, placed on 8 RUHs | `runtime=8h` |
| 3.3 | `<mix>/{fdp,nofdp}.fio`, mix ∈ `8S 7S1R 6S2R 4S4R 8R` | Same 8 uneven ranges as 3.1; the first *k* jobs are `randwrite` | `runtime=8h` |
| 3.4 | `precondition_*.fio`, `prefill<p>/{fdp,nofdp}/{prefill,hot_randwrite}.fio` | 3 stages, see [`sec_3.4prefill/fio_scripts/README.md`](sec_3.4prefill/fio_scripts/README.md) | 10× device capacity written in stage 3 |
| 3.5 | `zipf<θ>_p<AB>_{fdp,nofdp}.fio`, θ ∈ `0.6 0.8 1 1.2 1.4`, AB ∈ `2080 5050 8020` | 4K randwrite, iodepth 64. First A% of LBAs uniform (`fdp_pli=0`), last B% Zipf θ (`fdp_pli=1`; `zipf1` uses `zipf:0.99`) | `runtime=8h` |
| Appendix | `wl{24,32,48,64}_{nofdp,fdp_homogeneous,fdp_heterogeneous}.fio` | 24–64 seq-write jobs on 8 RUHs; homogeneous = equal-size jobs per RUH, heterogeneous = same jobs regrouped so each RUH mixes sizes. See [`Appendix/Homogeneous_Heterogeneous_RUH/fio_scripts/README.md`](Appendix/Homogeneous_Heterogeneous_RUH/fio_scripts/README.md) | `runtime=4h` |

All files assume a 3.84 TB device (937,684,566 × 4 KiB LBAs); the LBA ranges are given as percentages, so they scale to other sizes.

## Requirements

- Linux (patched 6.9 kernel from [`../kernel_compile`](../kernel_compile)), root, an FDP-capable NVMe SSD.
- fio with `io_uring_cmd` and FDP support (`fdp=`, `fdp_pli=`). The script uses `/usr/local/bin/fio` if present, otherwise `fio` on `PATH`.
- `nvme-cli` with `fdp` and `ocp` plugins, `jq`, `python3`, `sysstat` (`mpstat`).
- `tools/set_dev.sh` picks the number of placement IDs from the SSD model (8 for `MZWL63T8HFLT-00AAZ`, `MZOL67T6HBLC-01AFB`; 7 for `MZOL63T8HDLT-00AFB`, `MZOL61T9HDLT-00AFB`). For another model, set `PHNDLS` / `NPHNDLS` in the environment.
- `tools/getRUHWrite.sh`: `MAX_RUAMW` defaults to `4349952` and is device-specific; set it from `nvme fdp status` on your SSD.
- `run_single_test.sh` also starts `tools/measure_dev`, which is **not included** in this repository. Without it the run still completes; the error goes to `measure_dev_error.log`, and WAF comes from `waf_result.json` and `ocp_waf_measurements.csv` instead.

## Before running

**1. Point the job file at your device.** The driver reads the target from the job's `filename=` line (`/dev/ng<ctrl>n<ns>`)
and resets that controller. The job files currently use `/dev/ng1n1`, `/dev/ng0n2` (some Conv. files) or `/dev/ng0n1` (Sec 3.5).
`set_dev.sh` deletes all namespaces and creates one new one, which is normally namespace 1, so use `/dev/ng<ctrl>n1`:

```bash
# e.g. SSD is /dev/nvme2
sed -i 's#^filename=.*#filename=/dev/ng2n1#' path/to/job.fio
```

**2. Put the job under an `fdp/` or `cns/` directory.** `run_single_test.sh` decides whether to enable FDP from the job path,
not from the file name, so it rejects paths like `.../8_seq_even_fdp.fio`. Copy the jobs you want to run into `fdp/` and `cns/`:

```bash
cd scripts
mkdir -p jobs/fdp jobs/cns
cp ../sec_3.1_sequentual_workloads/metadata/fio_scripts/8_seq_even_fdp.fio   jobs/fdp/
cp ../sec_3.1_sequentual_workloads/metadata/fio_scripts/8_seq_even_nofdp.fio jobs/cns/
```

Keep each job's FDP setting consistent with the directory: `*fdp*` files (`fdp=1`) go to `fdp/`, `*nofdp*` files (`fdp=0`) go to `cns/`.

## Run (Sec 3.1, 3.2, 3.3, 3.5)

> **Warning:** `set_dev.sh` deletes every namespace on the controller and recreates it. Only run this on a dedicated test drive.

Run from `scripts/` (it calls `./tools/...` by relative path), once per job file:

```bash
cd scripts
sudo ./run_single_test.sh -j jobs/fdp/8_seq_even_fdp.fio
sudo ./run_single_test.sh -j jobs/cns/8_seq_even_nofdp.fio
```

For each run the script:

1. Recreates the namespace with FDP on (`fdp/`) or off (`cns/`) and deallocates the whole namespace.
2. Reads FDP stats (host / media bytes written) before the run (FDP only).
3. Starts the monitors: `waf_monitor.sh`, `mpstat`, write/read bandwidth from `smart-log`, and `getRUHWrite.sh` (FDP only).
4. Runs fio (8 h for these sections), stops the monitors, and reads FDP stats again to compute the WAF.

## Run (Sec 3.4 prefill)

Sec 3.4 runs three fio jobs back to back on the same namespace, so do not use `run_single_test.sh` (it would reset the device
before every job). Reset once with `set_dev.sh`, then run the stages by hand and measure only stage 3:

```bash
cd scripts
sudo ./tools/set_dev.sh -d /dev/nvme2 -f 1            # -f 0 for Conv.

cd ../sec_3.4prefill/fio_scripts
sudo fio precondition_fdp.fio                          # stage 1: full-device seq write x3
sudo fio prefill90/fdp/prefill.fio                     # stage 2: cold data, LBA [0, 90%)

# stage 3: start the WAF monitor, then write 10x device capacity to the hot region
sudo ../../scripts/tools/waf_monitor.sh /dev/nvme2 9999 10 prefill90_fdp_waf.csv &
sudo fio prefill90/fdp/hot_randwrite.fio
sudo pkill -f waf_monitor.sh
```

Repeat from `set_dev.sh` for every prefill level (50, 75, 80, 90, 99) and for Conv. (`-f 0`, `precondition_nofdp.fio`, `prefill<p>/nofdp/`).
The WAF for the figure is the last `WAF_FROM_BEGIN` value in the CSV.

## Results

Each `run_single_test.sh` run writes to `scripts/logs/<timestamp>_<fdp|cns>_<dir>_<job>/`:

| File | Content |
|---|---|
| `waf_result.json` | WAF over the whole run from `nvme fdp stats` (media bytes / host bytes), FDP only |
| `ocp_waf_measurements.csv` | WAF every 10 min (`WAF_INTERVAL`) and cumulative (`WAF_FROM_BEGIN`) |
| `ruh_writes.csv` | Writes and reclaim-unit resets per placement ID every 5 s, FDP only |
| `io_bandwidth.log`, `cpu_util.log` | Device write/read MiB/s and CPU utilization every 30 s |
| `fio_logs/` | fio output and the bw / lat / iops logs (1-minute averages) |
| `test.log`, `metadata.json`, `*.fio` | Run log, device info, and a copy of the job file |
