# telegram-kb

A searchable knowledge base built from Telegram channels, exposed to Claude over MCP.

Useful articles, libraries and documentation get shared in Telegram channels and then become
unfindable: Telegram's search cannot match substrings, normalises queries opaquely and returns
at most about 22 results. `telegram-kb` crawls public channels into a local SQLite index. That
index handles Russian inflection, ё/е spelling and partial words, and every result cites its
`t.me` post.

**The direction documents in the DocC catalogue are authoritative.** They outrank this README
and any code comment:

- `Design`: decisions, with the rejected alternatives
- `Roadmap`: slices S0–S6, then Phases 2–4
- `TechDebt`: numbered `TD-n` entries
- `Research`: a Verified / Unverified evidence ledger

```bash
swift package --disable-sandbox preview-documentation --target TelegramKB
```

## Status

**Phase 1, slices S0–S5 done; S6 (`tgkb-mcp`) is next.**

| Works today | Not yet |
|---|---|
| `tgkb sync`: public channels through the web preview, incremental and resumable | `tgkb-mcp`: the target exists as a placeholder (S6) |
| `tgkb query`: word search with Russian lemmatisation, plus substring search | Channels with the preview disabled, and groups (Phase 2, TDLib) |
| `tgkb doctor`: store health and a per-channel integrity report | Reactions and links as ranking signals (Phase 3) |
| URL canonicalisation to a versioned spec, shared with a sibling project | Fetching the content behind links (done in the sibling project) |

Measured on a 7,444-post corpus from four channels: `навигация` finds 108 posts, including
other inflected forms; `imation` finds 66, where Telegram's own search finds none; a query with
no good answer returns nothing rather than padding. See `evals/golden-queries.md`.

## Quick start

Requires macOS 13 or later (the lemmatiser uses Apple's `NaturalLanguage` framework) and a
Swift 6.1+ toolchain. Development uses Swift 6.3 with strict concurrency.

```bash
swift build -c release
.build/release/tgkb sync iosgr prefire_ios        # first run backfills; later runs are incremental
.build/release/tgkb query навигация               # word hits first, then substring-only hits
.build/release/tgkb query --mode substring imation
.build/release/tgkb doctor iosgr                  # coverage, gaps, reachability
```

The store defaults to `~/Library/Application Support/telegram-kb/kb.sqlite`; every subcommand
takes `--db`. `sync --full` refreshes stored posts but never removes one. Posts deleted on
Telegram are kept on purpose (`Design`, *Edits are not refreshed; deletions are kept*).

```bash
./Scripts/run-evals.sh           # golden queries G1–G10 against the default store
```

## Shape

Two executables over one SQLite store:

| | |
|---|---|
| `tgkb` | Ingestion. Crawls channels, writes the index. Owns all network access and credentials. |
| `tgkb-mcp` | Read-only stdio MCP server. No network, no credentials, no ban exposure. |

The TDLib ingestion path is behind a **trait, off by default**, so a default build does not
download the binary artifact. This was verified, not assumed; see
`research/spm-traits-binarytarget.md`.

```bash
swift build                      # no TDLib, no artifact download
swift build --traits TDLib       # adds the TDLib ingestion source
./Scripts/check-invariants.sh    # tgkb-mcp depends on exactly Model + Store + MCP, and no TDLib
```

## Repository map

| Path | What it is |
|---|---|
| `Sources/TelegramKBModel` | Value types and the URL canonicaliser. No I/O. |
| `Sources/TelegramKBStore` | GRDB schema, dual FTS5 index, search, crawl state |
| `Sources/TelegramKBIngest` | Web-preview parser, crawler, channel classifier |
| `Sources/TelegramKBIngestTDLib` | Phase 2, trait-gated |
| `Sources/tgkb`, `Sources/tgkb-mcp` | The two executables |
| `Sources/TelegramKB/TelegramKB.docc` | The direction documents |
| `Spec/url-canonical` | A versioned contract shared with another implementation, and its golden files |
| `evals/` | Golden queries, grounded in the real corpus |
| `research/` | Investigation notes and reproducible probes. Evidence for `Research`, not API documentation. |
| `reports/` | Drafts of upstream bug reports and their reproductions |

## Reviewing

`REVIEW.md` lists what a reviewer here should look hardest at. It was built from the bug classes
that four rounds of automated review actually found. `Scripts/check-invariants.sh` must pass
before every commit.

## Licence note

No licence has been chosen yet. TDLib is Boost; TDLibKit, TDLibFramework, GRDB, SwiftSoup and
the MCP SDK are MIT. **Never vendor code from `Telegram-iOS` or `Swiftgram/Telegram-iOS`: both
are GPLv2**, and copying from them would relicense this project.
