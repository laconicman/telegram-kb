# Research

The Verified / Unverified ledger. Full notes live in `research/`; this is the condensed index of
what is actually known, and — more importantly — what is not.

A claim is **Verified** only if traced to a primary source: upstream repository source, official
documentation, or an empirical probe run for this project. Everything else is marked.

## Verified

### Web preview — `research/web-preview-probe.md`
Probed directly, 2026-08-23. Reproducible via `research/probe.sh`.

- Reactions are present with exact counts, including paid/star and ZWJ sequences. 20/20 messages
  on a sample page carried them; 76/136 across a full channel.
- History reaches message id 1. A complete 136-post backfill took 10 pages and ~10 seconds.
- `https://t.me/robots.txt` returns **HTTP 404** — no robots.txt exists.
- 40 back-to-back requests, zero delay: all HTTP 200, no throttling. ~2.8 s/request server-side
  latency is the binding constraint.
- Link previews carry Telegram's resolved OG metadata (site, title, description, canonical URL).
- Post ids are non-contiguous (54% of the id space absent) and page size varies (5–20). Page by
  returned ids, never by count or stride.
- An undocumented `?q=` search endpoint works without login and composes with pagination.
- Server-side search has **no substring matching**; its normalisation is **opaque** —
  `anim`≡`animation`≡`animations` (15 hits) but `animat`≡`Animatable` (a different 2).

### Search quality, measured — `research/web-preview-probe.md`
- FTS5 `trigram` solves substring (`imation`: 0 → 14) and short prefixes (`навига`: 0 → 3).
- **FTS5 loses to Telegram on Russian inflection**: `навигация*` misses a post containing
  *навигации*. This is `TD-4`, quantified.

### Storage — `research/sqlite-cross-process-probe.md`, `research/grdb-fts5.md`
- Cross-process reader + writer: 60/60 reads succeeded, monotonic, zero errors. FTS5 `MATCH`
  works from a read-only connection in a separate process.
- `mode=ro` **fails** on a WAL database when the directory is not writable (`-shm` creation).
  `immutable=1` avoids it but is only sound with no writer running.
- A `SIGKILL`-ed writer leaves recoverable state; no manual repair needed.
- GRDB links the **system** `libsqlite3` under SwiftPM — confirmed independently by `otool -L`
  on our own built binary. The FTS5 measured on this machine is the FTS5 GRDB gets.
- `trigram` needs no custom build: `FTS5TokenizerDescriptor(components: ["trigram"])`.
- A connection lacking a custom tokenizer fails at *step* time with `no such tokenizer`.

### Packaging — `research/spm-traits-binarytarget.md`
- **SwiftPM traits gate `binaryTarget` downloads.** Trait off: no download, and
  `show-dependencies` reports the dependency absent from the graph. Verified with a control.
- Scaffold builds clean; `Scripts/check-invariants.sh` passes.

### TDLib — `research/tdlib-td.md`
- ID transforms verified from source and spot-checked independently:
  `message_id = post_seq << 20` (`MessageId.h:27,:60`);
  `chat_id = -1000000000000 - channel_id` (`DialogId.h:27`, `DialogId.cpp:58,:84`).
- `searchChatMessages` has **no** `min_date`/`max_date`; global `searchMessages` has both but
  takes a `ChatList`, not a `chat_id`. Per-channel date filtering must live in our store.
- No reaction search outside Saved Messages tags (Premium).
- `updateMessageReaction`/`updateMessageReactions` are **bots-only**; use
  `updateMessageInteractionInfo`.
- `getChatHistory` is `CHECK_IS_USER()` — bots cannot backfill.
- `FLOOD_WAIT` is auto-retried under a ~60 s budget; what surfaces is code 429 with
  `retry after N` in the **message string** — there is no structured `retry_after` field.
- `updateDeleteMessages(from_cache: true)` is **not** a deletion.

### Toolchain — `research/mcp-swift-sdk.md`, `research/swift-argument-parser.md`, `research/swift-docc-plugin.md`
- MCP swift-sdk **0.12.1**, implements spec **2025-11-25**, negotiates down.
- Tool input schemas are **hand-authored JSON `Value` trees** — no DSL, no Codable derivation.
- Tool annotation defaults when omitted are `destructive: true`, `openWorld: true` — read-only
  tools must set them explicitly.
- **stdout is the protocol.** The spec forbids non-MCP bytes on stdout; the SDK README's own
  logging example writes to stdout and would break a stdio server.
- swift-argument-parser 1.8.2; root command must be `AsyncParsableCommand` and must not live in
  `main.swift`.
- swift-docc-plugin 1.5.0; a docs-only target needs only a comments-only source file — **no
  dummy public symbol**. Confirmed by our own building scaffold.
- SwiftSoup 2.13.7 (2026-07-23); ~26 ms per 159 KB page. **`text()` silently drops `<br/>`.**

### Binary artifact — `research/Swiftgram-TDLibFramework.md`
Measured from the shipped zip's central directory via an HTTP range request — actual bytes.

- Download **343 MiB**; **unzipped 1.33 GiB** (3.97× expansion); SPM keeps both, so **≈1.7 GiB
  per resolved version**. The brief's "~300 MB" understates the download and omits the
  expansion entirely.
- Largest slice is `watchOS` (245 MiB), which we never run; `macos-arm64_x86_64` is 13.5% of the
  bundle. A macOS-only build is **feasible without forking** — the pipeline is already
  platform-parameterised (`TUIST_PLATFORM`) because CI shards on it. ~7.4× reduction.
- OpenSSL is **statically vendored**; zlib and libc++ come from the platform SDK.
- The release-body checksum **is** the SPM `binaryTarget` checksum, byte-identical, produced by
  `swift package compute-checksum`. Downstream can pin without downloading.
- Only the four *simulator* slices carry `_CodeSignature`; there is no `codesign` step in CI.
- TDLibKit's `Package.swift` is **generated** and pins the framework `.exact(...)`.

### Prior art — `research/prior-art-telegram-mcp.md`
Seven Telegram MCP servers surveyed.

- **None has a full-text index of any kind.** The only one with a persistent store queries it
  with `LIKE`; a grep for `fts5|MATCH` returns nothing.
- **None emits a `t.me` deep link**; one drops the message id from its response entirely.
- **Neither primary target has any rate-limit/FLOOD_WAIT code at all** (verified by grep).
- All four serious projects punt interactive login to a separate CLI step, and all four store
  the session **unencrypted**.

### Morphology and embeddings — `research/morphology-and-embeddings.md`
- **`NLTagger` lemmatises Russian correctly**, nouns and verbs, when the language is set
  explicitly. Closes the measured `TD-4` gap.
- **Without an explicit language, a single Russian word silently yields no lemma** — including
  the nominative form.
- **`NLEmbedding` is nil for Russian** (`supportedRevisions` is the empty set) — but
  **`NLContextualEmbedding(script: .cyrillic)` covers ru/bg/kk/uk**, 512 dims, OS-provided and
  OS-shared asset, zero packaging cost. My first write-up said Apple had nothing for Russian;
  that generalised one API into the platform and was **wrong**. `TD-9`.
- **Storage engines reviewed; SQLite + GRDB retained.** DuckDB fails the two-process criterion by
  its own documentation; Meilisearch/Typesense/Qdrant are daemons; Tantivy buys stemming
  `NLTagger` already provides. `sqlite-vec` does 100k × 512 in 71 ms. macOS system SQLite is
  built `OMIT_LOAD_EXTENSION`, so `sqlite3_vec_init(db, …)` must be called directly.
- Unknown tokens (`Animatable`) return no lemma and should be indexed verbatim — which also
  explains Telegram's observed bucketing without having to guess its algorithm.

### Target channels — classified 2026-08-24
Four of six are Phase-1 reachable; two need TDLib.

| Channel | `/s/` | Verdict |
|---|---|---|
| `@iosgr` (12,081 subs) | 200 | previewable |
| `@iosdev` (7,879 subs) | 200 | previewable |
| `@ios_broadcast` (3,500 subs) | 200 | previewable |
| `@prefire_ios` (980 subs) | 200 | previewable |
| `@iosmmcresources` (1,757 subs) | 302 | **broadcast channel with the preview disabled** — Phase 2 |
| `@AllByiOS` (409 *members*) | 302 | **a group, not a channel** — Phase 2 |

This also **settles a previously-unverified question**: channel owners *can* disable the web
preview — `@iosmmcresources` is a genuine broadcast channel with subscribers whose `/s/` still
302s. And "N members" vs "N subscribers" in `tgme_page_extra` distinguishes a group from a
channel, making the classifier four-way rather than three.

### The real corpus, and Telegram's result cap — crawled 2026-08-24
Full histories of the four previewable channels: **7,406 posts**, 2016→2026, **90%
Russian-dominant**, **95% carrying a link** (16,789 links, 11,665 unique, 479 shared across
channels), 164,747 reactions, 3.38 MB of body text.

- **Telegram's channel search caps at ~22 results per query.** For `архитектура` on `@iosgr`:
  **206** literal matches in the channel, **22** surfaced. Verified across five terms; the one
  term with fewer than 22 matches (`верстка`) returned uncapped and missed nothing, which is what
  rules out an index-horizon explanation. **The archive is effectively unsearchable through
  Telegram for any common term** — this is the project's strongest justification, and it is a
  completeness problem, not the precision problem the brief assumed.
- **Lemma index vs prefix index**, same channel: `навигация` 36 vs 11, `архитектура` 152 vs 54,
  `анимация` 77 vs 25. Lemmatisation roughly doubles recall.
- **Lemmatisation costs ~10.7 s per 4,326 posts** (~404/sec) — cheap enough to do at index time,
  which closes the throughput question.
- **`unicode61 remove_diacritics 2` does not fold ё→е.** Verified directly. 5% of `@iosgr` posts
  contain ё. `TD-10`.
- **Link-preview descriptions carry matchable text the body does not** — one post matched
  Telegram's search only via its preview description. Index previews as first-class text.

### Full research index

Every note in `research/`, with what it settles. Read these rather than re-deriving.

| File | Settles |
|---|---|
| `web-preview-probe.md` | `t.me/s/` structure, pagination, reactions, the ~22 result cap, search semantics |
| `morphology-and-embeddings.md` | `NLTagger` on Russian, `NLContextualEmbedding`, the ё/е and preview-indexing findings |
| `sqlite-cross-process-probe.md` | Reader/writer across processes; the WAL `mode=ro` trap |
| `grdb-fts5.md` | Which SQLite GRDB links; FTS5/trigram; `FTS5Pattern`; multi-process stance |
| `storage-engine-options.md` | Why SQLite + GRDB stays; `sqlite-vec`; on-device embedding options |
| `spm-traits-binarytarget.md` | Traits gate artifact downloads — and the `dump-symbol-graph` hole |
| `tdlib-td.md` | ID transforms, date asymmetry, reactions, `FLOOD_WAIT`, update semantics |
| `Swiftgram-TDLibKit.md` | The Swift wrapper: codegen, client lifecycle, the `.exact` pin contract |
| `Swiftgram-TDLibFramework.md` | Artifact size (343 MiB / 1.33 GiB), slices, OpenSSL vendoring, slim builds |
| `mcp-swift-sdk.md` | SDK version, tool-schema authoring, the stdout-is-the-protocol footgun |
| `swift-argument-parser.md` | CLI subcommand structure, exit codes |
| `swift-docc-plugin.md` | Docs-only target wiring, `.spi.yml` |
| `swiftsoup.md` | Parser choice, performance, the `text()` drops-`<br/>` trap |
| `prior-art-telegram-mcp.md` | Seven Telegram MCP servers; the gap; what to copy |
| `xcframework-skill-addendum.md` | Proposed additions to the `xcframework-distribution` skill (for review) |
| `link-content-fetching.md` | Fetch/parse/extract stack; per-domain shortcuts; what is reachable |
| `BRIEF-link-content-fetching.md` | The task brief that produced the above (for re-running) |
| `skills-landscape.md` | Agent skills for the non-Swift domains: what exists, why almost none fits |

Reproducible probes live alongside them: `probe.sh`, `crawl_corpus.py`, `lemmatize.swift`.

### Link content — `research/link-content-fetching.md`
From ~100 live requests; the four shortcuts re-verified independently by me.

- `developer.apple.com/documentation` HTML is a JS shell (**989** text chars); the
  `tutorials/data/….json` endpoint returns **148,400**. WWDC video pages already carry the full
  transcript in plain HTML (**36,014** chars).
- GitHub: `raw.githubusercontent.com/…/HEAD/README.md` beats scraping (32 KB clean vs a 545 KB
  page); the REST API is unusable at 60 req/hr.
- **Headless `WKWebView` works in a plain CLI with no app bundle** (1.9–14.8 s/page) — verified
  but not adopted, since the domain that motivated it has a JSON API.
- `Fuzi` is dead (2020); `exyte/ReadabilityKit` is archived; `mrowlinson/jusText-swift` is
  **unlicensed** — port from the BSD-2-Clause Python original instead. `TD-13`.
- `clck.ru/robots.txt` is `Disallow: /` with `Allow: /$`. Verified.
- **~60% of unique external URLs yield ≥1,000 chars** on a plain fetch, ~70% with the shortcuts.

### The `artanl` seam — synchronised 2026-09-03
A sibling project (the local-LLM article analyzer) owns article fetching and tagging; this
project owns Telegram ingestion, the post grain, FTS and search. They join on `url_canonical` —
one spec implemented twice, with a shared fixture list. See <doc:Design>.

- The analyzer's **fetch tier ladder** bottoms out at **Telegram's own preview metadata, which
  this project stores** — so no URL ever yields nothing. Our data is its floor.
- Extraction there is Python + `trafilatura`, which retires `TD-13` for us.
- `searchMessagesFilterUrl` is a **server-side** "messages containing a URL" filter: a channel's
  link-bearing posts can be enumerated without walking its whole history.
- `SearchMessagesFilter`'s 20 variants give a free, deterministic `format` label from TDLib — but
  web-sparse, per the probe above.

## Unverified

Carried forward deliberately. Do not build on these without probing first.

- **End-to-end ID reconciliation against a live TDLib client.** `TD-8`; the Phase 2 gate.
- ~~Forwarded markup.~~ **Answered** — present at ~1.3% of posts, carrying origin channel,
  origin post id *and* the original author's name, so attribution for forwards is *better* than
  for ordinary posts. Polls likewise present (~1.3%) with question, options and vote count.
  Document, audio, voice, sticker, location and round video are **absent from ~868 sampled
  message blocks** across all four reachable channels — absent from this corpus, not merely
  unlooked-for. The parser's branches for those kinds are written but **untested against real
  markup**, and stay speculative until TDLib.
- ~~Whether channel owners can explicitly disable the web preview.~~ **Answered** —
  `@iosmmcresources` is a genuine broadcast channel (1,757 subscribers) whose `/s/` still 302s,
  so owners can disable it. "N members" vs "N subscribers" separately distinguishes a group from
  a channel, making the classifier four-way.
- ~~What a disabled preview withholds.~~ **Answered** — the *frame*, not the content.
  Single-post embeds still return 200 with author, date, views, reactions and forward origin
  (11/11), but **no body text (0/11)** and no media, where enabled channels show both. So
  `previewDisabled` is not `unresolvable` — metadata is reachable — but it cannot serve content.
  `@iosmmcresources`, chosen for its files, is therefore Phase 2 work.
- **Where Telegram's actual rate limit is.** Substantially answered in practice: a full backfill
  of four channels — 7,406 posts over ~480 page requests at a 1 s delay — completed with no
  throttling, no 429s, no challenges. Still not a probe *for* the limit, but casual crawling at
  real corpus scale is now demonstrated rather than extrapolated.
- **Whether `?q=` is stable or supported.** Undocumented; used as a test oracle only.
- **HTML stability over time** — single point in time, no churn estimate. `TD-1`.
- **Trait gating under Xcode's resolver**, as opposed to the SwiftPM CLI.
- **Whether a macOS-only slim TDLibFramework build actually produces a usable artifact.** Read
  from CI configuration; not executed.
- **`gotd/td` and `Telethon` were deliberately not researched.** Their questions — MTProto
  date-bound parameters, and what server-side search really matches — were answered more
  directly: the first from TDLib's own TL scheme, the second by probing Telegram's live search
  myself. A pass over them would now be confirmatory rather than decisive. Flagged as a
  conscious omission, not an oversight.
- **Scale.** Storage results are from 60-row samples; retrieval results now come from a real
  7,406-post corpus. Nothing yet speaks to WAL growth during a long backfill or checkpoint
  starvation under a concurrent reader.
- **Whether mean-centering helps or hurts embedding rank quality.** The storage research measured
  raw cosine inverting and centering fixing it; my own probe measured the opposite sign. My mean
  was over 8 sentences — far too few to be representative. Unresolved; settle on the real corpus.
- **The fetchable fraction (~60/70%) is extrapolated from n=40** and flagged Unverified at that
  precision. Re-measure at n≈400 before sizing the work.
- **How Telegram matched two posts we cannot explain** (`TD-11`) — no occurrence of the term in
  the body, preview title, or preview description we captured. Candidates: linked-page content,
  semantic expansion, or media metadata we drop. Load-bearing for how much link-target content
  Phase 3 ingests.
- **No build of any dependency under Swift 6.3 strict concurrency beyond the scaffold**, which
  has no real code in it yet.

## See Also

- <doc:Design>
- <doc:TechDebt>
- <doc:Roadmap>
