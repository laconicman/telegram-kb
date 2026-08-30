# Tech Debt

Numbered `TD-n`, each with what it costs and what discharges it. Reference from code as
`// TODO(TD-n): …`.

## TD-1 — `t.me/s/` HTML has no stability contract

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

There is no reaction-based search in the Telegram API outside Saved Messages tags (Premium), so
reactions must be indexed locally — and a count is a snapshot at crawl time.

**Cost.** Reaction-weighted ranking drifts from reality between syncs. Worst on recent posts,
which accumulate reactions fastest; mild on the historical corpus, which is most of the value.

**Discharge.** Store `reactions_observed_at` per post and expose staleness in results rather than
hiding it. Re-crawl recent history more often than deep history. In Phase 2, subscribe to
`updateMessageInteractionInfo` — note that `updateMessageReaction`/`updateMessageReactions` are
documented **bots-only** and are not available to a user session.

## TD-4 — Russian morphology is not handled by FTS5

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

TDLibKit and TDLibFramework version independently while both track upstream TDLib, and
TDLibKit's tags are **pre-release-shaped** (`1.5.2-tdlib-1.8.66-022d6020`).

**Cost.** SwiftPM excludes pre-release versions from range resolution, so `from:` silently
resolves to nothing usable. Pinning must be `.exact(...)`, which makes upgrades manual and easy
to forget. The same hazard applies to `duckdb-swift`, which has no stable tag at all.

**Discharge.** Keep `.exact(...)`. Add a `doctor` check comparing the pinned TDLib version
against the runtime `getOption("version")`, and a scheduled check for newer upstream tags.

## TD-6 — Read-only open of a WAL database is conditionally fragile

A `mode=ro` connection must still create the `-shm` file, so it fails with
`attempt to write a readonly database` when the containing directory is not writable — despite
the caller only wanting to read.

**Cost.** Intermittent by nature: it depends on whether a sync is in flight or was killed, and
the error names the *database* rather than the directory, misdirecting whoever debugs it.

**Discharge.** Writer sets `SQLITE_FCNTL_PERSIST_WAL`; `tgkb doctor` explicitly checks directory
writability and reports it in plain language. Do not paper over it with `immutable=1`, which
trades a loud failure for silently stale reads.

## TD-7 — Views are captured lossily

`tgme_widget_message_views` renders abbreviated ("1.4K", "1.67K"), so exact view counts are not
recoverable from the web source.

**Cost.** View count is unusable as a precise ranking signal from web-ingested posts, and cannot
be compared meaningfully against TDLib-ingested ones.

**Discharge.** Store the parsed approximation with an explicit `is_approximate` flag, and prefer
reactions as the engagement signal — 164,747 of them across the corpus, and exact. TDLib supplies
exact view counts in Phase 2 for channels reachable that way.

## TD-8 — No end-to-end proof of ID reconciliation

The transform between web `data-post` numbers and TDLib `message_id` is verified from TDLib
source and corroborated by TDLib's own link builder, but has not been executed against a live
client.

**Cost.** If wrong, the two sources write duplicate rows instead of reconciling — the failure the
whole two-source design rests on avoiding.

**Discharge.** The first Phase 2 task, before any backfill: fetch one post from a channel already
crawled from the web and assert the rows reconcile. Keep it as a permanent integration test.

## TD-9 — Semantic retrieval over Russian needs care (partly superseded)

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

`unicode61 remove_diacritics 2` does **not** fold ё→е — ё is a distinct Cyrillic letter, not an
accented е. Verified directly: index `вёрстка`, query `верстка`, zero hits.

**Cost.** A common Russian word silently splits into two index terms. **5% of posts in `@iosgr`
contain ё** — roughly 200 posts in one channel. Telegram's own search folds them.

**Discharge.** Normalise ё→е at index *and* query time, before tokenisation. A few lines, and it
must be applied symmetrically or it makes things worse. Add a golden query covering it.

## TD-11 — Telegram's search reaches content we do not extract

While reconciling our index against Telegram's results, two posts matched on Telegram with no
occurrence of the term in the body, preview title, or preview description we captured.

**Cost.** Unknown-size recall gap. Given the corpus is **95% links**, if Telegram indexes
link-target content beyond the preview, our recall on link-heavy posts is structurally lower
than it looks.

**Discharge.** Settle the mechanism before Phase 3 decides how much link-target content to
ingest. Candidates to test: full linked-page text, semantic expansion, and media/document
metadata our crawler drops. Do not design link ingestion until this is answered — it changes the
size of the job.

## See Also

- <doc:Design>
- <doc:Roadmap>
- <doc:Research>
