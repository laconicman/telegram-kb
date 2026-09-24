# Tech Debt

Numbered `TD-n`, each with what it costs and what discharges it. Reference from code as
`// TODO(TD-n): …`.

Every entry opens with a **Status** line: *Open*, *Partly discharged*, *Mitigated* (the cause
cannot be removed, only watched), *Discharged* or *Superseded*, with the date and commit that
changed it. Entries are never deleted or renumbered: the history below a status line is the
reasoning, and existing references must keep resolving.

## TD-1 — `t.me/s/` HTML has no stability contract

**Status: Mitigated** — 2026-09-06, `a0540d4` (S3). SwiftSoup with the precise `js-message_text`
selector; every extracted field pinned by fixture tests, plus a test comparing it against an independent
implementation. Still open: `tgkb doctor --check-parser`, the live drift check. The
markup itself will never have a contract, so this entry stays open by nature.

The class names we parse (`tgme_widget_message_*`) are internal to Telegram's web front end and
carry no compatibility guarantee. Markup can change without notice or version.

**Cost.** Silent recall loss, not a crash. This is not hypothetical: during Phase 0 an extractor
that matched the shared class prefix `tgme_widget_message_text` harvested the *reply-quote* block
(`js-message_reply_text`, which Telegram truncates to ~256 chars) instead of the body
(`js-message_text`). The result was 21 of 136 posts silently truncated and 30 reply relationships
reported as zero. Nothing threw. It was caught only by comparing against an independent oracle.

**Discharge.** Parse with SwiftSoup and precise selectors, never regex or class prefixes. Pin
every extracted field with a fixture-based parser test against the committed HTML in
`research/fixtures/`. Add a `tgkb doctor --check-parser` that re-crawls a known post and asserts
field-by-field, so drift surfaces as a failed check rather than as quietly worse answers.

## TD-2 — Large binary dependency in the package graph

**Status: Partly discharged** — 2026-08-30, `e8cb32e` (scaffold). The TDLib dependency is
trait-gated and verified not to download with the trait off. Still open: the Xcode resolver, and a
macOS-only slim artifact (Phase 2).

**Re-measured on a clean clone of `main`, 2026-09-21 — and "Phase 1 pays nothing" was too
strong.** What the trait genuinely prevents: `.build/artifacts` is **0 B**, so the 343 MiB
download and its 1.33 GiB expansion never happen, and `swift package show-dependencies` reports
TDLib absent from the graph. What it does *not* prevent: SwiftPM still **clones the repositories**
to resolve them — `TDLibFramework` and `TDLibKit` cost **248 MB** of the 803 MB that all clones
and checkouts occupy after a default build (`.build` totals 1.2 GB). So a contributor who never
enables the trait still pays a quarter of a gigabyte for it. That is a fifth of what the artifact
would cost, and worth saying accurately rather than claiming zero.

**The brief's "~300 MB" was low, and the number that matters is a different one.** Measured from
the shipped artifact's zip central directory (`research/Swiftgram-TDLibFramework.md`):

| | |
|---|---|
| Download | **343 MiB** (359.8 MB) |
| Unzipped | **1.33 GiB** — a 3.97× expansion |
| SPM cost per resolved version | **≈1.7 GiB** — it keeps the `.zip` *and* the extracted `.xcframework` |
| Largest slice | `watchOS`, 245 MiB uncompressed — which we will never run |
| `macos-arm64_x86_64` slice | 183.4 MiB raw / 44.3 MiB zipped — **13.5%** of the bundle |

**Cost.** Slow cold builds and CI, a heavy SPM cache, and ~1.7 GiB of disk for a macOS-only
tool that needs 13.5% of what it downloads.

**Discharge.** Mostly paid already: the dependency is trait-gated and **verified** not to be
downloaded with the trait off (`research/spm-traits-binarytarget.md`), so Phase 1 pays nothing.
Remaining, in order of value:

1. Confirm trait gating holds under **Xcode's** resolver, not just the SwiftPM CLI.
2. **Build a macOS-only slim artifact.** Verified feasible and not a fork: Swiftgram's own
   pipeline is parameterised by platform (`TUIST_PLATFORM=macOS tuist generate`), because that
   is how their CI shards. A macOS-only artifact is roughly a **7.4× reduction** in both
   download and disk. This is a Phase 2 task, not Phase 1 — it only matters once TDLib is
   actually enabled.

## TD-3 — Reaction counts go stale between syncs

**Status: Open.** Reaction counts are stored, but no per-post observation time yet — the only
`observedAt` column belongs to link previews.

There is no reaction-based search in the Telegram API outside Saved Messages tags (Premium), so
reactions must be indexed locally — and a count is a snapshot at crawl time.

**Cost.** Reaction-weighted ranking drifts from reality between syncs. Worst on recent posts,
which accumulate reactions fastest; mild on the historical corpus, which is most of the value.

**Discharge.** Store `reactions_observed_at` per post and expose staleness in results rather than
hiding it. Re-crawl recent history more often than deep history. In Phase 2, subscribe to
`updateMessageInteractionInfo` — note that `updateMessageReaction`/`updateMessageReactions` are
documented **bots-only** and are not available to a user session.

## TD-4 — Russian morphology is not handled by FTS5

**Status: Discharged** — 2026-09-06, `c42455b` (S2), earlier than the Phase 3 planned below. The
`unicode61` index holds folded surface text *and* `NLTagger` lemmas, and queries are lemmatised the
same way (`TextNormalizer`, `Store.searchWords`). `G1` passes: 108 hits for `навигация`. One
divergence from the plan: language is detected per text with `NLLanguageRecognizer` and then set
explicitly, not stored on the row. A single-word query that cannot be identified falls back to its
surface form, which still matches the lemmas indexed for every post.

**Now measured rather than suspected**, and the finding inverts the naive assumption: on
inflected Russian, Telegram's own search is *better* than a plain FTS5 prefix index. SQLite has
no Russian stemmer.

**Cost.** `навигация*` misses a post containing *навигации* that Telegram finds. On a
majority-Russian corpus this is a real recall regression against the tool being replaced.

**Discharge — now verified, not hoped for.** Phase 1 mitigates with the dual
`unicode61` + `trigram` index. Phase 3 closes it with `NLTagger` lemmatisation, and that plan is
**confirmed to work**: with the language set explicitly, `навигация`/`навигации`/`навигацию`/
`навигацией`/`навигациями` all lemmatise to `навигация`, and full sentences lemmatise nouns and
verbs correctly (`research/morphology-and-embeddings.md`). This is exactly the case where FTS5
prefix matching failed and Telegram succeeded.

**One trap to encode when implementing it:** without an explicit `setLanguage`, lemmatisation of
a *single* Russian word silently returns **no tag at all** — including for the nominative form,
which is the one most likely to be typed as a query. Detect language once per post, store it on
the row, and reuse it; never lemmatise a bare query word under auto-detection.

Track recall against `evals/golden-queries.md` so the improvement is measured, not asserted.

## TD-5 — TDLib version pinning drift

**Status: Open.** `TDLibKit` is pinned `exact:` in `Package.swift`; the `doctor` version check and
the upstream-tag check are not built (Phase 2).

TDLibKit and TDLibFramework version independently while both track upstream TDLib, and
TDLibKit's tags are **pre-release-shaped** (`1.5.2-tdlib-1.8.66-022d6020`).

**Cost.** SwiftPM excludes pre-release versions from range resolution, so `from:` silently
resolves to nothing usable. Pinning must be `.exact(...)`, which makes upgrades manual and easy
to forget. The same hazard applies to `duckdb-swift`, which has no stable tag at all.

**Discharge.** Keep `.exact(...)`. Add a `doctor` check comparing the pinned TDLib version
against the runtime `getOption("version")`, and a scheduled check for newer upstream tags.

## TD-6 — Read-only open of a WAL database is conditionally fragile

**Status: Discharged**, as planned below — 2026-09-06, `c42455b` (S2): the writer sets
`SQLITE_FCNTL_PERSIST_WAL`; 2026-09-09, `e810b45` (S5): `tgkb doctor` reports directory writability
in plain language. A DeepWiki second opinion (2026-09-15, <doc:Research>) confirms this is GRDB's
documented multi-process pattern.

A `mode=ro` connection must still create the `-shm` file, so it fails with
`attempt to write a readonly database` when the containing directory is not writable — despite
the caller only wanting to read.

**Cost.** Intermittent by nature: it depends on whether a sync is in flight or was killed, and
the error names the *database* rather than the directory, misdirecting whoever debugs it.

**Discharge.** Writer sets `SQLITE_FCNTL_PERSIST_WAL`; `tgkb doctor` explicitly checks directory
writability and reports it in plain language. Do not paper over it with `immutable=1`, which
trades a loud failure for silently stale reads.

## TD-7 — Views are captured lossily

**Status: Discharged for the web source** — 2026-09-06, `b0d54de` (S1, `ViewCount.isApproximate`)
and `c42455b` (S2, the `viewsIsApproximate` column). Exact counts arrive with TDLib in Phase 2.

`tgme_widget_message_views` renders abbreviated ("1.4K", "1.67K"), so exact view counts are not
recoverable from the web source.

**Cost.** View count is unusable as a precise ranking signal from web-ingested posts, and cannot
be compared meaningfully against TDLib-ingested ones.

**Discharge.** Store the parsed approximation with an explicit `is_approximate` flag, and prefer
reactions as the engagement signal — 164,747 of them across the corpus, and exact. TDLib supplies
exact view counts in Phase 2 for channels reachable that way.

## TD-8 — No end-to-end proof of ID reconciliation

**Status: Open** — the Phase 2 gate.

The transform between web `data-post` numbers and TDLib `message_id` is verified from TDLib
source and corroborated by TDLib's own link builder, but has not been executed against a live
client.

**Cost.** If wrong, the two sources write duplicate rows instead of reconciling — the failure the
whole two-source design rests on avoiding.

**A second reconciliation hazard, found later and harder than the first.** The two sources
disagree on an **album's grain**: the web preview renders a media group as *one* post (verified —
`@ios_broadcast/581` spans message ids 581–586, 587 spans 587–591, 977 spans 977–984), while
TDLib returns *N* separate messages sharing a `media_group_id`. The ID transform is correct; the
*cardinality* is not. A naive reconciler writes N rows against 1 and reads the difference as
missing data.

Relatedly: **a missing message id is not evidence of deletion.** Albums consume consecutive ids
that never appear as posts, which is a large part of the 54% id gap in the crawled corpus.

**Corrected 2026-09-09.** That "54%" counts ids with no *post row*, which is the misleading
framing: an album occupies several consecutive ids while rendering as one post, so most of those
ids are accounted for by `mediaCount`. Measured across the four synced channels with album spans
included, **86–95% of each channel's id range is accounted for**, and the longest run of
genuinely unexplained ids is 4–9 — consistent with scattered deletions and service messages,
not with missed pages. `tgkb doctor` reports this per channel.

**Discharge.** The first Phase 2 task, before any backfill: fetch one post from a channel already
crawled from the web and assert the rows reconcile — **including an album**, which is the case
that actually fails. Group TDLib messages by `media_group_id` before writing, take the first id
as identity. Keep it as a permanent integration test.

## TD-9 — Semantic retrieval over Russian needs care (partly superseded)

**Status: Open**, not owed until Phase 3.

**Originally filed as "no on-device embedding model exists for Russian". That was wrong**, and
the correction is worth keeping visible: it was a claim about `NLEmbedding` generalised into a
claim about the platform.

`NLEmbedding` really does have nothing for Russian — `supportedRevisions(for: .russian)` is the
empty set. But **`NLContextualEmbedding(script: .cyrillic)` covers ru/bg/kk/uk** at 512
dimensions, with the model asset downloaded and shared by the OS, so it adds **nothing** to the
package. Verified directly (`research/morphology-and-embeddings.md`).

**Remaining cost — three real constraints, none fatal:**

1. **Mean-centering is schema, not a detail.** It materially changes ranking, so it must be
   applied identically at index and query time in *both* processes — the corpus mean therefore
   lives in the database. Whether centering helps at all is **unresolved**: the storage research
   measured raw cosine inverting and centering fixing it; my own probe measured the opposite
   sign. My mean was over 8 sentences, far too few to be representative, which is the likely
   explanation. **Settle it against the real 7,406-post corpus before relying on either.**
2. **Cyrillic and Latin are separate vector spaces.** Equivalent ru/en sentences score near zero
   against each other. A corpus mixing Russian prose with English technical terms cannot use one
   embedding space for both — and this, not model availability, is the real argument for a
   multilingual model such as `multilingual-e5-small` (384 dims, MIT).
3. **Quality is unproven for this task.** In my probe, both raw and centered rankings put
   "анимация переходов в UIKit" above "координатор для навигации" for a navigation query.

**Discharge.** Not owed until Phase 3. **Measure lemma-only retrieval against
`evals/golden-queries.md` first** — good lemmatisation may close enough of the gap that
semantics are unnecessary. If they are needed, start with `NLContextualEmbedding` (free) and
price MLX only against the cross-script problem, which is the one thing Apple's model cannot
solve. **Do not** ship semantics for English and lemma-only for Russian.

## TD-10 — Cyrillic ё is not folded to е

**Status: Discharged** — 2026-09-06, `c42455b` (S2). `TextNormalizer.foldYo` runs at index and
query time. The test `вёрстка and верстка are the same word` pins it, and `G3` covers it in the
evals. **The folding works; the inflections of folded words often do not** — an `е`-spelled query
still misses most ё-written posts, because the lemmatiser emits nothing for the inflected form.
That is `TD-23`, not a folding failure.

`unicode61 remove_diacritics 2` does **not** fold ё→е — ё is a distinct Cyrillic letter, not an
accented е. Verified directly: index `вёрстка`, query `верстка`, zero hits.

**Cost.** A common Russian word silently splits into two index terms. **5% of posts in `@iosgr`
contain ё** — roughly 200 posts in one channel. Telegram's own search folds them.

**Discharge.** Normalise ё→е at index *and* query time, before tokenisation. A few lines, and it
must be applied symmetrically or it makes things worse. Add a golden query covering it.

## TD-11 — Telegram's search reaches content we do not extract

**Status: Open.**

While reconciling our index against Telegram's results, two posts matched on Telegram with no
occurrence of the term in the body, preview title, or preview description we captured.

**Cost.** Unknown-size recall gap. Given the corpus is **95% links**, if Telegram indexes
link-target content beyond the preview, our recall on link-heavy posts is structurally lower
than it looks.

**Leading hypothesis (author's, and it fits the evidence):** Telegram indexes the *link preview*
it generated, which is **not guaranteed to hold the target page's full content** — sometimes it
is only OpenGraph metadata, sometimes more. That would explain a match with no term in the body,
and it predicts the gap is bounded by whatever Telegram scraped, not by the whole page.

**Discharge.** Settle the mechanism before Phase 3 sizes link ingestion. Candidates: preview
content beyond what is rendered, full linked-page text, semantic expansion, and media/document
metadata our crawler drops. **Note this is no longer purely a risk** — fetching link content
ourselves is now planned work (see <doc:Roadmap>), and doing it well would make us strictly
better than Telegram here rather than merely matching it.

## TD-12 — Link content will outweigh post text 15–25× and pollute ranking

**Status: Open**, Phase 3.

Extracted link text is estimated at **50–80 MB against 3.38 MB of post bodies**
(`research/link-content-fetching.md`).

**Cost.** Merged into a single FTS table, link content dominates `bm25()` and nearly every query
returns the post that *links to* an article about X rather than the post *about* X. This is the
biggest risk in the link-fetching work — bigger than any fetching difficulty — because it
degrades results that currently work.

**Discharge.** Keep fetched content in a **separate FTS table** (already the design decision, now
load-bearing rather than cautious), so opting in stays a query-time choice. Measure precision
against `evals/golden-queries.md` before deciding the default. Consider weighting or truncating
extracted text per document.

## TD-13 — SUPERSEDED: extraction moved to `artanl`

**Status: Superseded** — 2026-09-03, `1600de4`.

Originally: `mrowlinson/jusText-swift` is unlicensed and cannot be vendored, so the boilerplate
classifier must be ported from the BSD-2-Clause Python original.

**No longer this project's debt.** Article extraction now belongs to the analyzer, which is
Python and uses `trafilatura` — maintained, and it sidesteps the licensing question entirely.
Kept as a numbered entry so existing references resolve, and because the underlying lesson
travels: **an unlicensed repository cannot be vendored no matter how convenient it looks**
(`LICENSE`, `LICENSE.md`, `LICENSE.txt`, `COPYING` all 404; the GitHub API reports no licence).

## TD-14 — SUPERSEDED: coverage is the ladder's problem, and it has a floor

**Status: Superseded** — 2026-09-03, `1600de4`. Of the three obligations it leaves, two were met
in `c42455b` (S2): a preview with `previewObservedAt` on every link, and `urlCanonical` stored at
ingest. `contentProvenance` is owed once fetched content reaches this store.

Originally: ~8% link rot, ~10% bot-walled, ~7% YouTube — roughly 30% of URLs yielding no useful
text.

**Restated correctly.** The analyzer's tier ladder descends to `web.archive.org` for dead links
and, finally, to **Telegram's own preview metadata — which this project stores.** No URL yields
nothing. What survives as *our* obligation is narrow and concrete:

- Store the preview for **every** link, including ones we expect never to fetch. It is the
  fallback of record.
- Store `url_canonical` at ingest so the join key exists from the first crawl.
- **Carry `contentProvenance`** on any fetched-content row. Bot-walled sources are now attempted
  via mirrors and summarisers (<doc:Design>), so the ladder gains a rung between "preview only"
  and "fetched" — and a summary must be filterable, because it is evidence *about* an article
  rather than the article. Without the marker a mirror is silently indistinguishable from the
  original, which is the failure this whole project is built to avoid.

## TD-15 — `robots.txt` compliance is deferred, deliberately

**Status: Open, deliberately.** Note for publication: `tgkb` fetches only `t.me`, which has no
`robots.txt`; `Scripts/resolve_urls.py` does request third-party sites.

The engine currently plans to fetch without consulting `robots.txt`. This is the author's
explicit decision, recorded rather than silently assumed: the priority is retrieval quality, and
restricting scope later is the easy direction — particularly relevant if any of this is ever
published.

**Cost.** Facts, not judgements: `clck.ru/robots.txt` is `Disallow: /` with `Allow: /$`
(114 corpus links). Medium's `robots.txt` names `GPTBot`, `ClaudeBot`, `Bytespider` and
`Applebot-Extended` with `Disallow: /`. `t.me` has **no** `robots.txt` at all (HTTP 404), so
nothing is expressed there. The exposure is reputational and contractual rather than technical,
and it scales with distribution — negligible for a private index, material for a published tool.

**Discharge.** Before any public release: add a `robots.txt` check with a per-domain override
table, and an honest UA carrying a contact URL. **Independently of that, and not deferred:** no
CAPTCHA solving and no TLS/JA3 fingerprint spoofing at any tier — the tier ladder is what makes
those unnecessary, which is the strongest argument against them.

## TD-16 — `url_canonical` can silently diverge between two repos

**Status: Discharged** — 2026-09-03, `3be0eb2` (S0); spec v3 on 2026-09-06, `2f1de8d`. The other
implementation is tested against the same fixture list. The two implementations remain, so a new rule is a new
fixture, never a local fix.

The join key between `telegram-kb` and `artanl` is a **canonicalisation algorithm implemented
twice, in two languages**. Redirect following, `http`→`https` upgrade (529 corpus URLs),
`utm_*`/`ssource`/`share`/fragment stripping — each is a place the two can drift.

**Cost.** Divergence does not throw. It produces rows that fail to join, so articles silently
lose their posts and posts silently lose their attributes. Exactly the silent-recall-loss class
as `TD-1`.

**Discharge.** One versioned spec plus a **shared fixture list** that both repos run in their own
test suites, treated as a contract: divergence is a test failure, not a discovery. Seed the
fixtures from the real corpus — the shortener, interstitial and `http://` cases are already
enumerable from it.


## TD-17 — Roughly a fifth of URLs will never resolve

**Status: Partly discharged** — 2026-09-06, `6a6f4c0` (S3.5). `httpStatus` and `resolvedAt` are
recorded per row, so a failure is distinguishable from "never checked" (and since 2026-09-15,
`6e3aff7`, a row with an unreadable timestamp is rejected rather than stamped fresh). Still open:
periodic re-resolution of failures.

Measured on a 50-URL sample: 6 unreachable (`URLError`), 3 × 404, 2 × 403 and 1 × 418 — about
**18% not resolving cleanly**, consistent with the ~8% link rot plus ~10% bot-walled estimate in
`research/link-content-fetching.md`.

**Cost.** `url_resolution.resolved_canonical` is NULL for those rows, so `effective_url` falls
back to `url_canonical`. That is the designed behaviour and correct — but it means a shortener
that dies before we resolve it can **never** be joined to `artanl`'s row for the same article,
because neither side can discover the destination. The join silently under-matches.

**Discharge.** Record `http_status` and `resolved_at` so the failure is visible and re-triable
rather than indistinguishable from "not yet checked". Re-resolve NULLs periodically — some are
transient. Resolve **early**: every day a shortener stays unresolved is a day it might die, and
the corpus already reaches back to 2016.

## TD-18 — An incremental gap wider than the page cap never closes

**Status: Discharged** — 2026-09-15, `6e3aff7` (PR #1, review round 5), without the second cursor
planned below. What a capped incremental walk covered is contiguous from the newest page down, so
`Store.CrawlState.afterWalk` now records it as an unfinished backfill. The next run resumes through
the gap, at the price of re-walking stored history below it. Test:
`cappedIncrementalResumesThroughTheGap`.

An incremental walk records nothing until it reaches the stored mark (see Design, *A failed fetch
is never exhaustion*). If more than `maxPages` pages (500, about 10,000 posts) appeared since the
last sync, every run walked the newest 500 pages, stopped short, kept the old mark, and started
again from the top — the posts were written, but the gap below them was never reached.

**Cost.** None at current volumes: the busiest synced channel posts a few times a day. It would
have bitten a channel synced for the first time in years through a stale mark, or a much larger
channel.

**Discharge, as first planned.** A second cursor for the gap, resumed the way a backfill resumes
from `lowestMessageID`. Deferred at the time because it added a column and a state to a machine
that had already produced four review rounds of bugs — and then made unnecessary by seeing that
the existing resume state already describes the case.

## TD-19 — The channel's identity is a label its owner can change

**Status: Open** — the decision is made (<doc:Design> § *Channel identity is `rawChannelID`, not
the username*), the migration is scheduled as `S7` in <doc:Roadmap>.

`channel.username` is the primary key and `post.channelUsername` the foreign key. A Telegram
username is a public alias: the owner can change it, Telegram matches it case-insensitively, and
a channel need not have one at all. `rawChannelID` — already stored, already the basis of the
TDLib `chat_id` — is the immutable identity.

**Cost.** A rename orphans a channel's entire history, and the next crawl writes what looks like a
new channel. Three review findings have circled this already: a casing mismatch breaking the
foreign key, the `0` placeholder overwriting a learned id, and identity taken from the first
`data-view` on a page. None of those are separate bugs; they are the same wrong key.

**Discharge.** Schema `v4` as described in `S7`: key on `rawChannelID`, keep `username` as a
unique-when-present label, render permalinks from the label with a `t.me/c/<rawChannelID>/<id>`
fallback.

## TD-20 — Column names are repeated as string literals

**Status: Partly discharged** — 2026-09-16, review round 6. `Store.integrity` now decodes a typed
`Span` record instead of `row["messageID"]`, and `backfillComplete` is read with a typed fetch.

Column names still appear three times: in `Schema.swift`, in the `INSERT`/`SELECT` SQL, and in
`Row` subscripts such as `row["viewsIsApproximate"]` in `Store.loadPost`. That is one piece of
knowledge in three places — the DRY failure Hunt and Thomas describe, where a schema change
compiles cleanly and fails at run time.

**Cost.** A renamed column is caught by a test, if one covers that field, rather than by the
compiler. `loadPost` carries fourteen such subscripts; the write path spells the same names again
in SQL.

**Discharge.** GRDB `Codable` records (`FetchableRecord`/`PersistableRecord`) for `post` and its
relations, so property names generate the SQL and decode the rows. Do it with `S7`, which rewrites
these tables anyway — two migrations of the same code, not one.

## TD-21 — Two syncs of the same channel are not prevented

**Status: Open** — the writer's busy timeout (2026-09-16) bounds the *symptom*, not the cause.

`busyMode = .timeout(10)` makes a second writer wait rather than fail instantly, which is right
for two syncs of *different* channels sharing one file. Two syncs of the *same* channel still
interleave: each reads the crawl state at its own start, so the second can write back a state
older than the first's progress. That costs re-crawling, not lost posts — but it is unproven
either way, which is the objection.

**Cost.** Wasted requests, and a state machine whose invariants were reasoned about for one writer.

**Discharge.** A lease row in the database — channel identity, pid, heartbeat, taken in a
transaction — so both processes can see it without a lock file. Within a process, an actor keyed
by channel identity gives the same guarantee for concurrent channel crawls; it cannot help across
processes, and `Task(name:)` is a debugging label, not an identity (verified: two tasks may share
a name).

**How to write it, from a DeepWiki consult on GRDB (2026-09-16, <doc:Research>).** GRDB has no
lease primitive, and none is needed: it begins every write transaction as `IMMEDIATE`, so the
write lock is taken before the lease row is read. Put the staleness check and the claim in **one**
`dbPool.write` — never read the row in one access and claim it in another, because a read that
later escalates to a write is the one `SQLITE_BUSY` a timeout cannot prevent. Do not reach for
`BEGIN EXCLUSIVE`: it would block WAL readers, which is `tgkb-mcp`. One constraint that falls out
of our own settings: **the staleness threshold must be comfortably larger than `busyMode`'s 10
seconds**, or two processes contending for a takeover fail on the timeout instead of cleanly
losing the race.

## TD-22 — WAL growth during a long backfill is unmanaged and unmeasured

**Status: Open** — named after a DeepWiki consult on GRDB (2026-09-16, <doc:Research>) turned a
vague worry in the Research ledger into a specific mechanism.

GRDB runs no background checkpointing. The only checkpoints are SQLite's own automatic one, which
fires after a commit that leaves the WAL at 1,000+ pages and runs in `PASSIVE` mode, and whatever
the application calls itself. A `PASSIVE` checkpoint can only reclaim frames no reader snapshot
still pins.

**Cost.** Our shape is exactly the one that starves it: a writer committing a small transaction per
page for the length of a backfill, and `tgkb-mcp` reading in another process. Individually short
reads are fine; *continuously overlapping* ones are not, because some snapshot is then always
pinned near the start of the WAL and the file grows for the whole backfill. Nobody has measured
ours — a 116-page backfill is short. The reader exists as of S6 (`tgkb-mcp` opens the same file
in a second process), so the measurement this entry asks for is now runnable.

**Discharge.** Measure first: watch the `-wal` file during a full backfill with a reader looping
against it. If it grows without bound, call `db.checkpoint(.passive)` from the writer on a cadence
(every N pages), and a `.truncate` once at the end to give the space back. Do **not** use
`.full`/`.restart`/`.truncate` mid-backfill: they block until readers release.



## TD-23 — `NLTagger` gives no lemma for roughly a fifth of Russian words

**Status: Open** — found 2026-09-16, following a review finding that the golden checks were weaker
than their own criteria (PR #1, round 11). Measured, not suspected.

`NLTagger` with `.lemma` and the language set explicitly to Russian returns **no tag at all** for
`верстку`, even in the clean sentence *"Сегодня я хотел бы рассказать про верстку в нашем
приложении"*. Across post `iosgr/2081`, 10 of 43 tagged words came back with no lemma.

**Cost, measured on the synced corpus.** The word index holds folded surface text plus whatever
lemmas the tagger produced, so a word the tagger skips is reachable only by its exact form. The
trigram index cannot rescue it either: `верстка` is not a substring of `верстку`. Of the **8 posts
written with `вёрст…`, an `е`-spelled query returns 1**. `TD-4` is therefore discharged for the
words Apple's lexicon knows and no further — a narrower claim than this register made before.

This also corrects `evals/golden-queries.md`: `iosgr/2081` was described as the canonical ё case,
and it is not currently returned at all. `iosdev/530` is, and `G3` now asserts that specific post
rather than a bare non-zero count.

**Discharge — decide on eval evidence, not preference.** Candidates, in the order worth measuring:
add a prefix term per Cyrillic query token (FTS5 `верстк*`) alongside the lemma path and measure
`G1`/`G3` before and after; or vendor a Russian stemmer and index the stem as a third field. Both
widen recall and can cost precision, which is exactly what the golden queries exist to arbitrate.

## See Also

- <doc:Design>
- <doc:Roadmap>
- <doc:Research>
