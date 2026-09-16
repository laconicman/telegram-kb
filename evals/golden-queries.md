# Golden queries

Real questions worth asking this corpus, with what a good answer looks like. Retrieval quality is
measured against this file from Phase 1 onward, so that "did it get better" has an answer other
than vibes.

**How to use.** Run after any change to tokenisation, ranking or ingestion. A change that
improves one query and regresses another is a *trade*, and this table is how that trade becomes
visible instead of invisible.

## The corpus these are grounded in

Crawled 2026-08-24 from the four previewable target channels — complete histories, not samples.

| | |
|---|---|
| Posts | **7,406** across 4 channels, 2016-08-25 → 2026-08-24 |
| Language | **90% Russian-dominant**, 10% Latin-dominant |
| Posts carrying a link | **7,032 / 7,406 (95%)** — this is a link corpus |
| Links | 16,789 total, 11,665 unique; 479 shared across >1 channel |
| Reactions | 164,747 |
| Body text | 3.38 MB |
| Posts with no text at all | 161 (2%) |

`@iosmmcresources` (preview disabled) and `@AllByiOS` (a group) are **not** included — they need
Phase 2 TDLib. Any eval claiming corpus-wide coverage is wrong until they are in.

## Baselines to beat

Measured on `@iosgr` (4,388 posts) — see `research/web-preview-probe.md`.

**Telegram's own search caps at ~22 results per query.** For `архитектура`: 206 literal matches in
the channel, **22** surfaced by Telegram, 54 by an FTS5 prefix index, **152** by an FTS5 lemma
index. Beating Telegram on recall is not the bar — it is the floor.

## The table

`E` = expected. Fill in exact ids as the store is built; counts are already measured.

| # | Query | Kind | Expectation | Guards |
|---|---|---|---|---|
| **G1** | `навигация` | Russian inflection | ≥36 posts **in `@iosgr`**, counted per channel — the runner filters to that channel, because hits from the other three once covered for a regression in this one. Prefix-only finds 11 — **that is a fail.** Must match `навигации`, `навигацию`, `навигацией`. | `TD-4` |
| **G2** | `imation` | substring | Non-empty. Telegram returns 0; `unicode61` returns 0; only the `trigram` index can serve this. | — |
| **G3** | `верстка` | **ё/е folding** | Must return a post *written* with `вёрстка` for an `е`-spelled query; asserted on `iosdev/530`. **Corrected 2026-09-16:** `iosgr/2081` was named here as the canonical case and is **not returned at all** — its match sits in the link-preview description as `вёрстку`, for which `NLTagger` emits no lemma, so neither index reaches it. Of 8 ё-written posts, 1 comes back. See `TD-23`. | `TD-10`, `TD-11`, `TD-23` |
| **G4** | `архитектура` | **cap-beating recall** | ≥150 posts corpus-wide (369 contain the stem). Returning ~22 means we have reimplemented Telegram's limitation. | — |
| **G5** | "what did anyone share about app startup time" | natural language → link | Should surface `emergetools.com/blog/…improve-popular-iOS-app-startup`, shared in **3 channels**. Answer must cite `t.me` links. | — |
| **G6** | `swift-build` | cross-channel dedupe | `github.com/swiftlang/swift-build` was shared in **all 4 channels**. Phase 3 must return it **once**, listing all four sharings — not four near-identical rows. | — |
| **G7** | "which SPM did we settle on for X" | decision retrieval | The motivating use case. No fixed answer; judged by whether the cited posts actually contain a recommendation. | — |
| **G8** | most-reacted posts about SwiftUI | reaction ranking | 948 posts match `swiftui`. Ranking must use reaction counts (164,747 available), not recency alone. | `TD-3` |
| **G9** | `корутин` | sparse term | Only **4** posts corpus-wide. Must return **exactly** 4 — padding fails as surely as a miss. Re-baseline this number when the corpus grows. | — |
| **G10** | `гравитационные волны` | **no good answer** | Must return nothing, or say so. **Confabulation here is a worse failure than G1–G9 combined** — a knowledge base that invents citations is not usable. | — |

## Deliberately not yet covered

- **Forwarded posts.** None appeared in the crawl, so the author/sender dimension is untested for
  forwarded content — which is how a lot of shared material arrives.
- **The two Phase-2 channels.** Both are in the preference list; neither is reachable yet.
- **Date-bounded queries** ("what was shared about Z last spring"). The data supports it — every
  post has a full ISO-8601 timestamp — but no query here exercises it yet.
- **Media-only posts** (161 with no text). They carry date, author, reactions and often a link
  preview, and should be findable through those.
