# Storage engine options for `telegram-kb`, and semantic search over Russian

Research pass, 2026-08-24, on macOS 26.5.2 (build 25F84) / Swift 6.3.3, arm64.
Builds on `sqlite-cross-process-probe.md`, `grdb-fts5.md` and `morphology-and-embeddings.md`;
does not restate them. Probe scripts under `scratchpad/` (research probes, not shipped code).

---

## Verdict / recommendation

**Stay with SQLite + GRDB.** No challenger clears the bar, and two of the most plausible ones
fail on the criterion that started this. Specifically:

1. **Stay on SQLite + FTS5 via GRDB.** Nothing found here names a failure of SQLite that another
   engine fixes without giving up something already verified working. DuckDB — the strongest
   technical alternative — **fails criterion 1 outright**: its own docs say one process may read
   *and* write, or many processes may read and *none* write. That is exactly the topology
   `telegram-kb` requires, and DuckDB does not have it. Meilisearch, Typesense and Qdrant are
   daemons (criterion 6). Tantivy wins on Russian search quality alone and costs a Rust
   toolchain, a second binary artifact and a hand-written FFI layer to get a stemmer that
   `NLTagger` already provides for free. Realm is vendor-deprecated. LMDB/RocksDB have no text
   or vector search at all. SwiftData/Core Data would *hide* the FTS5 that is the point.

2. **Add `sqlite-vec` when Phase 3 needs vectors — vendored, pinned, in the same database file.**
   This is the substantive new finding. I verified that macOS's system SQLite has
   `SQLITE_OMIT_LOAD_EXTENSION` and exports **neither** `sqlite3_load_extension` **nor** a working
   `sqlite3_auto_extension` (Apple returns `SQLITE_MISUSE`), so every published instruction for
   adding `sqlite-vec` is inapplicable here — *and then* verified that calling
   `sqlite3_vec_init(db, …)` directly from GRDB's `prepareDatabase` hook works, with the stock
   `-lsqlite3`, no GRDB fork and no custom SQLite build. Measured at full corpus scale: **100k ×
   512-dim vectors, brute-force kNN in 71 ms, 198 MB** (or 46 ms / 51 MB int8, 2 ms / 8 MB
   binary). The absence of an ANN index — the usual objection — does not matter at 100k.
   Cost: one 10k-line C file (54 KB gzipped) and the discipline of pinning a **pre-v1**
   dependency that says "expect breaking changes".

3. **For Russian semantics, use `NLContextualEmbedding`, not MLX — at least first.**
   `morphology-and-embeddings.md` concluded that Apple has no Russian embedding and that MLX was
   therefore the only route. That is right about `NLEmbedding` — I confirmed
   `supportedRevisions(for: .russian)` is the **empty set**, so there is nothing to enable — but
   wrong about Apple. **`NLContextualEmbedding(script: .cyrillic)` covers ru/bg/kk/uk**, and I
   downloaded the asset, loaded it and embedded Russian on this machine: **`mBERT_cyrl`, 512
   dims, 256-token limit, 63 MB, OS-downloaded and OS-shared, 0.44 s to load, 74 posts/s**.
   Our binary grows by nothing.

**The single best on-device multilingual embedding option, with size:
`NLContextualEmbedding(script: .cyrillic)` — 512 dims, 63 MB, zero packaging cost.**
If an aligned cross-language space later proves necessary, the best paid option is
**`intfloat/multilingual-e5-small` — 384 dims, MIT, 449 MB (224 MB quantized for MLX)**.

### The two caveats that come with recommendation 3

Both were measured, and both are design constraints, not footnotes.

- **Raw cosine does not work.** The model is a classifier feature extractor, and Apple's own
  header says "For semantic similarity tasks, consider using `NLEmbedding`". Measured, unrelated
  sentences scored **0.934** while a same-topic pair scored **0.809** — the ranking is inverted.
  **Mean-centering fixes it completely** (margin −0.125 → **+0.410**, clean separation). The
  corpus mean must be stored in the database and used by both processes; if writer and reader
  centre differently, quality degrades silently — the same failure shape that got custom
  tokenizers rejected in `Design.md`.
- **Cyrillic and Latin are two different models with unrelated vector spaces.** A Russian and an
  English sentence that mean the same thing score **−0.007** — noise. On a corpus that mixes
  ru and en *within single posts*, that is a real limit: no cross-language semantic retrieval,
  two indexes, two means. **This — not "Apple has no Russian model" — is the actual argument for
  MLX**, and it is a much narrower one. Test it against `evals/` before paying 449 MB for it.

### What this does not change

The advisory-file-lock MVP mitigation, `SQLITE_FCNTL_PERSIST_WAL`, the writable-directory
requirement, the writer-owns-migrations rule and the "no `ValueObservation` across processes"
rule all stand exactly as `sqlite-cross-process-probe.md` and `grdb-fts5.md` left them. Adding a
`vec0` table to the same file preserves every one of them, which is most of why it is the right
answer: **one file, one WAL, one snapshot, one migrator.**

### What would change the verdict

- The corpus growing past ~1M posts, where brute-force kNN stops being free and `sqlite-vec`'s
  ANN index types are still compile-gated and experimental.
- Golden-query evidence that cross-language ru↔en semantic retrieval is required — that buys
  MLX + `multilingual-e5-small`, and nothing else does.
- A second writer appearing. One writer is load-bearing for all of the above.

---

## Q1 — engine comparison

### The load-bearing fact nobody has written down yet: macOS system SQLite cannot load extensions

`grdb-fts5.md` established that GRDB links `/usr/lib/libsqlite3.dylib`. Before evaluating
`sqlite-vec` I checked what that library will actually accept:

```
$ sqlite3 :memory: "pragma compile_options;" | grep OMIT
OMIT_AUTORESET
OMIT_LOAD_EXTENSION          ← this one
```

and confirmed it at the symbol level, because a compile option is a claim and a symbol table is
a fact (`nm` is unreliable against the dyld shared cache, so I resolved each symbol with
`ctypes.CDLL`):

| symbol | in `/usr/lib/libsqlite3.dylib` |
|---|---|
| `sqlite3_load_extension` | **ABSENT** |
| `sqlite3_enable_load_extension` | **ABSENT** |
| `sqlite3_auto_extension` | **PRESENT** |
| `sqlite3_cancel_auto_extension` | **PRESENT** |
| `sqlite3_reset_auto_extension` | **PRESENT** |

**Two consequences, and they point in opposite directions.**

1. **Runtime extension loading is impossible.** You cannot ship `vec0.dylib` and
   `.load` it, and no amount of GRDB configuration changes that — the entry points do not exist
   in the binary. Every "just load sqlite-vec" instruction written for Linux or for a
   self-built SQLite is inapplicable here.
2. **Static linking is still open.** `sqlite3_auto_extension()` survived, and it is the
   documented way to register an extension compiled *into* your own process. So an extension
   shipped as C source (which `sqlite-vec` is) can be compiled as an ordinary SwiftPM C target
   and registered from `Configuration.prepareDatabase` — **no GRDB fork, no custom SQLite
   build**, which is what `grdb-fts5.md` §10 ruled out.

This single fact decides the vector-store question, so it is worth proving rather than
asserting. Probe below.

### `sqlite-vec` — verified working against macOS system SQLite, and it is small

`sqlite-vec` **v0.1.9**, released **2026-03-31**, `prerelease: false` (GitHub releases API).
The amalgamation asset is `sqlite-vec-0.1.9-amalgamation.tar.gz`, **54 KB gzipped**, expanding to
**one `.c` file of 10,199 lines plus a 41-line header**. That is the entire dependency.

**The first thing I tried was wrong, and the way it failed is worth writing down.** Registering
via `sqlite3_auto_extension(sqlite3_vec_init)` compiles, but at runtime:

```
sqlite3_auto_extension rc=21          (SQLITE_MISUSE)
vec_version FAILED: no such function: vec_version
create vec0(512): no such module: vec0
```

The SDK header says why, in as many words:

> `'sqlite3_auto_extension' is deprecated: first deprecated in macOS 10.10` —
> **Process-global auto extensions are not supported on Apple platforms**

The symbol is exported but inert. So on Apple platforms both extension-registration routes that
the sqlite-vec README describes are closed.

**The route that works is to call the init function directly, per connection.** Compiled with
`-DSQLITE_CORE` and linked against the stock `-lsqlite3`:

```c
sqlite3_open(path, &db);
sqlite3_vec_init(db, &err, NULL);     // rc=0
```

```
sqlite3_vec_init(db) rc=0 err=none
vec_version=v0.1.9
create vec0(512)                                   rc=0
create vec0(embedding bit[512])                    rc=0
create vec0(embedding int8[512])                   rc=0
create vec0(post_id integer primary key,
            channel text partition key,
            embedding float[512], +ts integer)     rc=0
knn k=3 → rowid=2 d=0.0000, rowid=3 d=1.4142, rowid=1 d=1.4142   (correct)
```

**This maps exactly onto GRDB's `Configuration.prepareDatabase { db in … }` hook**, which GRDB
runs on every connection a pool opens — the same hook `grdb-fts5.md` already uses for
`SQLITE_FCNTL_PERSIST_WAL` and that custom tokenizers would have used. One extra line, in both
executables. **No GRDB fork, no custom SQLite build, no downgrade** — the three costs that
`grdb-fts5.md` §10 used to rule out every other route to a modified SQLite.

Note the `partition key` and `+aux` column support: `vec0` can carry a channel partition and
auxiliary columns, so metadata filtering happens inside the vector table instead of as a
post-filter.

### Verified benchmark: brute force at full corpus scale is fast enough

sqlite-vec 0.1.x has **no ANN index** — every kNN query is a linear scan. That is the objection
to it, so I measured it at the top of the stated corpus range. 100,000 random unit vectors of
512 dimensions (the exact shape `NLContextualEmbedding` produces), WAL, `synchronous=normal`,
`k=10`, best-of-10 after warm-up, on this machine:

| storage | insert | kNN k=10 over 100k | database size |
|---|---|---|---|
| `float[512]` | 1.79 s (55.8k rows/s) | **71 ms** | **198.5 MB** |
| `int8[512]` (`vec_quantize_int8(…,'unit')`) | 0.98 s | **46 ms** | **51.2 MB** |
| `bit[512]` (`vec_quantize_binary(…)`) | 0.81 s | **2.0 ms** | **8.3 MB** |

**Brute force is a non-issue at this scale.** 71 ms inside an MCP tool call is invisible next to
the LLM round-trip that follows it, and the whole 100k-vector index builds in under two seconds
once the embeddings exist. The corpus would have to grow by an order of magnitude before an ANN
index earned its complexity — and this project's stated ceiling is 100k.

**The real cost is disk, not latency: 198 MB of float32 vectors dwarfs the text corpus.** The
binary-quantized variant is 8.3 MB and 35× faster, which makes the classic two-stage retrieval
attractive: `bit[512]` for a wide first pass, rescore the top few hundred against `float[512]`.
But note that binary quantization discards magnitude entirely, and the mean-centering that
`NLContextualEmbedding` requires (above) happens *before* quantization — so the sign pattern
being quantized is the centred one. Untested in combination; flagged below.

`sqlite-vec` is **Apache-2.0 / MIT dual-licensed** (per the repository), compatible with this
project's constraints.

### The candidates, weighted

Criteria, in the brief's own order of weight: (1) two-process concurrency, (2) ru+en full-text
quality, (3) hybrid keyword+vector in one store, (4) packaging cost, (5) Swift binding maturity /
Swift 6 / licence, (6) operational simplicity (no daemon).

#### SQLite + FTS5 via GRDB — the incumbent, and its honest case

Its case is **not** that it is best at any one criterion. It is that it is the only candidate
that is *acceptable at all six*, and that every one of those six has already been measured on
this machine rather than argued.

- **(1)** Verified: 60/60 cross-process reads, monotonic, zero `SQLITE_BUSY`
  (`sqlite-cross-process-probe.md`). WAL one-writer/many-readers across processes is SQLite's
  designed case, not a workaround. GRDB documents the topology in `DatabaseSharing.md`.
- **(2)** The weakest criterion, honestly. No Russian stemmer; `unicode61` + `trigram` +
  `NLTagger` lemmas is a three-part workaround for something Tantivy has built in.
- **(3)** Now verified as *solved in place* (above): `sqlite-vec` static-links against the
  system library and runs kNN over 100k×512 in 71 ms.
- **(4)** Zero. The engine is already in the OS.
- **(5)** GRDB v7.11.1, `swiftLanguageModes: [.v6]`, MIT.
- **(6)** No daemon, no port, no supervision. A file.

**What it trades away: search quality on Russian, and only that.** Everything else it wins or
ties. That is the whole trade, and it should be stated that plainly rather than buried.

#### SQLite + FTS5 + `sqlite-vec` — the incumbent, extended

Same as above plus a 10k-line C file. **This is the recommendation.** It does not change the
engine, the process model, the packaging story, or anything already verified; it adds one
`prepareDatabase` line and one virtual table. Measured above.

**The one real risk is version churn, not capability.** `site/versioning.md` in the repo:

> `sqlite-vec` is pre-v1, so according to the rules of Semantic Versioning … "minor" release like
> "0.2.0" or "0.3.0" may contain breaking changes.

and the README carries `_`sqlite-vec` is a pre-v1, so expect breaking changes!_`. Mitigation is
cheap and this project already uses it elsewhere: **vendor the amalgamation at a pinned version**
(54 KB gzipped, two files) rather than tracking a moving dependency. Upgrading is then a
deliberate act with a reindex attached, which a vector index needs anyway.

`sqlite-dist.toml` declares an `spm = {}` distribution target, so a SwiftPM artifact is an
official output — but vendoring the amalgamation into a local C target is simpler and pins
harder.

#### DuckDB (+ FTS extension) — **disqualified on criterion 1**

DuckDB's own concurrency documentation states the rule that ends the discussion: in read-write
mode **"one process can both read and write to the database"**, and in read-only mode
**"multiple processes can read from the database, but no processes can write"**. Multi-process
writing is offered only "through the Quack remote protocol", which is **in beta** and is a
*remote protocol* — i.e. a daemon, which criterion 6 penalises.

**This is precisely the topology `telegram-kb` needs and DuckDB does not have it.** One writer
plus one concurrent reader in separate processes is the founding requirement, and DuckDB's answer
is "pick one". Everything else about DuckDB — genuinely better analytics, a real FTS extension
with a Snowball stemmer — is irrelevant once criterion 1 fails.

Two further costs, recorded for completeness: `duckdb/duckdb-swift` builds DuckDB's C++ sources
inside a SwiftPM target (a very large compile, MIT-licensed), and **every tag in that repository
is pre-release-shaped** — `v1.6.0-dev11145`, `v1.5.0-dev8547`, … with **no stable tag at all**.
That is the identical SwiftPM hazard already recorded as `TD-5` for TDLibKit: SwiftPM excludes
pre-release versions from range resolution, so the dependency could only ever be `.exact(...)`.

#### Tantivy (Rust, via FFI/UniFFI) — the only candidate that beats SQLite on criterion 2

Tantivy 0.26.1 (2026-05-10) has what FTS5 lacks: real per-language stemming, including Russian,
via Snowball. On **criterion 2 alone it wins outright**, and it is the only candidate that does.

It loses on almost everything else, and the losses compound:

- **(1)** Tantivy's index is a directory of segment files with a single-writer lock. A separate
  reader process opening the same directory is not the well-trodden path SQLite's WAL is, and
  none of this project's existing cross-process evidence transfers.
- **(4)/(5)** This is the killer. There is **no maintained Swift binding**. The realistic build
  is: write a Rust crate wrapping Tantivy, expose it through UniFFI or a hand-written C ABI,
  compile for `arm64-apple-darwin`, wrap it in an XCFramework or a `.binaryTarget`, and maintain
  the Rust toolchain in CI forever. For a project whose stated posture is to trait-gate a large
  binary artifact specifically to avoid taxing consumers, **adding a second binary artifact and a
  second language toolchain to gain a stemmer is badly out of proportion** — especially when
  `NLTagger` already lemmatises Russian correctly, for free, in-process, as
  `morphology-and-embeddings.md` verified.
- **(3)** Vectors would need a separate store; you would end up running Tantivy *and* SQLite.

**Verdict: the right answer to "SQLite has no Russian stemmer" is `NLTagger`, not Rust.**

#### Meilisearch / Typesense / Qdrant — **disqualified on criterion 6**

All three are servers. Criterion 6 says "no daemon to supervise is strongly preferred", and the
whole architecture in `Design.md` exists to make `tgkb-mcp` a slim, instantly-startable stdio
process with no network. Putting an HTTP server behind it inverts that.

Sizes, for the record (latest releases, macOS arm64 assets):
Meilisearch **v1.53.1**, `meilisearch-macos-apple-silicon` = **116.3 MB**;
Qdrant **v1.19.0**, `qdrant-aarch64-apple-darwin.tar.gz` = **26.3 MB**;
Typesense **v30.2** publishes no macOS asset on its GitHub release at all.

Meilisearch is *excellent* at criterion 2 — it does Russian stemming and typo tolerance out of
the box, and would be the best pure-search answer here. But it costs a 116 MB binary, a port, a
lifecycle (who starts it? what if it is not running when Claude Desktop spawns the MCP server?),
and a second copy of the corpus. For a single-user local tool that is a bad trade, and it is
exactly the trade `Design.md` already refused when it rejected `tgkb serve`.

#### LMDB / RocksDB — **unfit, one line each**

Both are ordered key-value stores with **no full-text search and no vector search whatsoever**;
adopting either means writing an inverted index by hand, which is strictly more work than the
problem. (LMDB does have genuinely excellent multi-process semantics — single-writer,
lock-free MVCC readers across processes — but that solves the criterion SQLite already passes,
at the cost of the two it fails.)

#### SwiftData / Core Data — **unfit on criteria 2 and 3**

Both are object-graph layers over SQLite, and neither exposes FTS5. Core Data's text matching is
`CONTAINS[cd]` predicates, which compile to `LIKE` scans — the exact approach `Design.md` already
identified as inadequate in the prior-art survey ("the only one with a persistent message store
searches it with `SELECT … WHERE text LIKE ?`"). Adopting Core Data would mean **adding an
abstraction layer whose main effect is to hide the FTS5 that is the point of the project**.
Multi-process Core Data is possible (persistent history tracking + remote-change notifications),
but it is more machinery than GRDB's read-only pool, not less. No vector search in either.

#### Realm — **disqualified: deprecated**

`realm/realm-swift`'s own README, first thing on the page:

> **We announced the deprecation of Atlas Device Sync + Realm SDKs in September 2024.**
> … For a version of `realm-swift` without sync features, install version 20 or see the
> `community` branch.

The repository is not archived and v20.0.5 shipped 2026-06-14, but a vendor-deprecated SDK with
499 open issues is not a foundation for a new project. It also has no FTS and no vector search.

---

## Q2 — vector/semantic search over Russian

### The headline: Apple *does* ship a Russian on-device embedding — just not `NLEmbedding`

**`morphology-and-embeddings.md` is correct but incomplete.** `NLEmbedding` really has no
Russian model, and I reconfirmed it on this machine with a stronger test than before — not just
"the factory returns nil", but *there is no revision to ask for*:

```
ru: supportedRevisions=[]  currentRevision=0
en: supportedRevisions=[1] currentRevision=1   rev 1: word=dim 300  sentence=dim 512
uk: supportedRevisions=[]  currentRevision=0
```

`NLEmbedding.supportedRevisions(for: .russian)` is the **empty set**. There is no downloadable
asset, no newer revision, nothing to enable. For `NLEmbedding` the answer is final: **no Russian,
not on this OS, not via an asset.** (Ukrainian likewise.)

**But `NLContextualEmbedding` — a different class, macOS 14+ — has a Cyrillic model, and Russian
is in it.** Probed on this machine:

```
script latin:     id=5C45D94E-…  dim=512 maxTok=256 rev=1 hasAvailableAssets=true   20 langs
script cyrillic:  id=FCDCF262-…  dim=512 maxTok=256 rev=1 hasAvailableAssets=false  4 langs [bg, kk, ru, uk]
script CJK:       id=12784592-…  dim=512 maxTok=256 rev=1 hasAvailableAssets=true    4 langs
NLContextualEmbedding(language: .russian) -> FCDCF262-… dim=512, hasAvailableAssets=false
```

`NLContextualEmbedding(language: .russian)` **resolves to a real model object**. The reason a
naive test looks like failure is that `load()` throws
`NLNaturalLanguageErrorDomain Code=8 "Failed to locate embedding model"` — because the **asset is
not downloaded yet**, not because the model does not exist. The Latin and CJK models happened to
be present on this machine; Cyrillic was not.

Primary source — the SDK header itself,
`MacOSX26.5.sdk/…/NaturalLanguage.framework/Headers/NLContextualEmbedding.h`, on the `languages`
property:

> Starting in iOS 17 and macOS 14, the framework supports 27 languages across three models:
> Latin … Cyrillic — including Bulgarian, Kazakh, Russian, and Ukrainian … Chinese, Japanese, and
> Korean

and on asset availability:

> The framework downloads models over-the-air, so check asset availability and download them if
> needed.

So the download API is `hasAvailableAssets` + `requestAssets(completionHandler:)` (async
`requestAssets() async throws -> AssetsResult`). Download result is measured below.

**Model shape:** 512 dimensions, **256-token maximum sequence length**, revision 1, subword
(BERT-style) tokens. The header is explicit that it emits *per-subword-token* vectors and that
you must pool them yourself:

> This object returns embeddings at the subword level … If you need to work with whole-word
> embeddings or create single representations for entire text inputs, pool or combine subword
> vectors. … Common pooling techniques include: Mean pooling … Max pooling … Use the embeddings
> of the first or last subword tokens.

**One counter-indication, straight from the header, that must be recorded honestly:**

> Note: For semantic similarity tasks, consider using `NLEmbedding`.

Apple positions `NLContextualEmbedding` as a *feature extractor* for Create ML text classifiers,
not as a sentence-similarity model, and points similarity work back at `NLEmbedding` — which for
Russian does not exist. That is the tension this project has to resolve: the only Apple-native
Russian embedding is the one Apple does not recommend for similarity. Mean-pooled BERT token
vectors are a standard (if not state-of-the-art) sentence representation, so it is workable, but
it will not match a model trained with a sentence-similarity objective.
### Verified: the Cyrillic asset downloads, loads, and embeds Russian — 63 MB, OS-managed

I requested the asset and it arrived. Second run, on this machine:

```
before: hasAvailableAssets=true
requestAssets -> available  error=nil  after 0.0s
load() OK in 0.44s
embeddingResult: tokens=17 lang=ru in 0.015s
token vectors=17  dim=512  first5=[-0.0672, 0.0263, 0.0497, -0.0064, -0.0424]
```

**A trap worth recording, because it cost me a run:** `requestAssets(completionHandler:)`
delivers its callback on the **main queue**. My first attempt blocked the main thread on a
`DispatchSemaphore` and the handler never fired — 420 s, no callback, and
`hasAvailableAssets` still `false` at the point I checked. The download *was* happening
underneath. Drive it from `RunLoop`, or use the `async` form. A CLI that naively
`semaphore.wait()`s on this deadlocks, and the symptom (silence, then "Failed to locate
embedding model") looks exactly like "Apple doesn't support Russian".

**What actually landed on disk** —
`/System/Library/AssetsV2/com_apple_MobileAsset_LinguisticData/49c15266…asset`:

```
Info.plist:  AssetLocale = "mul_Cyrl",  Contents[0] = { ContentPath: "mBERT.bundle",
                                                        ContentType: "Embedding" }
mBERT.bundle/modelInfo.plist:
    VersionString          = "mBERT_cyrl "
    EmbeddingDimension     = 512
    MaximumSequenceLength  = 256
    EmbeddingNodeNameOnANE = "embedding_out"
mBERT.bundle/metadata.json:
    storagePrecision = "Mixed (Float16, Int8)"
    outputSchema     = MultiArray (Float32 1 × 256 × 1 × 512)  ["mlm_embeddings"]
    ops include 6 × softmax, 96 × einsum, 36 × conv   → a small (~6-layer) transformer
mBERT.bundle/sp.dat  (587 KB)  → SentencePiece subword vocabulary
```

**63 MB on disk**, and — the part that matters for criterion 4 — **it is not our 63 MB.** The
OS downloads it, the OS stores it, it is shared with every other app that asks, and our binary
gains nothing. There is no SwiftPM dependency, no model to host, no first-run bundle to ship.
`EmbeddingNodeNameOnANE` says it runs on the Neural Engine.

**This changes the Phase 3 plan in `Design.md` and supersedes option 2 of
`morphology-and-embeddings.md`'s verdict.** MLX is no longer "the only route to semantic search
over Russian". There is a zero-dependency, zero-download-for-us, ANE-accelerated Russian
embedding in the OS, and this project was one API class away from it.

### Verified: it is usable for similarity — but *only* after mean-centering

Apple's header warns against using this class for similarity, so I measured rather than assumed.
Six Russian sentences: two paraphrase pairs (0↔1 SwiftUI navigation, 3↔4 soup), one same-topic
pair (0↔2), and cross-topic pairs that should score low. Mean-pooled over subword vectors,
L2-normalised, plain cosine:

```
        0     1     2     3     4     5
 0  1.000 0.976 0.809 0.898 0.918 0.934
 1  0.976 1.000 0.798 0.908 0.912 0.936
 2  0.809 0.798 1.000 0.691 0.708 0.735
 3  0.898 0.908 0.691 1.000 0.977 0.910
 4  0.918 0.912 0.708 0.977 1.000 0.922
 5  0.934 0.936 0.735 0.910 0.922 1.000

related pairs:   min 0.809  mean 0.921
unrelated pairs: max 0.934  mean 0.849      margin = −0.125   NOT separated
```

**Raw cosine does not work.** Everything sits in 0.69–0.98 — the textbook anisotropy of a BERT
encoder that was never trained with a similarity objective. Concretely: "how to set up SwiftUI
navigation" scores **0.934** against "a subscription costs 500 ₽/month" (unrelated) but only
**0.809** against "NavigationStack replaced NavigationView" (same topic). A raw-cosine threshold
would rank the wrong post first. Apple's warning is earned.

**Mean-centering fixes it completely.** Subtracting the corpus-mean vector before normalising —
the standard fix, Mu & Viswanath's "all-but-the-top" preprocessing, of which centering is step
one — flips the result:

```
plain mean-pool      related[min 0.809]  unrelated[max 0.934]  margin −0.125  SEPARATED: no
centered             related[min 0.639]  unrelated[max 0.228]  margin +0.410  SEPARATED: YES
centered + ABTT(1)   related[min −0.357] unrelated[max −0.035] margin −0.322  SEPARATED: no
```

Related pairs 0.64–0.78; unrelated pairs −0.36…+0.23. **A clean, wide, thresholdable gap.**
Removing the top principal component *as well* over-corrected here — but my background set was
16 sentences, far too few for a stable PC, so read that row as "not established", not as
"ABTT is harmful". Centering alone is enough and is the safe recommendation.

**Design consequence:** store the corpus mean vector in the database as part of the index (it is
512 doubles), recompute it on full reindex, and have **both** processes subtract it — the writer
when indexing, the reader when embedding a query. This is exactly the same class of hazard as
the custom-tokenizer skew already rejected in `Design.md`: if the two processes centre against
different means, similarity silently degrades rather than erroring. Store the mean *in the
database*, never recompute it independently in the reader.

### Verified: the two scripts are two models, and their vector spaces do not meet

This is the finding that constrains the design most, and it is not obvious from the API.

```
CROSS-SCRIPT ru↔en:  related pair  −0.007      unrelated pair  −0.022
```

`NLContextualEmbedding(script: .cyrillic)` and `(script: .latin)` are **different model
identifiers** (`FCDCF262-…` vs `5C45D94E-…`), separately trained, with **unrelated coordinate
systems**. "Как настроить навигацию в SwiftUI приложении" and "How to set up navigation in a
SwiftUI app" score −0.007 — indistinguishable from noise. This is *not* a multilingual aligned
space like LaBSE or multilingual-e5; it is three monolingual-ish encoders that happen to share a
class.

For this corpus — explicitly mixed Russian and English, routinely **in the same post** — that is
a real limitation:

- A Russian query cannot retrieve a semantically-matching English post, or vice versa.
- Posts mixing scripts must be routed to one model or split by sentence.
- Two vector indexes, two corpus means, and no cross-space ranking.

An **aligned** multilingual model (multilingual-e5, LaBSE, paraphrase-multilingual-MiniLM) puts
both languages in one space and does not have this problem. **That, and not "Apple has no
Russian model", is the actual argument for MLX.** It is a much narrower argument than
`morphology-and-embeddings.md` had to make, and it should be tested against real golden queries
before it is paid for.

### Verified: indexing throughput

200 short Russian posts, embedded and mean-pooled serially, cold-ish:

```
2.71 s  →  73.9 posts/s  →  100k posts ≈ 23 minutes
```

Load time `0.44 s`; a single 17-token sentence `0.015 s`. Serial, single-threaded, no batching.
**23 minutes for a full one-time reindex of the worst-case corpus is affordable**, and it is a
background job on the writer, not on the MCP read path. Query-time embedding is ~15 ms, which
disappears next to an LLM round-trip. Memory was not measured.

### Multilingual models on-device, if you decide the aligned space is worth paying for

Sizes below are **measured** from the HuggingFace API (`?blobs=true`), not estimated; licences
from each model's card metadata; dimensions from each `config.json`.

| model | dim | layers | vocab | `model.safetensors` | licence |
|---|---|---|---|---|---|
| `intfloat/multilingual-e5-small` | 384 | 12 | 250,037 | **449 MB** | MIT |
| `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` | 384 | 12 | 250,037 | **449 MB** | Apache-2.0 |
| `intfloat/multilingual-e5-base` | 768 | — | 250,037 | **1,061 MB** | MIT |
| `sentence-transformers/LaBSE` | 768 | 12 | 501,153 | **1,796 MB** | Apache-2.0 |
| `intfloat/multilingual-e5-large` | 1024 | — | 250,037 | **2,136 MB** | MIT |
| `BAAI/bge-m3` | 1024 | — | — | **2,166 MB** (`pytorch_model.bin`) | MIT |
| `jinaai/jina-embeddings-v3` | 1024 | — | — | 1,092 MB | **CC-BY-NC-4.0** |

Three things worth pulling out of that table:

1. **`jina-embeddings-v3` is non-commercial (CC-BY-NC-4.0).** For a project that maintains a hard
   licence wall (`Design.md`: "never vendor code from Telegram-iOS … both are GPLv2"), this is a
   landmine, and it is the model most likely to be recommended by a casual search. Rule it out
   explicitly.
2. **The two 384-dim models are both 449 MB, and almost all of that is vocabulary, not
   computation.** 250,037 XLM-R tokens × 384 dims × 4 bytes ≈ 384 MB of the 449 MB is the
   embedding matrix alone. This is why "small" multilingual models are not small.
3. **Quantization helps, but not enough to change the verdict.**
   `mlx-community/multilingual-e5-small-mlx` weighs **224 MB**;
   `mlx-community/multilingual-e5-large-mlx` weighs **1,068 MB**.

**Best single option if you go this route: `intfloat/multilingual-e5-small`** — 384 dims, MIT,
449 MB (224 MB quantized), ~100 languages in **one aligned space**, and it is already in
MLXEmbedders' registry:

```swift
/// Multilingual E5 Small - supports over 100 languages.
public static let multilingual_e5_small = ModelConfiguration(id: "intfloat/multilingual-e5-small")
```

At 384 dims the `sqlite-vec` storage cost also drops: 100k × 384 × 4 B ≈ 150 MB float32,
≈ 38 MB int8, ≈ 6 MB binary — extrapolating linearly from the 512-dim measurements above.

### The realistic cost of MLX Swift as a dependency

- **Packages.** `ml-explore/mlx-swift` (MIT, latest tag **0.31.6** 2026-07-02, pushed
  2026-08-20) plus `ml-explore/mlx-swift-lm` (MIT, pushed 2026-08-22, 785 stars), which is where
  `MLXEmbedders` now lives — it moved out of `mlx-swift-examples`, whose `Libraries/` now holds
  only `MLXMNIST` and `StableDiffusion`. Anything written against the old location is stale.
- **Build cost is the real tax, and it is not in the repo size.** `mlx-swift`'s `Package.swift`
  compiles MLX's **C++ sources and Metal shader backend from source** as SwiftPM targets
  (`mlx/mlx/backend/metal/*.cpp`, dozens of files, plus Metal kernels). The 6 MB repo figure is
  misleading; this is a long cold build and a Metal-toolchain dependency in CI. Compare against
  the incumbent, where the engine is `/usr/lib/libsqlite3.dylib` and the build cost is zero.
- **Model distribution.** 449 MB (or 224 MB quantized) that **this project would have to ship or
  download**, versus 63 MB that **the OS downloads and shares**. `Design.md` trait-gates a
  343 MiB artifact specifically to keep it off consumers; taking on a mandatory 449 MB model
  download for the *read-only* half of the system is the same mistake in a new place.
- **First-run latency and memory.** Not measured — model download plus a cold MLX/Metal
  initialisation. Flagged as unverified below.

**Weighed against a 63 MB OS-managed asset that loads in 0.44 s and embeds at 74 posts/s, MLX
buys exactly one thing: a single aligned ru+en vector space.** That is a real benefit for this
mixed-language corpus, and it is the *only* benefit. It should be bought with evidence from the
golden queries, not in advance.

### How to wire hybrid retrieval — and what the literature actually says at this scale

**Same store, same transaction.** With `sqlite-vec` static-linked, the vector index is a `vec0`
virtual table in the *same* SQLite file as `post`, `post_ft` and `post_tri`. That preserves every
property already verified: one file, one WAL, one read-only pool, one migrator, the reader still
sees a consistent snapshot, and `tgkb doctor` still has one thing to check. A separate vector
index would mean two files that can disagree, two crash-recovery stories, and a new class of
"the vectors are stale relative to the text" bug. **Do not add a second store.**

**Fuse with RRF, not with score arithmetic.** The canonical source is Cormack, Clarke & Büttcher,
*"Reciprocal Rank Fusion outperforms Condorcet and individual Rank Learning Methods"*,
SIGIR 2009, pp. 758–759. The formula, verbatim from the paper:

> RRFscore(d ∈ D) = Σ_{r∈R} 1/(k + r(d)),
> where k = 60 was fixed during a pilot investigation and not altered during subsequent validation

and the finding that matters here:

> RRF, when used to combine the results of IR methods (including learning to rank), almost
> invariably improved on the best of the combined results.

**Why RRF and not weighted score fusion, specifically for this project:** BM25 and cosine are not
commensurable. `grdb-fts5.md` already recorded that FTS5's `bm25()` returns *negative* scores of
unbounded magnitude, and this pass measured that raw `NLContextualEmbedding` cosines all sit in
0.69–0.98. Normalising two such distributions onto a common scale requires corpus statistics that
change every sync. **RRF needs only the rank order**, so it is immune to both problems — and it
is one `Dictionary<PostID, Double>` of arithmetic, not a tuning exercise.

**What the literature recommends at *this* corpus size** — this is the part worth being blunt
about. RRF's evidence base is TREC and LETOR: large collections, many systems, careful relevance
judgements. A 10k–100k-post single-user Telegram archive is none of those. Two honest
consequences:

1. **k = 60 is not a law.** It was "fixed during a pilot investigation" on TREC-scale data. On a
   result list of 20 items, k = 60 flattens the ranking almost to uniform — the reciprocal terms
   for ranks 1 and 20 differ by only 1/61 vs 1/80. **A smaller k (10–20) is more appropriate for
   short result lists**, and this is a parameter to fit against the golden queries, not to
   inherit.
2. **The `evals/` golden-query harness is the only authority that matters here.** This project
   already has one, and it has already caught a real parser bug (`Design.md`). Hybrid ranking
   should be judged by it, exactly the way the dual-index decision was.

**Concrete recommended shape**, when Phase 3 arrives:

```
1. post_ft   (unicode61)  MATCH pattern  ORDER BY rank   LIMIT 50   → ranked list A
2. post_tri  (trigram)    MATCH substring                LIMIT 50   → ranked list B   (opt-in)
3. post_vec  (vec0 float[512])  embedding MATCH q AND k=50          → ranked list C
   where q = L2normalise(meanPool(NLContextualEmbedding(query)) − corpusMean)
4. RRF-fuse A, B, C with a fitted k; return top 10 with snippet() from post_ft.
```

Step 3's `corpusMean` is stored in the database, written by `tgkb`, read by `tgkb-mcp` — never
recomputed independently, for the reason given in the centering section above.

**Phase it.** FTS5 alone → measure. Add `NLTagger` lemmas → measure. Only then add vectors →
measure. Each stage is independently useful, and the golden queries will say whether the next one
earns its keep. There is no need to decide the whole stack now, and the vector column can be
added by a forward-only migration without touching anything already shipped.

---

## Verified / Unverified

### Verified — probed on this machine (macOS 26.5.2 / 25F84, Swift 6.3.3, arm64, system SQLite 3.51.0)

- `NLEmbedding.supportedRevisions(for: .russian)` and `.ukrainian` are **empty**; `.english`
  returns `[1]` (word 300-dim, sentence 512-dim). No Russian `NLEmbedding` exists to enable.
- `NLContextualEmbedding(script: .cyrillic)` resolves — model `FCDCF262-…`, **512 dims**,
  **256-token** limit, revision 1, languages `[bg, kk, ru, uk]`. Latin is `5C45D94E-…` (20
  languages), CJK `12784592-…`.
- The Cyrillic asset **downloads and works**: `requestAssets → available`, `load()` in 0.44 s,
  `embeddingResult(for:language:)` returns 17 token vectors for a 55-character Russian sentence
  in 15 ms.
- On disk it is `AssetLocale = mul_Cyrl`, `mBERT.bundle`, `VersionString = "mBERT_cyrl "`,
  `EmbeddingDimension = 512`, `MaximumSequenceLength = 256`, `EmbeddingNodeNameOnANE`,
  `storagePrecision = "Mixed (Float16, Int8)"`, SentencePiece vocab — **63 MB** under
  `/System/Library/AssetsV2/com_apple_MobileAsset_LinguisticData/`.
- `requestAssets(completionHandler:)` delivers on the **main queue**; blocking the main thread
  on a semaphore deadlocks it (420 s, no callback) while the download proceeds underneath.
- Mean-pooled raw cosines are anisotropic and **do not** separate related from unrelated
  (margin −0.125). **Mean-centering does** (margin +0.410). Centering + removing the top PC
  over-corrected, but on a 16-sentence background set.
- Cyrillic↔Latin cross-model cosine is **−0.007 / −0.022** — the two spaces are unrelated.
- Throughput 200 short Russian posts in 2.71 s = **73.9 posts/s** ⇒ 100k posts ≈ 23 min.
- macOS `/usr/lib/libsqlite3.dylib` is built with `OMIT_LOAD_EXTENSION`; `sqlite3_load_extension`
  and `sqlite3_enable_load_extension` are **absent**, `sqlite3_auto_extension` is present but
  returns **`SQLITE_MISUSE` (21)** — the SDK header states process-global auto extensions are
  not supported on Apple platforms.
- `sqlite-vec` v0.1.9 amalgamation, compiled `-DSQLITE_CORE` against stock `-lsqlite3`, works via
  a **direct per-connection `sqlite3_vec_init(db, &err, NULL)`** — `vec_version`, `vec0` tables
  with `float[512]`/`int8[512]`/`bit[512]`, `partition key` and `+aux` columns, correct kNN.
- Benchmark, 100k × 512, k=10, best-of-10: float32 **71 ms / 198.5 MB**, int8 **46 ms /
  51.2 MB**, bit **2.0 ms / 8.3 MB**; inserts 56k–123k rows/s.

### Verified — primary sources

- `NLContextualEmbedding.h`, macOS 26.5 SDK — language/script coverage, the asset-download
  contract, the subword-pooling requirement, and the "for semantic similarity, consider using
  `NLEmbedding`" note. Quoted in place.
- `asg017/sqlite-vec` — v0.1.9 released 2026-03-31 (`prerelease: false`), amalgamation asset
  54 KB gzipped / 10,199 LOC; `site/versioning.md` and README state pre-v1 breaking-change
  policy; `sqlite-dist.toml` declares `license = "MIT OR Apache-2.0"` and an `spm` target;
  `LICENSE-MIT` and `LICENSE-APACHE` both present (there is no plain `LICENSE`).
- DuckDB concurrency documentation — "one process can both read and write" / "multiple processes
  can read from the database, but no processes can write"; multi-process writes only via the
  beta Quack remote protocol.
- `duckdb/duckdb-swift` — MIT; **every tag is `vN.N.N-devNNNNN`, no stable tag**; builds DuckDB
  C++ in a SwiftPM target.
- `realm/realm-swift` README — "We announced the deprecation of Atlas Device Sync + Realm SDKs in
  September 2024"; latest v20.0.5 (2026-06-14), not archived, 499 open issues.
- Release assets: Meilisearch v1.53.1 macOS arm64 **116.3 MB**; Qdrant v1.19.0 macOS arm64
  **26.3 MB**; Typesense v30.2 ships no macOS asset; Tantivy 0.26.1 (2026-05-10).
- HuggingFace API model sizes and licences, and `config.json` dimensions, as tabulated.
- `ml-explore/mlx-swift` MIT, tag 0.31.6; `ml-explore/mlx-swift-lm` MIT, hosts `MLXEmbedders`
  with `multilingual_e5_small` and `bge_m3` registered; `mlx-swift`'s `Package.swift` compiles
  MLX C++/Metal from source.
- Cormack, Clarke & Büttcher, SIGIR 2009 — RRF formula and `k = 60` "fixed during a pilot
  investigation", quoted from the paper PDF.
- DeepWiki (`asg017/sqlite-vec`, index pinned at 04d28bd2, 2026-05-18) corroborated the pre-v1
  status, licence, SPM target, and that IVF/DiskANN exist but are compile-time gated. Its claim
  about macOS extension loading was an inference from the Python docs; my symbol probe is the
  stronger evidence and agrees.

### Unverified — could not probe, or deliberately out of scope

- **Retrieval quality of `NLContextualEmbedding` on the real corpus.** Six hand-written sentences
  established that centering separates related from unrelated. They say nothing about nDCG on
  the golden queries. **This is the measurement that should decide Phase 3**, and it needs the
  crawled corpus, not a probe.
- **A stable corpus mean.** Estimated from 16 sentences. The real mean must come from the corpus,
  and how much it drifts between syncs (and whether that forces reindexing) is unknown.
- **Binary quantization combined with mean-centering.** Both measured separately; the combination
  — quantizing the *centred* vectors and whether recall survives — is untested.
- **Two-stage `bit` → `float` rescoring recall.** Attractive on the numbers (8.3 MB, 2 ms) but no
  recall measurement was made.
- **MLX first-run latency, memory footprint, and cold build time.** Not measured. The build-cost
  claim rests on reading `Package.swift`, not on running a build.
- **`sqlite-vec` under GRDB specifically**, and under two processes. I probed the C layer. The
  `prepareDatabase` wiring is a one-line inference from `grdb-fts5.md`'s verified account of that
  hook, and the cross-process behaviour of `vec0` shadow tables under WAL was **not** tested.
  Worth a probe before committing, on the same grounds the tokenizer question was.
- **`NLContextualEmbedding` asset availability on a fresh machine / offline.** The Cyrillic asset
  was absent here until requested, so a first run needs network. Behaviour under a metered or
  offline connection, and whether the asset can be evicted by the OS, is untested — a real
  operational question for `tgkb doctor`.
- **Whether the Latin model should be used for English posts at all**, given the two spaces do
  not meet. Untested; the alternative (index everything with the Cyrillic model, or skip
  semantics for English) was not measured.
- **DuckDB's Quack protocol** was not investigated beyond the doc sentence; it is a daemon and
  therefore already excluded by criterion 6.
- **Typesense's macOS story** — no GitHub release asset; whether it distributes via Homebrew or
  Docker only was not checked, because criterion 6 excludes it regardless.
- **Core Data / SwiftData multi-process specifics** (persistent history tracking, remote-change
  notifications). Not probed — both were excluded on the FTS/vector criteria before concurrency
  mattered.
