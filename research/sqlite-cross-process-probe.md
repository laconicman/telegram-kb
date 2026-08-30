# Cross-process SQLite probe — can `tgkb-mcp` read while `tgkb` writes?

Empirical, run by me on 2026-08-23 on this machine (macOS 26 / Darwin 25.5, system SQLite
3.51.0, Python's `sqlite3` against the same system library). This tests the **SQLite layer**
that brief §2's two-executable split rests on. GRDB-layer specifics are in `grdb-fts5.md`.

Scripts: `scratchpad/xproc/{writer,reader}.py` (research probes, not shipped code).

---

## Verdict

**The two-executable split is safe at the storage layer, with one deployment trap that must be
designed around rather than discovered in production.**

A separate reader process sees a concurrent writer's commits promptly, monotonically, and with
zero errors, and FTS5 queries work normally from a read-only connection. That is the load-
bearing assumption of §2 and it holds.

The trap: **`mode=ro` is not enough.** A read-only connection to a WAL database still needs to
*create* the `-shm` shared-memory file, so it fails with `attempt to write a readonly database`
whenever the containing **directory** is not writable — even though the caller only wants to
read. This is a property of WAL, not of our code, and it will bite exactly when the MCP server
is run under tighter permissions than the CLI that created the database.

---

## Verified

### Concurrent writer + read-only reader, separate processes

Writer: 60 inserts, one commit each, 50 ms apart. Reader: 60 independent read-only
connections, each running an FTS5 `MATCH` query, 50 ms apart, started 300 ms after the writer.

```
writer: done, 60 rows
reader: ok=60 fail=0 saw 6..60 monotonic=True
```

- **60/60 reads succeeded. Zero `SQLITE_BUSY`, zero errors.**
- The reader observed counts rising 6 → 60 **monotonically** — it sees committed data as it
  lands, and never went backwards.
- **FTS5 `MATCH` (including Cyrillic prefix `навигац*`) works from a `mode=ro` connection in a
  different process.** No tokenizer registration was needed for the built-in tokenizers.

### The read-only trap — `mode=ro` vs `immutable=1`

With a WAL database and the **directory** made non-writable:

| Open mode | Result |
|---|---|
| `file:kb.sqlite?mode=ro` | **FAILED — `attempt to write a readonly database`** |
| `file:kb.sqlite?immutable=1` | **OK** — 61 rows read |

`mode=ro` promises not to write *the database*; it does not exempt the connection from creating
the `-shm` file WAL requires. `immutable=1` does, by promising the file cannot change — which is
**only sound if no writer is running**, and silently returns stale or corrupt reads if one is.
So `immutable=1` is *not* a general fix; it is a fallback for a genuinely frozen snapshot.

Practical consequence for us: **the MCP process needs write permission on the directory holding
the database, despite being a logically read-only component.** Document it, and have
`tgkb doctor` check it explicitly — the error message names the *database* as readonly, which
points the reader at the wrong file and wastes their time.

**Reconciliation with GRDB's own guidance** (see `grdb-fts5.md`): GRDB's `DatabaseSharing.md`
states that "Read-only connections will fail unless two extra files ending in `-shm` and `-wal`
are present", and prescribes that the **writer** set `SQLITE_FCNTL_PERSIST_WAL` so those files
survive after it closes. At first reading that contradicts my Test 1, where a cleanly-closed
database with no `-wal`/`-shm` opened read-only without complaint. It does not — the two
describe the same mechanism from opposite ends:

- SQLite must **create** `-shm` to open a WAL database, even read-only.
- If the directory is writable (my Test 1), it creates them and succeeds.
- If the directory is not (my trap test), it cannot, and fails.
- `PERSIST_WAL` sidesteps the question by ensuring the files already exist.

So there are **two independent mitigations, and they are not alternatives — take both**:
set `PERSIST_WAL` on the writer *and* keep the directory writable. Either alone leaves a live
failure path, and the failure is intermittent (it depends on whether a sync is in flight), which
makes it precisely the sort of bug that survives to production.

### Crash recovery

Writer killed with `SIGKILL` mid-session, leaving `-wal` and `-shm` behind. A subsequent
read-only open succeeded and returned all committed rows (62), including the row committed
immediately before the kill. **A hard-killed sync does not require manual recovery.**

### Journal-mode file lifecycle

`-wal` and `-shm` are removed when the last connection closes cleanly, and recreated on next
write. A reader that opens between sync runs therefore sees a plain single file; one that opens
during a sync sees all three. Both work — but it means *the failure above is intermittent by
nature*, appearing only when a sync happens to be in flight or was killed. That is the worst
kind of bug to leave for later, which is why it is worth pinning now.

---

## Unverified

- **GRDB's own stance and API surface** for this scenario — its `Configuration`, `busyTimeout`
  defaults, and whether it documents a caveat against multi-process use. That is the GRDB
  agent's question, and its answer governs; my results only establish that the *underlying
  engine* permits this.
- ~~**Custom `FTS5WrapperTokenizer` across processes.**~~ **Now answered** — probed
  independently at the GRDB layer (see `grdb-fts5.md`): a connection that has *not* registered
  the tokenizer opens the file, reads unrelated tables, and even runs a plain `SELECT` against
  the FTS5 table without complaint — but `MATCH` and `INSERT` fail at *step* time with
  `no such tokenizer: …`. So it is survivable if both executables register the same tokenizer
  from a shared module. **I still recommend against it for v1**, and the reason is not the loud
  error but the quiet one: on version skew the two processes tokenise *differently*, and the
  index silently disagrees with the query. The dual `unicode61` + `trigram` schema reaches the
  same recall with no such failure mode.

- **Scale.** 60 rows and 60 reads. Nothing here speaks to a 100k-post index, WAL growth under a
  long backfill, or checkpoint starvation when a reader holds a long transaction.
- **`busy_timeout` tuning.** I set 5 s on both sides and never hit contention, so the value was
  never exercised. Under a real backfill it will be.
- Behaviour on network/dispatched filesystems (iCloud Drive, NFS). SQLite is known to be unsafe
  on some of these. `~/Library/Application Support/` is local, so this is only a hazard if a
  user relocates the database — worth a `doctor` warning.

---

## Consequences for the design

1. **§2's split is sound at this layer.** Reader and writer in separate processes is a normal,
   well-supported SQLite deployment, not a workaround.
2. **Open the reader `mode=ro` and require a writable directory**; do not reach for
   `immutable=1` as a default — it trades a loud failure for a silent one.
3. **`tgkb doctor` should check directory writability**, because SQLite's error text misdirects.
4. **Set `SQLITE_FCNTL_PERSIST_WAL` on the writer** *and* require a writable directory. Both.
5. **Avoid custom tokenizers in v1.** They work cross-process only if both binaries register an
   identical tokenizer, and the failure mode on drift is a silently wrong index rather than an
   error. Dual-index instead.
