# FDP Benchmarking Artifact

Scripts, patches and build instructions for the experiments on NVMe Flexible Data Placement (FDP) SSDs.

Clone with the TorFS submodule:

```bash
git clone --recurse-submodules <this-repo-url>
```

## Contents

| Folder                              | What it contains                                                                                                                                                                    |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`kernel_compile/`](kernel_compile) | Linux 6.9 kernel patch that passes file write hints to FDP placement IDs, and how to build it                                                                                       |
| [`fio_scripts/`](fio_scripts)       | fio job files for the microbenchmarks (Sec 3.1–3.5)                                                                                                                                 |
| [`RocksDB/`](RocksDB)               | RocksDB v7.2.2 patch and build steps ([`compile/`](RocksDB/compile)), db_bench / YCSB workloads, monitoring scripts, and [TorFS](https://github.com/SamsungDS/TorFS) as a submodule |
| [`MySQL/`](MySQL)                   | Percona Server patch and build steps ([`compile/`](MySQL/compile)), and TPC-C run scripts ([`how_to_run/`](MySQL/how_to_run))                                                       |

## Environment

- CentOS 9
- Experiments were conducted on three Samsung PM9D3a FDP SSDs with capacities of 1.88 TB, 3.84 TB, and 7.68 TB
- The patched Linux 6.9 kernel from [`kernel_compile/`](kernel_compile)

## Getting started

1. Build and boot the patched kernel: [`kernel_compile/README.md`](kernel_compile/README.md)
2. Run the fio microbenchmarks in [`fio_scripts/`](fio_scripts)
3. Build RocksDB / MySQL and run the application experiments: see the README in each folder

**Warning:** the scripts write to raw NVMe devices and may format them or recreate namespaces. Only run them on a dedicated test drive.
