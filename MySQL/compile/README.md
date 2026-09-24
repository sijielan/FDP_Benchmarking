# MySQL (Percona Server)

- **OS:** CentOS 9
- **Source:** [percona/percona-server](https://github.com/percona/percona-server), tag `Percona-Server-8.0.34-26`
- **Patch:** [`percona-mysql-8.patch.txt`](percona-mysql-8.patch.txt)
- **Boost:** 1.77.0

The patch makes InnoDB set a write hint on its files with `fcntl(F_SET_RW_HINT)`, so the kernel can map each file type to an FDP placement ID:

| File                                             | Hint           |
| ------------------------------------------------ | -------------- |
| Doublewrite buffer (`buf0dblwr.cc`)              | `WLTH_SHORT`   |
| Tablespace `.ibd` files (`fil0fil.cc`)           | `WLTH_LONG`    |
| Temporary tablespace `.ibt` files (`fil0fil.cc`) | `WLTH_NOT_SET` |

## 1. Get the source and apply the patch

```bash
git clone https://github.com/percona/percona-server.git
cd percona-server
git checkout Percona-Server-8.0.34-26
git submodule update --init
git apply /path/to/percona-mysql-8.patch.txt
```

## 2. Build and install

Download Boost 1.77.0 first (or let CMake fetch it with `-DDOWNLOAD_BOOST=1`).

```bash
cmake -DWITH_BOOST=/path/to/boost_1_77_0 \
      -DCMAKE_C_COMPILER=/usr/bin/gcc \
      -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
      -DFORCE_INSOURCE_BUILD=1


make -j8
sudo make install          # installs to /usr/local/mysql
```
