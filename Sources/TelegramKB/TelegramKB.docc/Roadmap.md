# Roadmap

Rationale lives in <doc:Design>. This is what gets built, in what order, and how two people (or
two sessions) work on it at once without colliding.

## How to read this

Work is cut into **slices**, each with an explicit *done* test. A slice is finished when its test
passes, not when its code exists. Slices in the same **track** are sequential; separate tracks
are genuinely parallel and own disjoint files, because parallel sessions on this repo have
already collided once.

`S0` is deliberately tiny and comes first because it unblocks the *other* project.

---

## S0 — the seam contract ✅ *(done)*

The `url_canonical` spec and its shared fixture list.

- Write the spec as a versioned document: resolve redirects → upgrade `http`→`https` → strip
  `utm_*`/`ssource`/`share`/fragments → lowercase host → keep the post-redirect URL.
- Seed the fixture list **from the real corpus**, which already enumerates the hard cases: 313
  shortener links, the `clck.ru` → `sba.yandex.ru` interstitial, 529 `http://` URLs, and the 479
  links shared across channels.
- Implement it in `TelegramKBModel`. `artanl` implements the same list independently.

**Delivered, now at spec v2 after cross-implementation review.** `Spec/url-canonical/SPEC.md` and `Spec/url-canonical/fixtures.json` (**42** cases) plus
`corpus-canonical.tsv` (**11,773** rows, self-checking), implemented in
`TelegramKBModel.URLCanonicaliser` and run by `TelegramKBModelTests`. Validated against all **11,665** unique corpus URLs: 100% canonicalised,
zero tracking parameters surviving, idempotent throughout, **1,995 raw forms collapsed (17%)**.
Both the contract test and the spec/resource drift guard are negative-tested.

**`artanl` passed 34/34 on its first run**, having handled both predicted divergences
explicitly. v2 then added `effective_url` as the join key, seven fixtures, and the one real
divergence the review found: **literal non-ASCII paths**, which Swift percent-encodes and Python
does not.

*Note: the corpus run found two bugs the 34 hand-written fixtures did not — an enumerated `utm_*`
list that missed `utm_refcode`, and a spec claim that no IDN host existed when two do.*

---

## Track A — the store *(blocks everything else here)*

### S1 — `TelegramKBModel`
`Channel`, `Post`, `Author`, `Reaction`, `LinkRef`, `Poll`, `Forward`. No I/O. Includes the S0
canonicaliser and the **`kind` + modifiers** model from <doc:Design> — `kind` (text, photo,
album, video, audio, voice, document, poll, …), `mediaCount`, `isForwarded` with origin,
`replyTo`, and `formatSource` so "not a document" is distinguishable from "this source cannot
say".

**Done:** round-trip `Codable` tests; canonicaliser passes the S0 fixtures; an album fixture
round-trips as **one** post with `mediaCount > 1`.

### S2 — `TelegramKBStore`
GRDB schema and migrations, **including the six commitments made to `artanl`** (see
<doc:Design>): the `url_resolution` relation, `spec_version` as a column, an album `group_id`,
poll text as indexable, preview metadata with `observed_at`, and `formatSource`. Dual FTS5 — `unicode61` for ranked word search, `trigram` for
substring — plus **ё→е normalisation at index and query time** (`TD-10`). `url_raw` and
`url_canonical` stored side by side with the spec version (<doc:Design>). Writer sets
`SQLITE_FCNTL_PERSIST_WAL` (`TD-6`).

**Done:** migrations run on an empty file; a seeded fixture round-trips; `навигация` matches a
post containing *навигации* via the lemma path; `вёрстка` matches `верстка`; a reader process
opens the file read-only while a writer holds it.

---

## Track B — ingestion *(parallel with C after S2)*

### S3 — `WebPreviewSource` parser
SwiftSoup, precise selectors. Must extract: body (`js-message_text`, **not** the reply-quote
sibling), reactions incl. paid, link previews, hashtags, views, **poll question and options**,
**forwarded origin channel + post id + author**, reply target, and **album grouping** — one post,
`mediaCount` media, trailing ids absent by design rather than deleted.

**Done:** fixture tests pin **every** field against committed HTML, including one reply, one
poll, one forwarded post and **one album** (`tgme_widget_message_grouped`). This is `TD-1`'s discharge and the tests are the point of the slice.

### S3.5 — URL resolution *(can start immediately; needs neither S1 nor S2)*
Populate `url_resolution` for every canonical URL. Input is
`Spec/url-canonical/corpus-canonical.tsv`, which already exists, so this is unblocked **now**.
One request in flight per host, up to ~8 hosts concurrently: ~33 min for 9,770 URLs.

**Done:** every canonical URL has a `url_resolution` row — including non-redirects, where
`resolved_canonical` equals the input. NULLs carry an `http_status` explaining why (`TD-17`).

### S4 — crawler
Page by returned ids, never a stride. Polite by default. Per-channel watermarks so a re-run is
incremental. The four-way channel classifier for `doctor`.

**Done:** a full channel backfill reproduces the corpus already crawled, and a second run fetches
only new posts.

---

## Track C — retrieval *(parallel with B after S2)*

### S5 — `tgkb query`
CLI search over the store. Exists before the MCP server because it is how the evals run without
an MCP client in the loop.

**Done:** `G1`–`G10` in `evals/golden-queries.md` are runnable and produce numbers.

### S6 — `tgkb-mcp`
`search_posts`, `find_links`, `get_post`. Compact records, opaque cursors, a `t.me` link on
every row, `find_links` keyed on `url_canonical`. Annotations set explicitly — the SDK defaults
are `destructive: true`, `openWorld: true`. All diagnostics to stderr; fd 1 redirected at
startup.

**Done:** Claude answers "what has anyone shared about X" with cited `t.me` links.

---

## The Phase-1 exit

**`S0`–`S6`, and `G1`–`G10` measured — not necessarily all passing.** `G1` (Russian inflection)
and `G10` (no good answer) must pass; the rest need numbers so later phases can show movement.
Public channels only, no auth, no TDLib, no ban exposure.

---

## Next — Phase 2: TDLib

Gated behind the `TDLib` trait. **First task, before any backfill: prove the ID reconciliation
end-to-end** against a channel already crawled from the web (`TD-8`). Then `tgkb login`
(Keychain, QR if available), throttled resumable backfill, edits and deletes — treating
`updateDeleteMessages(from_cache: true)` as *not* a deletion — reactions via
`updateMessageInteractionInfo`, and `format` stored with its source (<doc:Design>).

Unlocks the two channels the web preview cannot reach: `@iosmmcresources` (preview disabled) and
`@AllByiOS` (a group).

## Next — Phase 3: retrieval quality

Lemma column via `NLTagger` (`TD-4`). Links promoted to first-class entities with cross-channel
dedupe. Reactions as a ranking signal. The `artanl` join on `url_canonical`, and its extracted
text in a **separate FTS table** (`TD-12`). Dual search — local index and Telegram's live `?q=`
merged, since theirs caps at ~22 and ours is a crawl-time snapshot. Semantic search decided from
eval evidence, not in advance (`TD-9`).

## Later — Phase 4: write operations

Send, forward-to-Saved-with-tag, drafts. Human confirmation on every one. Settle first where
TDLib lives once MCP needs it — the four options are in <doc:Design>, unanswered on purpose.

---

## Working in parallel

| Track | Owns | Never touches |
|---|---|---|
| A | `TelegramKBModel`, `TelegramKBStore`, migrations | anything else |
| R | `S3.5` resolution — runs standalone against the golden file, writes JSON until S2 exists | any source target |
| B | `TelegramKBIngest`, `research/fixtures/` | `TelegramKBMCP`, `Sources/tgkb-mcp` |
| C | `TelegramKBMCP`, `Sources/tgkb`, `Sources/tgkb-mcp`, `evals/` | `TelegramKBIngest` |

**A blocks B and C. B and C do not block each other.** The direction docs are shared: edit them
in small, anchored changes, never by line-index surgery — that has already destroyed content
here once.

`Scripts/check-invariants.sh` must pass before every commit on every track.
