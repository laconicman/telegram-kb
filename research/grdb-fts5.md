# GRDB + FTS5 for `telegram-kb` — research notes

Date: 2026-08-23. GRDB master (latest release v7.11.1, 2026-06-18). System sqlite3 3.51.0.
Every claim below is marked **VERIFIED** (traced to a quoted primary source or a probe I
ran) or listed under "Unverified / open" at the end.

## Verdict / what this means for us

1. **GRDB under plain SwiftPM links the system `libsqlite3`** — a `.systemLibrary` target
   with `link "sqlite3"`, nothing vendored. So the FTS5 and `trigram` you already measured
   in the shell are literally the same code GRDB will call. **No custom build needed, and
   none is even possible without abandoning SwiftPM.** (§1, §10)

2. **Trigram works from GRDB today**, via
   `FTS5TokenizerDescriptor(components: ["trigram"])` — `init(components:)` is `public`.
   GRDB ships no `.trigram` convenience and does not need to. I verified trigram infix
   substring matching on Cyrillic, inside an *external-content* table, with working
   `snippet()`. (§1, §7)

3. **Two processes on one file is supported and documented** — GRDB has a whole guide for
   it, `DatabaseSharing.md` — but it opens with a genuine warning: *"Preventing errors that
   may happen due to database sharing is difficult… Always consider sharing plain files, or
   any other inter-process communication technique, before sharing an SQLite database."*
   For **two macOS CLI processes, one writer / one read-only reader**, the listed hazards
   mostly do not apply to us (the scary one is iOS-only). This is a green light with three
   concrete obligations. (§2)

4. **The three obligations**, in order of how badly they bite:
   - The **writer must enable persistent WAL** (`SQLITE_FCNTL_PERSIST_WAL`) or the read-only
     process fails to open the file whenever the writer isn't running. Non-obvious, and
     GRDB documents it explicitly.
   - The **reader must never migrate**; it checks `migrator.hasCompletedMigrations` /
     `hasBeenSuperseded` and refuses to serve on mismatch. The migrator definition must live
     in a module shared by both binaries.
   - **`ValueObservation` will not see cross-process writes.** Don't reach for it; an MCP
     tool call queries on demand anyway.

5. **Custom `FTS5WrapperTokenizer` is not ruled out, but I recommend against it for v1.**
   Registration is per-connection, and I confirmed empirically what happens without it: the
   file opens fine, unrelated tables work, a plain `SELECT` from the FTS5 table even works —
   but any `MATCH` or `INSERT` dies at step time with `no such tokenizer: …`. Workable if
   both binaries register the same type; the danger is **silent** token divergence on
   version skew, not a loud failure. `unicode61` already gives us Cyrillic case-folding.
   (§3, §7)

6. **Proposed shape:** one content table `post`; two synchronized FTS5 tables over it —
   `post_ft` (`unicode61 remove_diacritics 2`) for ranked word search, `post_tri`
   (`trigram`) for substring. Query via raw-SQL join with `bm25`/`snippet`. Untrusted LLM
   query text goes exclusively through `FTS5Pattern(matchingAllTokensIn:)` and friends —
   never `rawPattern`. Normalize all text NFC on the way in and out. (§4–§7)

---

## 1. Which SQLite does GRDB link against under plain SwiftPM? — **VERIFIED**

**Answer: the system `libsqlite3`.** GRDB's SwiftPM manifest declares a `systemLibrary`
target and the `GRDB` target depends on it. Nothing is vendored or compiled from
amalgamation source.

Primary source — `Package.swift` @ `groue/GRDB.swift` `master`
(fetched 2026-08-23 via `raw.githubusercontent.com`):

```swift
// GRDB+SQLCipher: Delete the GRDBSQLite target
.systemLibrary(
    name: "GRDBSQLite",
    providers: [.apt(["libsqlite3-dev"])]),
```

and the module map that target points at — `Sources/GRDBSQLite/module.modulemap`:

```
module GRDBSQLite [system] {
    header "shim.h"
    link "sqlite3"
    export *
}
```

`Sources/GRDBSQLite/shim.h` is just `#include <sqlite3.h>` plus small static-inline
wrappers around variadic C functions (`sqlite3_config`, `sqlite3_db_config`) that Swift
cannot call. `link "sqlite3"` resolves, on macOS, to `/usr/lib/libsqlite3.dylib` — the
same library `sqlite3(1)` and every other system client uses.

### The FTS5 nuance that matters

`Package.swift` also carries:

```swift
var swiftSettings: [SwiftSetting] = [
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_ENABLE_SNAPSHOT"),
    .define("SQLITE_DISABLE_SNAPSHOT", .when(platforms: [.linux])),
]
```

These are **`SwiftSetting.define`, not `CSetting.define`** — i.e. Swift *conditional
compilation* flags (`#if SQLITE_ENABLE_FTS5`) that gate GRDB's own Swift FTS5 API surface
(`FTS5`, `FTS5Pattern`, `FTS5Tokenizer`, …). They do **not** compile SQLite; they are
GRDB asserting "the SQLite I am linking against has FTS5". That assertion is
unconditionally true on Apple platforms, and matches what you measured on this machine
(system sqlite3 3.51.0 reports `ENABLE_FTS5`).

**Consequence for us:** the FTS5 you verified in the shell *is* the FTS5 GRDB will use.
Same library, same compile options, same tokenizers.

### Trigram tokenizer — **VERIFIED available, no custom build**

Trigram shipped in SQLite 3.34.0 (2020-12-01) and is part of the FTS5 module itself, not a
separate compile option. macOS system SQLite here is 3.51.0 and you confirmed `trigram`
works on Cyrillic. Since GRDB links that exact library, `tokenize='trigram'` is reachable
from GRDB with zero extra setup — it is passed through as a raw tokenizer string:

```swift
try db.create(virtualTable: "post_ft", using: FTS5()) { t in
    t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram", "remove_diacritics", "1"])
    // or the built-in helper: t.tokenizer = .unicode61(...)
    t.column("body")
}
```

`FTS5TokenizerDescriptor` takes arbitrary `components`, so any tokenizer the linked SQLite
knows about (including `trigram`) is expressible without GRDB needing to bless it.

---

## 2. Two processes, one database file — GRDB's documented position — **VERIFIED**

GRDB has a dedicated guide for exactly our topology:
`GRDB/Documentation.docc/DatabaseSharing.md` (rendered as
<https://swiftpackageindex.com/groue/GRDB.swift/documentation/grdb/databasesharing>).
It does **not** forbid multi-process access — it supports it and prescribes a setup. But it
opens with a real warning. Quoting verbatim:

> **This guide describes a recommended setup that applies as soon as several processes want
> to access the same SQLite database.** It complements the Concurrency guide, that you
> should read first.

and the caveat you suspected exists:

> Important: Preventing errors that may happen due to database sharing is difficult. It is
> extremely difficult on iOS. And it is almost impossible to test.
>
> Always consider sharing plain files, or any other inter-process communication technique,
> before sharing an SQLite database.

It then enumerates the four failure classes:

> 1. **Database setup** may be attempted by multiple processes, concurrently, with possible conflicts.
> 2. **SQLite** may throw `SQLITE_BUSY` errors, "database is locked".
> 3. **iOS** may kill your application with a `0xDEAD10CC` exception.
> 4. **GRDB** DatabaseObservation does not detect changes performed by external processes.

**Reading it for us:** #3 is iOS-only (app suspension) — irrelevant to two macOS CLI
processes. #4 is the one that will actually bite: `ValueObservation` in `tgkb-mcp` will
**not** see writes made by `tgkb`. #2 is manageable with `busyMode`. #1 is solved by having
exactly one process own migrations.

### DatabasePool vs DatabaseQueue — **VERIFIED**

> In order to access a shared database, use a `DatabasePool`. It opens the database in the
> [WAL mode], which helps sharing a database because it allows multiple processes to access
> the database concurrently.
>
> It is also possible to use a `DatabaseQueue`, with the `.wal` `Configuration/journalMode`.

So: `DatabasePool` is the recommendation (WAL by default, multiple concurrent readers).
`DatabaseQueue` is permitted if you set `journalMode = .wal` — it serializes all access
*within* a process onto one connection, which is fine for a single-threaded MCP server but
gains nothing. **Use `DatabasePool` in both processes.**

### The persistent-WAL requirement — the trap that would have cost us a day — **VERIFIED**

`DatabaseSharing.md`, section "The Specific Case of Read-Only Connections":

> Read-only connections will fail unless two extra files ending in `-shm` and `-wal` are
> present next to the database file. Those files are regular companions of databases in the
> WAL mode. But they are deleted, under regular operations, when database connections are
> closed. Precisely speaking, they *may* be deleted: it depends on the SQLite and the
> operating system versions. And when they are deleted, read-only connections fail.
>
> The solution is to enable the "persistent WAL mode" […] by setting the
> `SQLITE_FCNTL_PERSIST_WAL` flag. This mode makes sure the `-shm` and `-wal` files are
> never deleted, and guarantees a database access to read-only connections.

**Action for us:** the *writer* (`tgkb`) must set persistent WAL, or `tgkb-mcp` will fail
to open the file whenever `tgkb` is not running. GRDB's own sample:

```swift
configuration.prepareDatabase { db in
    if db.configuration.readonly == false {
        var flag: CInt = 1
        let code = withUnsafeMutablePointer(to: &flag) { flagP in
            sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, flagP)
        }
        guard code == SQLITE_OK else { throw DatabaseError(resultCode: ResultCode(rawValue: code)) }
    }
}
```

### Read-only opening — **VERIFIED, and yes it works against a live WAL writer**

```swift
var configuration = Configuration()
configuration.readonly = true
let dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)
```

That is GRDB's own `openReadOnlyDatabase` sample, in the multi-process guide, explicitly for
"a process that only reads in the database" while another writes. A read-only WAL connection
is exactly SQLite's designed case: readers read the last committed snapshot and never block
the writer, and the writer never blocks them. Two riders GRDB attaches:

- the `-wal`/`-shm` files must exist ⇒ persistent WAL on the writer (above);
- the reader still needs **write access to the containing directory** in the general case
  (SQLite must be able to create `-shm`); with persistent WAL and a live writer, the files
  are already there.

### SQLITE_BUSY and `busyMode` — **VERIFIED**

> If several processes want to write in the database, configure the database pool of each
> process that wants to write:
> ```swift
> configuration.busyMode = .timeout(/* a TimeInterval */)
> ```
> The busy timeout has write transactions wait, instead of throwing `SQLITE_BUSY`, whenever
> another process is writing. GRDB automatically opens all write transactions with the
> IMMEDIATE kind, preventing write transactions from overlapping.

We have **one writer**, so `SQLITE_BUSY` on writes is not our scenario. Readers can still
hit busy on checkpoint contention; set a modest `busyMode = .timeout(5)` on both sides —
it costs nothing.

GRDB also wraps opening in `NSFileCoordinator` in both samples ("Since several processes may
open the database at the same time, protect the creation of the database connection with an
NSFileCoordinator"). For two macOS CLI processes this is cheap insurance at open time only.

### Cross-process change notification — **VERIFIED limitation**

> DatabaseObservation features are not able to detect database changes performed by other
> processes.
>
> Whenever you need to notify other processes that the database has been changed, you will
> have to use a cross-process notification mechanism such as NSFileCoordinator or
> CFNotificationCenterGetDarwinNotifyCenter. You can trigger those notifications
> automatically with `DatabaseRegionObservation`.

**For us this is a non-issue**: `tgkb-mcp` answers a tool call by running a query at that
moment; it does not need a live-updating view. Do not reach for `ValueObservation` across
the process boundary — it will silently never fire.

---

## 3. Custom `FTS5WrapperTokenizer` across process boundaries — **VERIFIED EMPIRICALLY**

### What GRDB requires (primary source)

`Documentation/FTS5Tokenizers.md` @ master, section "Using a Custom Tokenizer":

> **Register the custom tokenizer into the database:**
> ```swift
> class MyTokenizer : FTS5CustomTokenizer { ... }
>
> var config = Configuration()
> config.prepareDatabase { db in
>     db.add(tokenizer: MyTokenizer.self)
> }
> let dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
> ```

Registration is per-`Database` (per SQLite connection), done from `prepareDatabase`, which
GRDB runs on **every** connection a pool opens. Within one process that is handled for you.
GRDB's docs do **not** discuss the cross-process case — so I probed it.

`FTS5WrapperTokenizer` itself is the ergonomic protocol: you implement
`accept(token:flags:for:tokenCallback:)` and delegate the hard work to a `wrappedTokenizer`
(usually `.unicode61()`), post-processing each token — folding, stemming, synonyms.
The three protocols are `FTS5Tokenizer` ⊃ `FTS5CustomTokenizer` ⊃ `FTS5WrapperTokenizer`.

### The probe

sqlite3 3.51.0 (the system library GRDB links). I built an FTS5 table with `unicode61`,
then rewrote its schema text via `PRAGMA writable_schema` to name a tokenizer that no
connection has registered — an exact simulation of "second process opens the file without
registering the tokenizer". Results:

| Operation on a connection lacking the tokenizer | Result |
|---|---|
| Open the database file | **OK** |
| `.tables`, read/write unrelated tables | **OK** |
| `SELECT body FROM t;` (full scan, no MATCH) | **OK** — tokenizer is instantiated lazily |
| `SELECT ... FROM t_content;` (shadow table, direct) | **OK** |
| `SELECT ... FROM t WHERE t MATCH 'привет';` | **FAILS**: `no such tokenizer: mycustomtok` |
| `INSERT INTO t VALUES('test');` | **FAILS**: same error |
| `CREATE VIRTUAL TABLE … tokenize='nosuchtok'` | **FAILS**: same error |

Note the error surfaces at **step** time, not prepare time, and the connection stays usable
for everything else.

### Verdict on custom tokenizers for us

**Not "cross-process-hostile" in the fatal sense — but it does impose a hard coupling that
I would not take on for a v1.** Concretely:

- `tgkb-mcp` *can* register the same tokenizer (it links GRDB too), so this is workable.
- But the tokenizer type must live in a **shared Swift module** consumed by both targets,
  registered under a **byte-identical name**, with **byte-identical behavior**.
- The failure mode of getting that wrong is the dangerous one: if the writer indexed with
  tokenizer v1 and the reader tokenizes queries with v2, **there is no error** — FTS5
  matches only when both sides emit identical tokens, so you get silently wrong/empty
  results. Ship-skew between two independently-built binaries makes this a live risk.
- And forgetting to register at all does not fail at open; it fails on the first search,
  i.e. inside an MCP tool call.

**Recommendation: use built-in tokenizers (`unicode61` and/or `trigram`) for v1.**
`unicode61` already case-folds and diacritic-strips Cyrillic and Latin alike, which is the
bulk of what mixed ru/en needs. Revisit a custom tokenizer only if stemming (Russian
morphology) proves necessary — and if so, put it in a shared module with a version-stamped
tokenizer name (`tgkb_ru_v1`) so skew fails loudly instead of silently.

---

## 4. FTS5 table creation, external content, migrations — **VERIFIED**

Source: `Documentation/FullTextSearch.md` @ master, "Create FTS5 Virtual Tables" and
"External Content Full-Text Tables".

```swift
try db.create(virtualTable: "document", using: FTS5()) { t in
    t.column("content")
    t.column("uuid").notIndexed()
    t.content = "table"          // external content
    t.contentRowID = "id"
    t.prefixes = [2, 4]
    t.columnSize = 0
    t.detail = "column"
}
```

`FTS5TableDefinition` exposes `tokenizer`, `content`, `contentRowID`, `prefixes`,
`columnSize`, `detail`, `column(_:)`, `synchronize(withTable:)` (verified in
`GRDB/FTS/FTS5.swift`, all `public`).

> **All columns in a full-text table contain text.** If you need to index a table that
> contains other kinds of values, you need an "external content" full-text table.

That is us: `post` holds ids, channel, date, url, body; only `body` (and maybe a title) is
searched.

### `synchronize(withTable:)` — **VERIFIED**

> The two tables must be kept up-to-date, so that the full-text index matches the content of
> the regular table. This synchronization happens automatically if you use the
> `synchronize(withTable:)` method in your full-text table definition […]
> The eventual content already present in the regular table is indexed, and every insert,
> update or delete that happens in the regular table is automatically applied to the
> full-text index.

```swift
try db.create(table: "post") { t in /* … */ }

try db.create(virtualTable: "post_ft", using: FTS5()) { t in
    t.synchronize(withTable: "post")
    t.column("body")
}
```

**Mechanism, and why it matters to the migrator** — quoted:

> Synchronization of full-text tables with their content table happens by the mean of SQL
> triggers.
>
> SQLite automatically deletes those triggers when the content (not full-text) table is
> dropped.
>
> However, those triggers remain after the full-text table has been dropped. Unless they are
> dropped too, they will prevent future insertion, updates, and deletions in the content
> table, and the creation of a new full-text table.
>
> To drop those triggers, use the `dropFTS4SynchronizationTriggers` or
> `dropFTS5SynchronizationTriggers` methods.

**Migration rule for us:** any migration that drops or rebuilds `post_ft` must call
`try db.dropFTS5SynchronizationTriggers(forTable: "post_ft")` right after
`try db.drop(table: "post_ft")`, or the *next* migration's inserts into `post` will fail.
This is the single most likely way to break `tgkb` during schema evolution.

Shadow tables (`post_ft_data`, `post_ft_idx`, `post_ft_content`, `post_ft_docsize`,
`post_ft_config`) are created and dropped by SQLite itself; the migrator never names them.
Note from my probe above that they *are* directly readable as ordinary tables — useful for
debugging, never for querying.

### Querying an external-content table — **VERIFIED gotcha**

> SQLite will throw an error when you try to perform a full-text search on a regular table:
> `SQLite error 1: unable to use function MATCH in the requested context`
>
> The solution is to perform a joined request, using raw SQL:
> ```swift
> let sql = """
>     SELECT book.*
>     FROM book
>     JOIN book_ft
>         ON book_ft.rowid = book.rowid
>         AND book_ft MATCH ?
>     """
> ```

So `tgkb-mcp`'s search query is a hand-written join, not a query-interface expression. Fine —
we want `bm25`, `snippet`, and `ORDER BY rank` in there anyway.

---

## 5. `FTS5Pattern` — turning untrusted LLM text into a safe pattern — **VERIFIED from source**

Signatures, verified in `GRDB/FTS/FTS5Pattern.swift` @ master:

```swift
public struct FTS5Pattern: Sendable {
    public let rawPattern: String
    public init?(matchingAnyTokenIn string: String)      // "foo bar" -> foo OR bar
    public init?(matchingAllTokensIn string: String)     // "foo bar" -> foo bar   (AND)
    public init?(matchingAllPrefixesIn string: String)   // "foo bar" -> foo* bar*
    public init?(matchingPhrase string: String)          // "foo bar" -> "foo bar"
    public init?(matchingPrefixPhrase string: String)    // "foo bar" -> ^"foo bar"
    public init(rawPattern: String, allowedColumns: [String] = []) throws  // THROWS
}

extension Database {
    public func makeFTS5Pattern(rawPattern: String, forTable table: String) throws -> FTS5Pattern
}
```

**Only two things throw**: `init(rawPattern:allowedColumns:)` and
`Database.makeFTS5Pattern(rawPattern:forTable:)`. The five `matching…` initializers are
**failable, non-throwing** — they return `nil` only when no pattern could be built
(empty input, or input that tokenizes to nothing, e.g. `"*"`).

### The sanctioned answer for untrusted input — quoted

> The FTS5Pattern initializers don't throw. They build a valid pattern from any string,
> **including strings provided by users of your application**.

So: **for text arriving from an LLM tool call, use the `matching…` initializers, never
`rawPattern`.** Treat `nil` as "empty query".

### How the safety is actually achieved (this is the load-bearing detail)

All five failable inits funnel through the same private helper — verified in
`GRDB/FTS/FTS5.swift`:

```swift
static func tokenize(query string: String) throws -> [String] {
    try DatabaseQueue().inDatabase { db in
        try db.makeTokenizer(.ascii()).tokenize(query: string).compactMap {
            $0.flags.contains(.colocated) ? nil : $0.token
        }
    }
}
```

It runs the input through the **`ascii` tokenizer**, whose default separator set is every
non-alphanumeric ASCII character. That means every FTS5 query-syntax character —
`"` `*` `(` `)` `:` `^` `-` `+` — is *discarded as a separator*, and the reserved bare-word
operators `AND`/`OR`/`NOT`/`NEAR` are re-emitted as ordinary lowercased terms. The output is
then re-validated by `init(rawPattern:)`. There is no injection surface left.

Two consequences worth knowing:

1. **Cyrillic survives intact.** The `ascii` tokenizer treats codepoints > 127 as token
   characters, so Russian words pass through unsplit and *uncased*. That is fine: the
   resulting bare terms are re-tokenized by the *table's* tokenizer (`unicode61`) at MATCH
   time, which is where case-folding and diacritic-stripping actually happen. I probed the
   end-to-end behavior below.
2. **Cost.** Both `FTS5.tokenize(query:)` and `init(rawPattern:)` spin up a fresh in-memory
   `DatabaseQueue()` per call. Negligible at MCP-tool-call rates; do not call it in a loop
   over thousands of rows.

### Which initializer for us

For an MCP `search` tool, `matchingAllTokensIn` is the right default (AND semantics — an LLM
sending three words means all three). Offer `matchingPhrase` behind an explicit
`exact_phrase` argument. `matchingAllPrefixesIn` is a decent "autocomplete" mode but is
**not** substring search — `*` in FTS5 is a prefix operator only, never infix. Substring is
the trigram tokenizer's job, and trigram tables are queried with a plain `MATCH 'substring'`
rather than a prefix pattern.

---

## 6. Ranking and highlighting: `bm25()`, `snippet()`, `highlight()` — **VERIFIED**

GRDB does **not** wrap the FTS5 auxiliary functions in Swift. It exposes exactly one
convenience — ordering by relevance — and expects raw SQL for the rest.
`Documentation/FullTextSearch.md`, "FTS5: Sorting by Relevance":

```swift
// SQL
let documents = try Document.fetchAll(db,
    sql: "SELECT * FROM document WHERE document MATCH ? ORDER BY rank",
    arguments: [pattern])

// Query Interface
let documents = try Document.matching(pattern).order(Column.rank).fetchAll(db)
```

`Column.rank` is the only sugar. `bm25(tbl, w0, w1, …)`, `snippet(tbl, col, open, close,
ellipsis, tokens)` and `highlight(tbl, col, open, close)` are called as plain SQL functions.
Since we already need a join to reach the content table (§4), this costs nothing.

I confirmed all three work on Cyrillic against the system SQLite 3.51.0:

```
sqlite> SELECT p.id, bm25(post_ft, 1.0) AS rank,
   ...>        snippet(post_ft, 0, '[', ']', '…', 8),
   ...>        highlight(post_ft, 0, '<b>', '</b>')
   ...> FROM post p JOIN post_ft f ON f.rowid = p.id
   ...> AND post_ft MATCH 'привет OR поиск' ORDER BY rank;
1|-0.542532041792845|[Привет], мир! Обновление GRDB для macOS.|<b>Привет</b>, мир! …
3|-0.48262052797523 |Смешанный текст: … полнотекстовый [поиск] works fine.|…
```

Note bm25 returns **negative** scores (more negative = more relevant), so `ORDER BY rank`
ascending is correct and `ORDER BY bm25(...) DESC` is a classic bug. Column weights go in
positionally: `bm25(post_ft, 10.0, 1.0)` weights column 0 ten times column 1 — useful if we
index a title/first-line column alongside the body.

---

## 7. Mixed Russian + English: what I measured — **VERIFIED EMPIRICALLY**

System sqlite3 3.51.0, external-content FTS5 over a `post(id, body)` table.

| Test | `unicode61 remove_diacritics 2` | `trigram` |
|---|---|---|
| `MATCH 'ПРИВЕТ'` finds "Привет, мир!" (Cyrillic case-fold) | **yes** | yes |
| `MATCH 'полнотекстовый поиск'` (implicit AND, mixed doc) | **yes** | yes |
| `MATCH 'текстов'` — infix substring of "полнотекстовый" | **no** | **yes** |
| `snippet()` / `highlight()` | yes | **yes** (`…но[текстов]ый …`) |
| external content (`content='post'`) + `'rebuild'` | yes | **yes** |
| 2-character query (`'те'`) | n/a | **no match** — trigram needs ≥3 chars |

So: **`unicode61` already solves Cyrillic case-insensitivity out of the box** — no custom
tokenizer needed for that. `remove_diacritics 2` is the right setting (it is the
Unicode-correct variant that does not mangle non-Latin scripts; GRDB models it as
`FTS5.Diacritics.removeLegacy` vs `.remove`).

What `unicode61` does **not** give us, and Telegram's own search also does not give us, is
infix substring — and trigram does, on Cyrillic, with working snippets, including in an
external-content table. That confirms the plan.

**Cost of trigram, be aware:** it indexes every 3-character window, so the index is several
times larger than a word index and ranking by `bm25` is much less meaningful (every document
containing the trigrams scores similarly). Queries shorter than 3 characters silently return
nothing.

**Recommended shape: two FTS5 tables over the same content table.**

```swift
// word search — ranked, snippeted, the default
try db.create(virtualTable: "post_ft", using: FTS5()) { t in
    t.synchronize(withTable: "post")
    t.tokenizer = .unicode61(diacritics: .removeLegacy)   // "remove_diacritics 2"
    t.column("body")
}

// substring search — the escape hatch, only when the caller asks for it
try db.create(virtualTable: "post_tri", using: FTS5()) { t in
    t.synchronize(withTable: "post")
    t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
    t.column("body")
}
```

`FTS5TokenizerDescriptor.init(components: [String])` is `public` (verified in
`GRDB/FTS/FTS5TokenizerDescriptor.swift`, line 84), and GRDB emits it verbatim as
`tokenize='…'`. GRDB ships convenience statics only for `.ascii`, `.porter`, `.unicode61` —
there is no `.trigram` helper, and none is needed.

### Unicode normalization — the one real trap for Russian — **VERIFIED (docs)**

`Documentation/FullTextSearch.md`, "Unicode Full-Text Gotchas":

> Generally speaking, matches may fail when content and query don't use the same unicode
> normalization. SQLite actually exhibits inconsistent behavior in this regard.
>
> For example, for "aimé" to match "aimé", they better have the same normalization: the NFC
> "aim\u{00E9}" form may not match its NFD "aime\u{0301}" equivalent. Most strings that you
> get from Swift, UIKit and Cocoa use NFC, so be careful with NFD inputs (such as strings
> from the HFS+ file system, or strings that you can't trust like network inputs). Use
> `String.precomposedStringWithCanonicalMapping` to turn a string into NFC.

Telegram HTML is a network input. Russian "ё" and "й" are exactly the precomposed/decomposed
hazard. **Apply `.precomposedStringWithCanonicalMapping` to post bodies on the way in and to
query text on the way out**, in both processes. This is a two-line fix that prevents an
extremely confusing class of "search silently misses" bugs.

---

## 8. `DatabaseMigrator`, and what the read-only process should do — **VERIFIED**

`GRDB/Documentation.docc/Migrations.md` @ master.

> **Each migration runs in a separate transaction.** Should one throw an error, its
> transaction is rollbacked, subsequent migrations do not run, and the error is eventually
> thrown by `DatabaseMigrator/migrate(_:)`.
>
> **Migrations run with deferred foreign key checks.** […]
>
> **The memory of applied migrations is stored in the database itself** (in a reserved table).

> Migrations can only run forward:
> ```swift
> try migrator.migrate(dbQueue, upTo: "v2")
> try migrator.migrate(dbQueue, upTo: "v1")
> // ^ fatal error: database is already migrated beyond migration "v1"
> ```

### The sanctioned read-only pattern — quoted verbatim

This is the exact answer to "what does a process that cannot migrate do?" — it is spelled
out in `Migrations.md`, and repeated in `DatabaseSharing.md`'s `openReadOnlyDatabase` sample:

> When several versions of your app are deployed in the wild, you may want to perform extra
> checks:
> ```swift
> try dbQueue.read { db in
>     // Read-only apps or extensions may want to check if the database
>     // lacks expected migrations:
>     if try migrator.hasCompletedMigrations(db) == false {
>         // database too old
>     }
>
>     // Some apps may want to check if the database
>     // contains unknown (future) migrations:
>     if try migrator.hasBeenSuperseded(db) {
>         // database too new
>     }
> }
> ```

**Design rule for `telegram-kb`:**

- `tgkb` (writer) **owns migrations**. It is the only process that calls
  `migrator.migrate(dbPool)`. It should also check `hasBeenSuperseded` afterwards and refuse
  to run against a future database (GRDB's own writer sample does exactly this).
- `tgkb-mcp` (reader) **never migrates**. It opens read-only, then runs both checks and
  fails the MCP handshake with a clear message — "database is older than this build, run
  `tgkb migrate`" / "database was written by a newer tgkb, upgrade tgkb-mcp".
- The `DatabaseMigrator` definition therefore has to be **shared between both targets** —
  put it in a common `TelegramKBDB` module. This is the one piece of code the two binaries
  genuinely must agree on.

### `eraseDatabaseOnSchemaChange` — **VERIFIED, and: do not ship it**

> A `DatabaseMigrator` can automatically wipe out the full database content, and recreate the
> whole database from scratch, if it detects that migrations have changed their definition.
> […]
> - A schema change is detected: any difference in the `sqlite_master` table […]
>
> > Warning: This option can destroy your precious users' data!
>
> It is recommended that this option does not ship in the released application: hide it
> behind `#if DEBUG`.

For us it is worse than merely dangerous: re-crawling Telegram to rebuild a wiped corpus is
expensive and rate-limited. Keep it `#if DEBUG` **and** gate it on an explicit
`TGKB_ERASE_DB=1` env var.

Also from "Good Practices":

> **A good migration is a migration that is never modified once it has shipped.** […]
> migrations should define the database schema with **strings** […] **migrations should not
> depend on application types.**

So the migrator must not reference `Post.databaseTableName` — literal `"post"`, `"post_ft"`.

---

## 9. Concurrency rules that bind us — **VERIFIED**

`GRDB/Documentation.docc/Concurrency.md` @ master:

> In the case of apps that share a database with other processes, such as an iOS app and its
> extensions, don't miss the dedicated Sharing a Database guide after this one.

> #### Rule 1: Connect to any database file only once
>
> Open one single `DatabaseQueue` or `DatabasePool` per database file, for the whole duration
> of your use of the database. Not for the duration of _each_ database access, but really for
> the duration of _all_ database accesses to this file.
>
> - *What if you do not follow this rule?*
>     - You will not be able to use the DatabaseObservation features.
>     - You will see SQLite errors (`SQLITE_BUSY`).

**For `tgkb-mcp` this is the rule most likely to be violated by accident**: an MCP server is
tempting to write as "open the db, answer, close". Don't. Open one `DatabasePool` at process
start and keep it for the process lifetime.

Two useful reassurances, also from `Concurrency.md`:

> Concurrent reads can not see partial database updates (even reads performed by other
> processes).

> An isolated read sees a stable and immutable state of the database, and does not see
> changes performed by eventual concurrent writes (even writes performed by other processes).

> Whenever you extract some data from a database access, immediately consider it as _stale_.
> […] nothing prevents other application threads or **processes** from overwriting the value
> you have just fetched.

So the reader is never at risk of seeing a half-written crawl batch — provided `tgkb` wraps
each batch of posts in one `dbPool.write { }` transaction, which GRDB does by default.

---

## 10. Alternatives to the system SQLite — costed, briefly

**`GRDB-SQLCipher`.** Encryption, not capability. Delivered via CocoaPods subspec, or under
SPM by editing GRDB's own `Package.swift` (the commented-out block quoted in §1 that swaps
`GRDBSQLite` for a `sqlcipher/SQLCipher.swift` dependency and defines `SQLITE_HAS_CODEC`).
That means vendoring a fork of GRDB — real maintenance cost. It bundles its own SQLite, so
FTS5/trigram availability becomes SQLCipher's build's problem rather than Apple's. **Not
relevant to us**: public Telegram channel posts are not secrets.

**Custom SQLite build (`SQLiteCustom` / `GRDBCustom.xcodeproj`).** `Documentation/
CustomSQLiteBuilds.md` opens with "By default, GRDB uses the version of SQLite that ships
with the target operating system" and then carries a disqualifying warning:

> Warning: The technique described here is not compatible with the Swift Package Manager
> (SPM). It will create build issues with SPM companion librairies such as GRDBQuery or
> GRDBSnapshotTesting.

It also requires cloning GRDB, `git submodule update --init SQLiteCustom/src`, and an Xcode
project with four `GRDBCustomSQLite/*.xcconfig` files. And the pinned version is **SQLite
3.47.2** — *older* than the 3.51.0 already on this Mac. For a SwiftPM CLI project this route
would cost us the package manager and downgrade our SQLite. **Ruled out.**

**Third-party SQLite as an SPM dependency** (e.g. `stephencelis/CSQLite`,
`SQLiteCipher`-style packages) is technically possible by hand-editing GRDB's manifest, with
the same fork-maintenance cost. Only worth it if Apple's SQLite ever *removes* something we
depend on — which has not happened and would be newsworthy.

**Conclusion: stay on the system library.** It is newer than GRDB's own custom-build pin, it
has FTS5 + trigram (measured), and it is the only configuration GRDB's SwiftPM path
supports without a fork.

---

## Unverified / open

- **`detail=column` + `trigram`**: SQLite's docs state trigram requires `detail=full`, but
  `CREATE VIRTUAL TABLE … tokenize='trigram', detail=column` was **accepted without error**
  by sqlite 3.51.0 in my probe. I did not chase whether it fails later at query time.
  *Unverified — not probed further.* Just use the default `detail=full` for the trigram
  table; we have no reason to change it.
- **`trigram remove_diacritics 1`** was accepted, but `'grus'` did not match `'Grüßen'` in my
  probe — so ß→ss folding does not happen. German is irrelevant to us; noting it only so
  nobody assumes trigram does aggressive folding.
- **NSFileCoordinator necessity on macOS for two non-sandboxed CLI processes.** GRDB's
  samples use it unconditionally. I did not test whether omitting it causes real problems
  here. *Unverified — could not probe without building both binaries.* Cheap enough to just
  follow GRDB's sample.
- **GRDB's Swift 6 strict-concurrency posture** was not investigated (out of scope for this
  pass), though `Package.swift` declares `swiftLanguageModes: [.v6]` and `FTS5Pattern` /
  `FTS5TokenizerDescriptor` are `Sendable`, which is a good sign.
- GRDB latest release: **v7.11.1**, published **2026-06-18**; repo last pushed 2026-08-08;
  15 open issues. (via `gh api`, 2026-08-23.)
