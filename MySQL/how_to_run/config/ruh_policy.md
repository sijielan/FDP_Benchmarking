# RUH / Write Hint Policy History

Percona Server 8.0.36-28 (`/home/fdp-research/percona-server-8.0.36-28`), FDP write-hint mapping.

## Hint assignment points

| # | File | Location | Meaning |
|---|---|---|---|
| A | `storage/innobase/buf/buf0dblwr.cc:2731` | `dblwr_file_open()` | doublewrite buffer |
| B | `storage/innobase/log/log0files_io.cc:283` | `Log_file_handle::open()` | redo log |
| C | `storage/innobase/fsp/fsp0file.cc:107` | `Datafile::open_or_create()` | system tablespace / meta |
| D | `storage/innobase/fil/fil0fil.cc:5796` | `fil_ibd_create()` | user table (on create) |
| E | `storage/innobase/fil/fil0fil.cc:5805` | `fil_ibt_create()` | session temp (on create) |
| F | `storage/innobase/fil/fil0fil.cc:2990` | `open_file()` reopen branch | system tablespace / meta (reopen) |
| G | `storage/innobase/fil/fil0fil.cc:2993` | `open_file()` reopen branch | global + session temp (reopen) |
| H | `storage/innobase/fil/fil0fil.cc:2995` | `open_file()` reopen branch | undo tablespace (reopen) |
| I | `storage/innobase/fil/fil0fil.cc:2997` | `open_file()` reopen branch | user table (reopen) |

D/I are the same category (user table), E/G are the same (temp), and C/F are the same (meta). Each pair must use the same hint.

## Policy 1 (before 2026-08-01)

| Category | Hint | Points |
|---|---|---|
| user table | `WLTH_EXTREME` | D, I |
| doublewrite buffer | `WLTH_SHORT` | A |
| redo log | `WLTH_MEDIUM` | B |
| temp (session + ibtmp1) | `WLTH_LONG` | E, G |
| meta (system tablespace) | `WLTH_NONE` | C, F |
| undo | `WLTH_S` | H |

## Policy 2 (applied 2026-08-01)

| Category | Hint | Points |
|---|---|---|
| user table | `WLTH_EXTREME` | D, I |
| doublewrite buffer | `WLTH_SHORT` | A |
| redo log | `WLTH_MEDIUM` | B |
| temp (session + ibtmp1) | `WLTH_MEDIUM` | E, G |
| meta (system tablespace) | `WLTH_NONE` | C, F |
| undo | `WLTH_S` | H |

Difference from Policy 1: only E and G change from `WLTH_LONG` to `WLTH_MEDIUM`.

## Policy 3 (current, applied 2026-08-04)

| Category | Hint | Points |
|---|---|---|
| user table | `WLTH_EXTREME` | D, I |
| doublewrite buffer | `WLTH_SHORT` | A |
| redo log | `WLTH_NONE` | B |
| temp (session + ibtmp1) | `WLTH_NONE` | E, G |
| meta (system tablespace) | `WLTH_NONE` | C, F |
| undo | `WLTH_NONE` | H |

Difference from Policy 4: only A changes back from `WLTH_NONE` to `WLTH_SHORT` (B, C, D, E, F, G, H, I unchanged).

## Policy 4 (applied 2026-08-03, replaced by Policy 3)

| Category | Hint | Points |
|---|---|---|
| user table | `WLTH_EXTREME` | D, I |
| doublewrite buffer | `WLTH_NONE` | A |
| redo log | `WLTH_NONE` | B |
| temp (session + ibtmp1) | `WLTH_NONE` | E, G |
| meta (system tablespace) | `WLTH_NONE` | C, F |
| undo | `WLTH_NONE` | H |

User tables keep `WLTH_EXTREME`; everything else (doublewrite/log/temp/meta/undo) is `WLTH_NONE`.
Difference from Policy 2: A, B, E, G and H all change to `WLTH_NONE` (C, D, F, I unchanged).

## Switching policies

Set points A–I to the values in the target policy's table, then rebuild and redeploy as shown below.

Example: Policy 4 → Policy 3 (already applied), one change:
- A (`buf0dblwr.cc:2731`): `WLTH_NONE` → `WLTH_SHORT`

Example: Policy 4 → Policy 2, change back:
- A (`buf0dblwr.cc:2731`): `WLTH_NONE` → `WLTH_SHORT`
- B (`log0files_io.cc:283`): `WLTH_NONE` → `WLTH_MEDIUM`
- E (`fil0fil.cc:5805`): `WLTH_NONE` → `WLTH_MEDIUM`
- G (`fil0fil.cc:2993`): `WLTH_NONE` → `WLTH_MEDIUM`
- H (`fil0fil.cc:2995`): `WLTH_NONE` → `WLTH_S`

Policy 4 → Policy 1: same as above, but set E/G to `WLTH_LONG` instead of `WLTH_MEDIUM`.

## Rebuild / deploy

```bash
cd /home/fdp-research/percona-server-8.0.36-28
make -j$(nproc) mysqld
sudo make install   # or: sudo cp runtime_output_directory/mysqld /usr/local/mysql/bin/mysqld
```

Restart mysqld afterwards for the change to take effect.
