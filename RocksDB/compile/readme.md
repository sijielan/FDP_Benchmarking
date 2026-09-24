# RocksDB + YCSB

- **OS:** CentOS 9
- **RocksDB:** v7.2.2
- **Patch:** [`rocksDB_patch.txt`](rocksDB_patch.txt)

The patch makes RocksDB pass per-level write hints to the kernel, which maps each hint to an FDP placement ID:

- `db/column_family.cc`: new SST write-hint mapping by level (L0–L3: medium, L4: long, deeper levels: extreme).
- `env/io_posix.cc`: passes the hint to `fcntl(F_SET_RW_HINT)` as a `uint64_t`, which the kernel expects.

## 1. Install dependencies

```bash
# JDK / JRE
sudo dnf install -y java-17-openjdk-devel

# Maven
sudo dnf install -y maven

# lz4
sudo dnf install -y lz4 lz4-libs
```

## 2. Get RocksDB and apply the patch

```bash
git clone git@github.com:facebook/rocksdb.git
cd rocksdb
git checkout v7.2.2
git apply /path/to/rocksDB_patch.txt
```

## 3. (Optional) Install TorFS and its dependencies

Only needed if you build with the TorFS plugin ([SamsungDS/TorFS](https://github.com/SamsungDS/TorFS)).

```bash
# TorFS: clone into the plugin/torfs directory of the RocksDB source tree
cd rocksdb
git clone git@github.com:SamsungDS/TorFS.git plugin/torfs
cd ..

# liburing
git clone https://github.com/axboe/liburing.git
cd liburing
./configure --cc=gcc --cxx=g++
make -j$(nproc)
sudo make install

# xNVMe: follow https://xnvme.io/getting_started/index.html#building-and-installing
git clone git@github.com:xnvme/xnvme.git
```

## 4. Build RocksDB Java (rocksdbjni)

```bash
DEBUG_LEVEL=0 ROCKSDB_DISABLE_JEMALLOC=true make -j32 rocksdbjava

# With TorFS:
# DEBUG_LEVEL=0 ROCKSDB_PLUGINS=torfs ROCKSDB_DISABLE_JEMALLOC=true make -j32 rocksdbjava
```

Copy the jar into the local Maven repository so YCSB picks it up:

```bash
mkdir -p ~/.m2/repository/org/rocksdb/rocksdbjni/7.2.2-linux64/
cp java/target/rocksdbjni-7.2.2-linux64.jar ~/.m2/repository/org/rocksdb/rocksdbjni/7.2.2-linux64/
```

## 5. Build YCSB

```bash
git clone https://github.com/brianfrankcooper/YCSB.git
cd YCSB
```

In `pom.xml`, set the RocksDB version to the jar built above:

```xml
<rocksdb.version>6.2.2</rocksdb.version>   <!-- before -->
<rocksdb.version>7.2.2-linux64</rocksdb.version>   <!-- after -->
```

Then build the RocksDB binding:

```bash
mvn -pl site.ycsb:rocksdb-binding -am clean package
tar zxvf rocksdb/target/ycsb-rocksdb-binding-0.18.0-SNAPSHOT.tar.gz
```
