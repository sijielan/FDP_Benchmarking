# Building the FDP-enabled Linux kernel

- **OS:** CentOS 9
- **Kernel:** Linux 6.9 (tag `v6.9`)
- **Patch:** [`6.9.patch.txt`](6.9.patch.txt)

The patch adds NVMe Flexible Data Placement (FDP) support. File writes carry a write hint
(set with `fcntl(F_SET_RW_HINT)`), and the NVMe driver maps that hint to an FDP placement ID.
It is based on these upstream patches:

- NVMe FDP support: <https://lore.kernel.org/linux-nvme/20240510134015.29717-1-joshi.k@samsung.com/>
- ext4 FDP support: <https://lore.kernel.org/all/173099237654.321265.6588244483471280365.b4-ty@mit.edu/T/>

## Build

```bash
git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git checkout v6.9
git apply /path/to/6.9.patch.txt
```

Patch link: [`6.9.patch.txt`](6.9.patch.txt)

Then follow this guide to compile and install the kernel:
<https://www.linux.org/threads/compiling-your-own-linux-kernel-red-hat.48361/>
