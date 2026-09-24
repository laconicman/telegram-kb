# TD-22 — WAL growth during a backfill, measured

Empirical, run 2026-09-24 on this machine (macOS 26 / arm64, the real binaries —
`tgkb sync` writing, `tgkb-mcp` answering MCP calls in a second process, and a raw
`sqlite3` snapshot for the worst case). Channel: `@iosgr`, 4,411 posts over 225 pages,
`--delay 1`. The `-wal` size was polled once a second for the whole walk
(`wal.log`: 758 samples over 821 s).

## Verdict

**The hypothesised cost is real but narrower than feared — and the fix is a single
`checkpoint(.truncate)` at the end of a write session, not a mid-backfill cadence.**

Three arms:

1. **Realistic MCP reader — a `tgkb-mcp` process answering a continuous tool-call loop**
   (`search_posts` / `find_links` / `get_post`, ~20 calls/s, 6,978 calls over the run):
   the WAL **sawtooths** — grows to ~4–5.5 MB, then a passive autocheckpoint reclaims it
   down to ~0.3–1.3 MB. **19 checkpoint events**; the gaps between `dbPool.read`
   snapshots are enough. Short reads do not starve the checkpointer.

2. **Pinned snapshot — one `sqlite3` connection holding `BEGIN DEFERRED` for 240 s:**
   the starvation mechanism is real. Once pinned, no checkpoint could reclaim past the
   held frame and the WAL climbed to **44.3 MB** (≈10 KB/post). The writer was never
   blocked — WAL readers don't block writers — but nothing shrank the file until the
   snapshot released *and* a checkpoint ran.

3. **Residue after the writer exits:** the WAL stayed at 44.3 MB while `tgkb-mcp` held
   the database open, and survived `SIGTERM` kills of every reader (a killed process
   runs no close-checkpoint). It cleared only when the next writer — a one-page
   incremental sync — checkpointed on its way out: `-wal` → **0 bytes**, frames folded
   into the main file (19 MB → 27.6 MB).

So: mid-backfill growth under real readers is bounded; the unmanaged part is the
**residue**, which persists exactly as long as some reader keeps the file open — the
normal state while `tgkb-mcp` runs. Hence `Store.truncateWAL()`, deferred in
`Sync.run`: `SQLITE_BUSY` (a reader mid-snapshot) is tolerated, since the next
writer's checkpoint reclaims the residue anyway. `PERSIST_WAL` still owns the files;
only the contents are returned.
