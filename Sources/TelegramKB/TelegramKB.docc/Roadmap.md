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

**Delivered, now at spec v3 after cross-implementation review.** `Spec/url-canonical/SPEC.md` and `Spec/url-canonical/fixtures.json` (**49** cases) plus
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

### S1 — `TelegramKBModel` ✅ *(done)*
`Channel`, `Post`, `Author`, `Reaction`, `LinkRef`, `Poll`, `Forward`. No I/O. Includes the S0
canonicaliser and the **`kind` + modifiers** model from <doc:Design> — `kind` (text, photo,
album, video, audio, voice, document, poll, …), `mediaCount`, `isForwarded` with origin,
`replyTo`, and `formatSource` so "not a document" is distinguishable from "this source cannot
say".

**Done:** round-trip `Codable` tests; canonicaliser passes the S0 fixtures; an album fixture
round-trips as **one** post with `mediaCount > 1`.

### S2 — `TelegramKBStore` ✅ *(done)*
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

## Track B — ingestion *(next; blocks C)*

### S3 — `WebPreviewSource` parser ✅ *(done)*
SwiftSoup, precise selectors. Must extract: body (`js-message_text`, **not** the reply-quote
sibling), reactions incl. paid, link previews, hashtags, views, **poll question and options**,
**forwarded origin channel + post id + author**, reply target, and **album grouping** — one post,
`mediaCount` media, trailing ids absent by design rather than deleted.

**Done:** fixture tests pin **every** field against committed HTML, including one reply, one
poll, one forwarded post and **one album** (`tgme_widget_message_grouped`). This is `TD-1`'s discharge and the tests are the point of the slice.

### S3.5 — URL resolution ✅ *(done)*
Populate `url_resolution` for every canonical URL. Input is
`Spec/url-canonical/corpus-canonical.tsv`, which already exists, so this is unblocked **now**.
One request in flight per host, up to ~8 hosts concurrently: ~33 min for 9,770 URLs.

**Delivered.** All **9,770** resolved via `Scripts/resolve_urls.py`, imported by
`Store.importResolutions(fromJSONLAt:)`. 49% redirect, 23% cross-host, 19% fail (`TD-17`
predicted ~18%). **1,630 keys (17%) change** — each a row that would otherwise silently fail to
join with `artanl` — while only 158 identities merge internally, so this is a **seam feature
rather than a dedupe one** (<doc:Design>).

### S4 — crawler ✅ *(done)*
Page by returned ids, never a stride. Polite by default. Per-channel watermarks so a re-run is
incremental. The four-way channel classifier for `doctor`.

**Crawl state lives in the database, not a side file.** A separate watermark file was built
first, with atomic writes — and then deleted, because the file itself was the problem: it drifts
from the store. Deleting the database while the file survived left a channel with 17 posts and a
mark of 181, and sync "resumed" from it, skipping the backfill. Deriving the mark from the store
does not help — the gap is *below* the mark. Only `backfillComplete`, written beside the posts it
describes, distinguishes "up to date" from "never finished".

**Delivered.** `WebPreviewSource` pages by returned ids with per-channel watermarks;
`ChannelClassifier` implements the four-way `doctor` check; crawl state lives on the channel
row, in the same database as the posts, so the two cannot drift.
Nine hermetic tests over committed fixtures, plus an env-gated live suite
(`TGKB_LIVE=1 swift test --filter LiveCrawl`) that verifies the done-criterion directly: a full
backfill returns **136 posts spanning ids 1–297**, exactly reproducing the independent Python
crawl, and a re-run fetches one page.

---

## Track C — retrieval *(after B, not alongside it)*

### S5 — `tgkb sync`, `query`, `doctor` ✅ *(done)*
CLI search over the store. Exists before the MCP server because it is how the evals run without
an MCP client in the loop.

**Done:** `G1`–`G10` in `evals/golden-queries.md` are runnable and produce numbers.

**Delivered in PR #1, through thirteen Devin review rounds: 34 inline findings, exactly one of
which did not reproduce.** Every one
of those rounds found a bug in crawl-state handling, and in two of them some findings were bugs
the previous round's fixes had introduced. So the state decisions now live in `Store.CrawlState` as pure,
tested functions, and every fix gets a mutation check: the fix is reverted and its test must fail.
Those checks stopped being hand-run in round 8 — `Scripts/mutation-check.sh` replays 29 of them
from `Scripts/mutants/*.patch`, each patch putting one fixed bug back. The review lessons are encoded
in `REVIEW.md`.

### S5.5 — groups from a chat export, `tgkb import` ✅ *(done)*
Inserted 2026-09-21. A knowledge base beyond iOS needed groups: the FSTEC/ISP RAS static- and
dynamic-analysis community lives in public groups (`@sdl_static`, `@sdl_dynamic`), which no
Phase-1 source reaches. Rationale is in <doc:Design> § *A chat export is the way in for a group*.

- **Track A first, as its own commits:** `FormatSource.export`, and store reads for a channel's
  identity, its stored ids, and reachability in `Integrity`.
- **Then B:** `ChatExportParser` for the HTML a Telegram client writes, and `MessageEmbed` for
  the one web page a group's message has.
- **Then the sync library:** `ChatImport` verifies against one embed, allows one chat one row, and
  writes in batches of `commitPage`.
- **Then C:** `tgkb import`, plus `doctor` wording for groups.

**Done:** a real export of a 12,471-message group imports in 38 s (release build), verified
against `t.me`. Every count matches the markup: none unreadable, 1,324 service messages, and
photos, files, polls, reactions, previews and replies as counted in the HTML. A Russian query
returns its messages with permalinks.

### S6 — `tgkb-mcp`
**Load the `mcp-builder` skill first** — it is from `anthropics/skills`, already installed, and
covers exactly this. Designing the tool surface from the SDK research alone would skip it
(`research/skills-landscape.md`).

`search_posts`, `find_links`, `get_post`. Compact records, opaque cursors, a `t.me` link on
every row, `find_links` keyed on `url_canonical`. Annotations set explicitly — the SDK defaults
are `destructive: true`, `openWorld: true`. All diagnostics to stderr; fd 1 redirected at
startup.

**Carried in from S5 and a DeepWiki second opinion** (2026-09-15, <doc:Research>):

- `search_posts` calls `Store.search(_:mode:limit:)` and never merges indexes itself; it
  returns `total` beside the cursor, so a truncated list is never silent (<doc:Design>).
- The MCP protocol, and so the MCP Swift SDK, paginates **list** operations (`tools/list`,
  `resources/list`) but has **no cursor for `tools/call`** results: pagination of search results
  is ours, as a `cursor` tool parameter and a `next_cursor` output field. (Not TDLib, which
  paginates its own history and search calls.)
- Records go in `structuredContent` with a declared `outputSchema`, plus a short text
  `content` for clients that render only text.
- Set all four annotations, `destructiveHint: false` and `idempotentHint: true` included.
- Arguments are not validated against `inputSchema` by the SDK: decode and reject with
  `invalidParams` ourselves.
- Keep `strict` initialisation on, check `Task.isCancelled` in handlers, and keep each
  `dbPool.read` short. A long read holds a stale snapshot and blocks WAL checkpoints.

**Settled before writing any of it, after a prospective DeepWiki review of this plan**
([conversation](https://deepwiki.com/search/i-am-planning-the-next-slice-s_fb2c1572-dfc1-45e4-aab6-30dabe7e8750?mode=deep),
2026-09-20 — it reads the default branch, so it judged the plan against the code and the docs,
which is exactly what a prospective ask is for):

- **This slice needs new `TelegramKBStore` API** — channel, date and kind filters, a cursor, a
  count — and the track table below says Track C never touches that target. The boundary wins over
  the convenience: those additions are **Track A work, done first and separately**, and S6 consumes
  them. Discovering this mid-slice would have been scope creep wearing a deadline.
- **`find_links` keys on `url_canonical` AND searches `effective_url`.** The Roadmap said the
  former and Design says the join key is the latter; a tool that searched only the canonical form
  would silently miss the 17% of URLs whose key changes on resolution — the very failure
  `S3.5` existed to remove. It returns `url_canonical`, because that is the form the maintainer
  asked to see, with the resolved target beside it.
- **Channel parameters take one round-trippable string**, the same literal the record emits
  (`@username`), per Design § *MCP tool surface*. No id/hash/type triple, no resolve call inside
  the model's loop.
- **`Scripts/check-invariants.sh` is part of this slice's done test**, not a habit: `tgkb-mcp`'s
  closure is the one invariant a new target can break silently.

**Done:** Claude answers "what has anyone shared about X" with cited `t.me` links.

---

### S7 — channel identity by `rawChannelID`
Schema `v4`. `rawChannelID` becomes the channel key and `post`'s foreign key; `username` becomes a
unique-when-present label with its own index. Permalinks keep rendering from the username, falling
back to the `t.me/c/<rawChannelID>/<id>` form when there is none. Rationale, including what it
costs, is in <doc:Design> § *Channel identity is `rawChannelID`, not the username*.

Comes **before Phase 2**: TDLib reconciliation joins on this id (`TD-8`), and a username rename
would otherwise orphan a channel's whole history (`TD-19`).

**Done:** a channel renamed between two syncs keeps one row and one history, proven by a test that
renames the username and re-crawls; `doctor` still reports per-channel integrity; permalinks
resolve for a channel with no username.

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
`@AllByiOS` (a group). A group can already come in from a chat export (`S5.5`); TDLib adds
incremental updates and the chats nobody exported.

**Fetch through Telegram's own export.** The clients' exporters use the takeout API. A
`tgkb` fetch path through it would take a whole chat, including one never synced, and feed the
same `ChatImport` that `tgkb import` uses. The manual export step goes, and the parse-and-write
path stays one. It needs the logged-in session this phase brings. Telegram may delay a data
export on a new device by hours ("you will be able to begin downloading your data in…"), so the
first run needs a session that has already cleared that.

## Next — Phase 3: retrieval quality

(Lemmatisation, once planned here, shipped in S2 — `TD-4`.) Links promoted to first-class entities with cross-channel
dedupe. Reactions as a ranking signal. The `artanl` join on `url_canonical`, and its extracted
text in a **separate FTS table** (`TD-12`). Dual search — local index and Telegram's live `?q=`
merged, since theirs caps at ~22 and ours is a crawl-time snapshot. Semantic search decided from
eval evidence, not in advance (`TD-9`).

## Later — Phase 4: write operations

Send, forward-to-Saved-with-tag, drafts. Human confirmation on every one. Settle first where
TDLib lives once MCP needs it — the four options are in <doc:Design>, unanswered on purpose.

---

## Publication

**Public since 2026-09-16.** Decisions taken before that, recorded so they are not re-asked:

| Question | Decision |
|---|---|
| Licence | **Apache-2.0** (`LICENSE`, 2026-09-15). Every dependency is MIT, Apache-2.0 or Boost. |
| `t.me/+…` invite links in the golden URL files and fixtures | **Kept.** Scraped from public channels, mostly dead; not worth rewriting history over. |
| Working notes (`SYNC-*.md`, `OPEN-QUESTIONS.md`) | **Kept in the repository** as the record of how decisions were reached. |
| DeepWiki | Badge added ahead of publication so the wiki indexes and auto-refreshes. |
| Captured third-party content | Fixtures and corpus URLs are other people's posts, included as test data and excluded from the licence grant — said in `README.md`. |

Still open now that it is public:

- Check the first generated DeepWiki against `.devin/wiki.json` — steering has no success signal.
  **It indexes the default branch**: asked on 2026-09-16 it correctly reported no `Store.CrawlState`
  and no `Sources/tgkb/Sync.swift`, because `main` is still the Phase 0 scaffold while the work sits
  on the PR branch. The wiki is worth nothing as a review aid until this merges — the same root
  cause as the licence detection above.
- GitHub's licence detection reports none, because it reads the **default branch** and `LICENSE`
  currently exists only on the PR branch. It resolves on merge — the file itself is byte-identical
  to `apache.org/licenses/LICENSE-2.0.txt` (sha256 `cfc7749b…`), verified against the source.
- `TD-15` (`robots.txt`) stays deferred by the maintainer's decision until this is production
  ready. `tgkb` itself fetches only `t.me`, which publishes no `robots.txt`;
  `Scripts/resolve_urls.py` is the part that requests third-party hosts.

## Working in parallel

| Track | Owns | Never touches |
|---|---|---|
| A | `TelegramKBModel`, `TelegramKBStore`, migrations | anything else |
| R | `S3.5` resolution — runs standalone against the golden file, writes JSON until S2 exists | any source target |
| B | `TelegramKBIngest`, `research/fixtures/` | `TelegramKBMCP`, `Sources/tgkb-mcp` |
| C | `TelegramKBMCP`, `Sources/tgkb`, `Sources/tgkb-mcp`, `evals/` | `TelegramKBIngest` |

Track R (resolution) remains genuinely parallel — it needs neither the store nor the parser.

**A blocks B, and B now blocks C.** An earlier draft ran B and C in parallel. That was wrong:
building the parser and crawler surfaces markup and data cases that should *shape* the query and
MCP surface, and designing those first would mean designing them against assumptions rather than
findings. The dependency runs one way — implementation informs interface, not the reverse. The direction docs are shared: edit them
in small, anchored changes, never by line-index surgery — that has already destroyed content
here once.

`Scripts/check-invariants.sh` must pass before every commit on every track.
