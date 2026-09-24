# Sec 3.4 Hot/cold data isolation (prefill) experiment: fio scripts

These scripts are for paper section §`sec:microbench:hot-cold` (RUH Isolation With Mixed Hot and Cold Data) and figure `../waf_compare_line.pdf` (x-axis: prefill ratio *p*, y-axis: WAF).

The scripts were **rewritten** from the paper text. They are not the job files used in the original experiment. See the last section for where the original data came from.

## Procedure

For each prefill level *p* ∈ {50, 75, 80, 90, 99}%, run once with FDP and once with Conv. Each run has three stages, executed in order:

| Stage | File | Writes | RUH under FDP |
|---|---|---|---|
| 1. Precondition | `precondition_{fdp,nofdp}.fio` | 128K sequential write of the whole device, 3 times (`loops=3`) | `fdp_pli=0` (cold) |
| 2. Prefill (cold data) | `prefill<p>/{fdp,nofdp}/prefill.fio` | 128K sequential write of LBA [0, *p*), once | `fdp_pli=0` (cold) |
| 3. Hot random write | `prefill<p>/{fdp,nofdp}/hot_randwrite.fio` | 128K random write to LBA [*p*, 100%) until 10× the device capacity (~38.4 TB) has been written | `fdp_pli=1` (hot, dedicated) |

```bash
# Example: prefill 90%, FDP
fio precondition_fdp.fio
fio prefill90/fdp/prefill.fio
# Start measuring device writes here (measure_dev / nvme fdp stats); the WAF in the figure covers stage 3 only
fio prefill90/fdp/hot_randwrite.fio
```

Every *p* starts again from stage 1 ("before each experiment" in the paper).

## Parameters

| Parameter | Value |
|---|---|
| ioengine | `io_uring_cmd` (`cmd_type=nvme`) |
| bs / iodepth | 128K / 256 (same for all three stages) |
| Device | FDP: `/dev/ng1n1` (`fdp=1`); Conv.: `/dev/ng0n2` (`fdp=0`, `fdp_pli` commented out) |
| Stage 3 write amount | `io_size=38407559823360`, i.e. 10× the 3.84 TB device (3,840,755,982,336 bytes). This is the same for every *p*, so smaller hot regions are rewritten more times. |
| Logs | Only stage 3 writes `prefill_hot_{bw,lat,iops}` logs, `log_avg_msec=60000`, to the current directory |

Hot region size for each *p* on the 3.84 TB device:

| *p* | Hot region | Stage 3 writes | Times the hot region is rewritten |
|---|---|---|---|
| 50% | 1.92 TB | 38.4 TB | ~20 |
| 75% | 0.96 TB | 38.4 TB | ~40 |
| 80% | 0.77 TB | 38.4 TB | ~50 |
| 90% | 0.38 TB | 38.4 TB | ~100 |
| 99% | 38 GB | 38.4 TB | ~1000 |

## Where the data in the current figure comes from (`../waf.stat`)

- **Conv. column**: the `WAF_FROM_START` value (cumulative WAF over the whole run) in the last row of `Data/rocksDB/fdp_evaluation/fio_eval/logs/prefill/write_fixsize/prefill<p>/randome/nofdp/…/waf_measurements.csv`. The 50/75/80/90% values match the original files digit for digit.
  - **The 99% value has a typo**: the original is `2.4057031562573465`, but `waf.stat` has `2.5057031562573465` (only the first decimal digit differs).
- **FDP column** (1.01 / 1.01 / 1.05 / 1.05 / 2.43): entered by hand with two decimal places; no matching original run exists in the repository. The FDP runs under `prefill/…/randome/fdp/` use prefill ratios of 8/12/13/15/16%, not 50–99%, and their cumulative WAF does not match either.
- The original experiment used different parameters: a single job, **bs=4K, iodepth=32**; Conv. ran on `/dev/ng0n1`; the hot-region offset/size were passed on the command line by the test script and were not recorded in any job file. Results from these new scripts should not be plotted together with the old data.
