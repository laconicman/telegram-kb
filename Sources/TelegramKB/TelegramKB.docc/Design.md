# Design

One decision per section: what was decided, why, and what was rejected. Evidence lives in
`research/`; this records the conclusions and the reasoning.

## Two executables over one store

**Decision — adopted.** `tgkb` (ingestion, owns TDLib and all credentials) and `tgkb-mcp`
(read-only MCP server) as separate executables over one SQLite file.

The brief proposed this and asked for it to be pressure-tested rather than accepted. It
survives, and the evidence strengthened it:

- **The MCP process genuinely needs nothing.** Phase 1 requires no TDLib *at runtime* and, once
  trait-gated, none at *build* time either. `tgkb-mcp` starts with no network, no auth state and
  no ban exposure — the properties the brief wanted.
- **The storage layer supports it.** A separate reader process saw a concurrent writer's commits
  monotonically across 60 reads with zero errors, and FTS5 `MATCH` works from a read-only
  connection (`research/sqlite-cross-process-probe.md`).
- **The freshness objection is weak here**, exactly as the brief argued. The corpus is
  historical; a periodic `tgkb sync` is not a compromise.

**Rejected: one process, `MCP adapter → domain → TDLib transport`.** It would put a large binary
artifact and a live auth state machine behind a stdio server that is spawned per session and
should start instantly. It also puts credentials in the process most exposed to untrusted input.

**Cost accepted:** no live search until a `search_live` tool arrives in Phase 3, and the user
must run `tgkb sync` periodically.

**MVP concurrency: an explicit lock.** Rather than relying on SQLite's own locking alone, the
writer takes an advisory file lock for the duration of a sync and the reader tolerates its
absence. This is a deliberate MVP choice, not a permanent one — it trades some concurrency for a
failure mode that is easy to reason about while the schema is still moving. **The wider question
— whether SQLite/GRDB is the right engine at all for a two-process design — is open and worth a
dedicated research pass** rather than an assumption inherited from the brief.

**Caveat that must be designed for, not discovered.** GRDB's own `DatabaseSharing.md` opens by
discouraging database sharing, and its concrete hazard for us is that
*"GRDB DatabaseObservation does not detect changes performed by external processes"* — the MCP
server cannot observe the writer, and must not be built as if it could. Two mitigations, both
required, not alternatives: the writer sets `SQLITE_FCNTL_PERSIST_WAL`, **and** the database
directory stays writable by the reader. Either alone leaves an intermittent failure path where
a read-only open dies with `attempt to write a readonly database` — an error that names the
wrong file and sends the reader hunting in the wrong place.

## One package, not two — the TDLib artifact is trait-gated

**Decision.** A single `telegram-kb` package with a `TDLib` trait, default **off**, gating both
the `TelegramKBIngestTDLib` target and the TDLibKit dependency.

The brief asked whether SwiftPM traits can prevent a consumer from pulling the large artifact,
and asked for it to be verified rather than assumed. **Verified: yes**
(`research/spm-traits-binarytarget.md`). With the trait off, SwiftPM does not download the
artifact, and `swift package show-dependencies` reports the dependency as *absent from the graph
entirely* — not merely unlinked.

**Rejected: splitting the TDLib ingestion into a second package.** It would buy nothing the
trait does not, at the cost of a second repository, a second version number and a split test
suite.

The brief's hard invariant — `tgkb-mcp` must not transitively depend on
`TelegramKBIngestTDLib` — is enforced by `Scripts/check-invariants.sh`, which checks the
dependency graph, the artifact directory, and the linked symbols of both binaries.

**Pinning note.** TDLibKit's tags are pre-release-shaped (`1.5.2-tdlib-1.8.66-022d6020`).
SwiftPM excludes pre-release versions from range resolution, so a `from:`/`upToNextMinor`
requirement will not select them at all. The dependency must be `.exact(...)`. This is `TD-5`.

## Two sources, one row

**Decision.** The web preview is the *primary* source; TDLib is the *completeness* source. Both
write the same rows, keyed on `(channel_raw_id, post_seq)`.

The brief called ID alignment "the load-bearing question for a two-source design". It is
**resolved**, from TDLib source and cross-checked against real crawled data:

```
chat_id    = ZERO_CHANNEL_ID - channel_id    // ZERO_CHANNEL_ID = -1000000000000  (DialogId.h:27)
message_id = Int64(post_seq) << 20           // SERVER_ID_SHIFT = 20   (MessageId.h:27, :60)
```

The decisive corroboration is that **TDLib's own link builder emits
`t.me/<username>/<message_id >> 20>`** — the number in a `t.me` URL *is* the unshifted TDLib id,
which is exactly what the web preview's `data-post` gives us. The two sources already share an
identifier; we are not inventing a mapping.

Two guards, both from source:
- A TDLib id is a *server* id only when `id & 0xFFFFF == 0`. Non-zero low bits mean a local,
  unsent or scheduled message with no web counterpart.
- **Apply the `-100` prefix arithmetically, never by string concatenation.** Monoforum channel
  ids reach `3000000000000`, producing chat ids near `-4000000000000`, outside the `-100…` text
  pattern. The string trick works for ordinary channels and fails silently for those.

**Still a Phase 2 gate:** an end-to-end join against a live client. Confidence is high; proof is
not yet in hand.

**Rejected: web-only.** ~13% of posts in the sampled corpus carry no text, private channels are
invisible, and reaction counts drift between crawls.

**Rejected: TDLib-only.** It puts the riskiest operation — bulk backfill of a logged-in account
— on the critical path for content that is freely readable without an account at all.

## The web preview is a first-class source, not a fallback

**Decision.** Treat `https://t.me/s/<channel>` as the primary ingestion path for public channels.

The brief proposed elevating this and asked for empirical verification. Everything it hoped for
held, and more (`research/web-preview-probe.md`): reactions **are** present with exact counts,
history reaches message id 1, link previews arrive with Telegram's own resolved OG metadata, and
there is no rate limiting at casual crawl volumes. There is no `robots.txt` at all — a factual
observation about crawl directives, and explicitly *not* a claim about Telegram's Terms of
Service, which is a separate instrument and the author's call.

An undocumented `?q=` search endpoint also exists and works without login. **It is used as a
test oracle, never as a runtime dependency** — it is undocumented, its normalisation is opaque,
and it could vanish without notice. It has already earned its keep: comparing our index against
it revealed a parser bug that would otherwise have shipped.

## A local index, because Telegram's search cannot be reasoned about

**Decision.** SQLite FTS5 is the search engine. Telegram is ingestion only.

Measured, not assumed. Telegram's `?q=` has **no substring matching** (`imation` → 0 hits) and
its normalisation is **opaque**: `anim` ≡ `animation` ≡ `animations` returns one set of 15, but
`animat` ≡ `Animatable` returns a *different* set of 2. That is not prefix expansion and it is
not a documented stemmer. The problem is not that it is limited in a predictable way we could
work around — it is that its recall is unpredictable, and we could never explain to a user why a
query missed a post we know exists.

## FTS5 tokenisation: dual index now, lemmatisation later

**Decision.** Index each post body twice — `unicode61 remove_diacritics 2` for ranked word
search, `trigram` for substring — and union at query time.

**This decision exists because the naive version loses to Telegram.** On Russian morphology
Telegram is *better* than a plain FTS5 prefix index: `навигация`, `навигации` and `навигацию`
all return the same three posts, while `навигация*` misses one of them because the inflected
form diverges before the prefix ends. SQLite has no Russian stemmer. A local index that ignores
this regresses against the thing it replaces, in the corpus's dominant language.

The dual index wins where Telegram cannot follow — substring (`imation`: 0 → 14) and short
prefixes (`навига`: 0 → 3) — and Phase 3 lemmatisation closes the morphology gap.

- **Rejected for v1: a custom `FTS5WrapperTokenizer` doing Russian suffix stripping.** It works
  cross-process only if both executables register an identical tokenizer; a connection missing
  it fails at *step* time with `no such tokenizer`. The real hazard is worse than that loud
  error — on version skew the two processes tokenise *differently* and the index silently
  disagrees with the query. Not worth it when the dual index reaches the same recall.
- **Deferred to Phase 3: `NLTagger` lemmatisation** into a parallel lemma column. It subsumes
  the custom tokenizer, handles Russian properly, is macOS-native, and arrives anyway with the
  semantic-search work.

Untrusted query text is converted with GRDB's failable `FTS5Pattern.matching…` initialisers,
which discard FTS5 operator characters. Only `rawPattern` throws, and it takes no user input.

## SQLite + GRDB stays — no challenger cleared the bar

**Decision.** SQLite + GRDB + FTS5, as scaffolded. Reviewed deliberately rather than inherited
(`research/storage-engine-options.md`), with the burden of proof placed on the challenger.

- **DuckDB** — the strongest technical alternative — **fails the founding criterion outright**:
  its own documentation permits one process reading *and* writing, or many reading and *none*
  writing. Our topology is exactly the case it excludes. Its Swift binding also has no stable
  tag, the same hazard as `TD-5`.
- **Meilisearch / Typesense / Qdrant** are daemons. A single-user local tool should not acquire
  a service to supervise.
- **Tantivy** wins on built-in Russian stemming, and costs a Rust toolchain plus a second binary
  artifact to obtain what `NLTagger` already provides free.
- **Realm** is vendor-deprecated. **LMDB / RocksDB** have neither text nor vector search.
  **SwiftData / Core Data** would hide the FTS5 that is the entire point.

**Vector search, when it arrives, also stays in SQLite.** `sqlite-vec` benchmarks at 100k × 512
dimensions in **71 ms**, so the absence of an ANN index is a non-issue at this corpus size. One
platform trap to record: **macOS system SQLite is built `OMIT_LOAD_EXTENSION`**, so every
published `sqlite-vec` loading instruction is inapplicable and `sqlite3_auto_extension` returns
`SQLITE_MISUSE`. Calling `sqlite3_vec_init(db, …)` directly works against stock `-lsqlite3` with
no GRDB fork.

**Rejected: switching engines at all.** The incumbent is verified working cross-process, links
the system SQLite (so FTS5 and `trigram` need no custom build), and its one documented weakness —
multi-process sharing — is mitigated rather than fatal.

## TDLib, not a pure-Swift MTProto client

**Decision.** `Swiftgram/TDLibKit` + the prebuilt `Swiftgram/TDLibFramework` XCFramework.

Writing MTProto means implementing a bespoke crypto handshake correctly, and getting it subtly
wrong is a security problem, not a bug. TDLib is Boost-licensed, is what Telegram themselves
ship, and handles `FLOOD_WAIT` internally.

**Hard wall: never vendor code from `Telegram-iOS` or `Swiftgram/Telegram-iOS`.** Both are
GPLv2; copying from them would relicense this project. TDLib (Boost), TDLibKit, TDLibFramework,
GRDB, SwiftSoup and the MCP SDK (all MIT) are fine.

A consequence worth recording: `getChatHistory` is gated `CHECK_IS_USER()`, so **a bot account
cannot backfill history at all**, and reaction updates via `updateMessageReaction` are bots-only.
The two constraints point opposite ways and settle the question — this must run as a user
account, and reaction sync must use `updateMessageInteractionInfo`.

## MCP tool surface

**Decision.** Few composable tools, compact records, opaque cursors, always a `t.me` link.

Search results return `(channel, date, author, snippet, reactions, t.me link)` — never full
bodies. Full text comes from a follow-up `get_post`. A result list that dumps whole posts
wastes the context window that the tool exists to protect.

**Every returned record carries a `t.me` permalink.** Of seven Telegram MCP servers surveyed,
**not one emits one** — `chaindead` drops the message id from its response entirely, so its
output cannot be cited even in principle, and `dryeab` ships a competent `t.me` URL parser it
uses only inbound. Citation is the whole point of retrieval here; the link is not a nicety.

**Peer addressing uses one round-trippable string**, borrowed from `chaindead`: the listing tool
emits exactly the literal the next tool accepts (`@username`, or a synthetic form for channels
without one). One parameter instead of an id/hash/type triple, and no resolve call inside the
model's loop.

## Why `tgkb` has no `serve` subcommand

**Decision.** `tgkb` does **not** expose `serve`. The only way to run the MCP server is the
`tgkb-mcp` binary.

The objection is not redundancy. It is that **a working fat path erodes an invariant that is
otherwise enforced by construction.** `tgkb serve` would not make `tgkb-mcp` heavier — it would
make it *vestigial*. Whichever binary the Claude Desktop config points at becomes the real one,
and if the all-in-one works, that is the one everybody uses. The slim binary would then exist
only as documentation of an intention nobody is forced to honour.

**`query` is not the same case and stays.** It needs only `TelegramKBStore`, it is how retrieval
is exercised and the golden-query evals are run without an MCP client in the loop, and `tgkb` is
the fat binary by design. The distinction is whether the subcommand duplicates the *product*
(`serve` does) or merely uses the shared library (`query` does).

The invariant is stated **positively**: `tgkb-mcp`'s transitive target closure must be exactly
`{TelegramKBMCP, TelegramKBStore, TelegramKBModel}`. A check for the *absence* of
`TelegramKBIngestTDLib` would pass for the wrong reasons as the graph grows — it would still
pass if someone added a different heavyweight target. `Scripts/check-invariants.sh` implements
the allowlist, and a negative test confirms it fails on any addition.

## OPEN — where does TDLib live once MCP needs it? *(unanswered, deliberately)*

Phase 3's `search_live` and Phase 4's write operations both want TDLib **inside the MCP
process**. That is the genuine fork, and `serve` was quietly pre-empting it. Recording it here
unanswered is better than answering it today by widening a binary.

Four options, none yet chosen:

1. **Collapse the split** — one process again. Cheapest to build, discards every property the
   split was for.
2. **A `tgkb` daemon over a Unix socket**, with `tgkb-mcp` as a thin client. Two prior-art
   projects independently converged on this, which is some evidence it is the natural shape.
   Costs a lifecycle problem: who starts the daemon, and what happens when it is not running.
3. **Spawn `tgkb` as a subprocess per write.** The invariant survives intact.
4. **Keep writes out of MCP altogether** — Claude proposes, the human runs `tgkb`.

**Current lean, not a decision: (3) is stronger than it first looks.** Write operations are
low-frequency and human-confirmed *by design*, so a process spawn per write costs nothing that
matters, and the dependency graph stays clean. But this is a Phase 3 decision that deserves
Phase 3 evidence — in particular, whether `search_live` (which is *not* low-frequency) can
tolerate the same treatment. It probably cannot, and that asymmetry may split the answer:
subprocess for writes, something else for live search.

## The `artanl` seam — this project does not fetch or tag articles

**Decision, superseding an earlier one.** `telegram-kb` does **not** build its own article
fetcher or tagger. A sibling project — the local-LLM article analyzer (`artanl`) — owns both.
The two meet at a single co-owned key.

```
telegram-kb                       artanl
(posts, channels, FTS, search)    (articles, attributes, tags)
        │                               │
        └────────  url_canonical  ──────┘     ONE spec, versioned, both sides test it
```

I previously specified a fetch stack for this repo. That was the wrong scope: the analyzer had
already designed a better one, in a language with better tools for it, and duplicating it would
have created two crawlers and two extraction paths over the same URLs.

**What each side owns:**

| `telegram-kb` | `artanl` |
|---|---|
| Telegram ingestion — both sources | Article fetching (the tier ladder) |
| The **post** grain | The **article** grain |
| FTS, ranking, semantic search | LLM tagging, `format`, `topic`, `complexity` |
| The MCP tool surface | The controlled vocabulary |

**Rules that make this work, taken from the analyzer plan:**

- **Both sides implement the same canonicalisation spec**, against a shared fixture list.
  Resolve → canonicalise → dedupe. Follow every redirect hop, upgrade `http://`→`https://`
  (529 corpus URLs), strip `utm_*`/`ssource`/`share`/fragments, store the post-redirect URL as
  canonical and keep the original. **Divergence is a test failure, not a discovery.**
- **Grains stay different.** 479 links are shared across more than one channel: many posts, one
  article. Neither side models the other's grain.
- **Either side can be broken for a better result.** Neither store exists yet, so migration cost
  is zero — and this project is 25 lines of placeholder Swift, which is the cheapest moment to
  take a dependency-shaped decision back.

**Rejected: `telegram-kb` fetching link content itself.** It would duplicate the tier ladder,
put a crawler in the process that must stay ban-free, and split extraction across two languages.

**Rejected: one combined store.** The grains genuinely differ, and the analyzer must work with
no Telegram at all — which is what "independently valuable" means operationally.

## Coverage: no site is ignored, because the ladder has a floor

The requirement is that **no source is written off**. The analyzer's fetch ladder satisfies it
structurally rather than by effort: every URL descends tiers until something works, and

> **Tier 4 is Telegram's own preview metadata — which `telegram-kb` already stores.**

So the floor is *this project's* data, and it guarantees that no URL ever yields nothing. That is
the strongest reason for the seam to run in this direction: our worst case is the analyzer's
safety net.

Two consequences that are ours to honour:

1. **Store the preview even when we will never fetch the page** — it is the fallback of record,
   not a nicety. Site, title, description and resolved URL, for every link.
2. **Store `url_canonical` alongside the raw URL at ingest**, so the join key exists from the
   first crawl rather than being back-filled.

**Note on `robots.txt`:** compliance is deliberately **not** a constraint on the engine at this
stage — the author's explicit call, recorded as `TD-15` rather than silently assumed. What is
*not* deferred, because the ladder makes it unnecessary rather than because it is disallowed:
**no CAPTCHA solving and no TLS/JA3 fingerprint spoofing at any tier.**

## URLs: store both forms, derive the canonical, rewrite nothing

**Decision.** Every link is stored **twice** — `url_raw` exactly as it appeared in the post, and
`url_canonical` derived from it. Both are searchable. `find_links` returns `url_canonical` as the
identity.

The governing principle is that **canonicalisation is derived, never destructive**. What was
crawled is a fact about the post and cannot be rewritten; the canonical form is an index built on
top of it. Three consequences that make this more than pedantry:

- **The spec will change.** Canonicalisation is a heuristic — a new tracking parameter, a new
  shortener, a redirect that starts resolving differently. When it changes, `url_canonical` must
  be **recomputable from `url_raw` without re-crawling**. If we had stored only the canonical
  form, every revision would mean a full re-crawl, and older rows could never be brought into
  line with newer ones.
- **Both forms are legitimately searchable.** Someone may search for the shortener they actually
  saw in the channel, or for the destination. Neither is wrong, and the raw form is often what a
  person remembers.
- **Divergence becomes debuggable.** With both stored, a join failure against `artanl` shows
  exactly which side canonicalised differently. With only the canonical stored, the same failure
  is invisible (`TD-16`).

`url_canonical` is therefore a **derived column with a spec version recorded beside it**, so a
spec bump is a recompute over `url_raw` rather than a migration that loses information.

**Rejected: storing only the canonical form.** Smaller, and it makes the spec unrevisable.
**Rejected: canonicalising at query time only.** It would make the join key non-indexable, which
defeats the seam.

## Post kind is modelled, and it is not one field

**Decision.** A post carries a **`kind`** (what it *is*) plus **orthogonal modifiers** (how it
arrived). Conflating them into one enum is the mistake to avoid: a forwarded video album that
replies to something is all four things at once.

```
kind      : text | photo | album | video | videoNote | audio | voice
            | document | poll | sticker | location | giveaway | unknown
modifiers : isForwarded (+ origin channel, origin post id, origin author)
            replyTo (post id)
            mediaCount (≥1; >1 means album)
            formatSource: tdlib | web | absent
```

`kind` is **free and deterministic** where a source supplies it — TDLib's `SearchMessagesFilter`
has 20 variants, so a video post *is* a video with no tokens spent and no hallucination surface.
That is why `artanl` should only infer `format` for text-plus-link posts, where it is genuinely
ambiguous. Everything else is a lookup.

But the signal is **TDLib-complete and web-sparse**, which is why `formatSource` exists rather
than a bare enum: of 625 sampled web posts, document, audio, voice, sticker, location and round
video appear **zero** times, while polls and forwards appear at ~1.3% each. A consumer must be
able to tell "this is not a document" from "this source cannot say".

### Albums are one post over many message ids — and that breaks two assumptions

Verified in the web preview: `tgme_widget_message_grouped` renders **one** `data-post` id
containing several media. Measured on `@ios_broadcast`: post 581 spans ids 581–586, post 587
spans 587–591, post 977 spans 977–984. The trailing ids are absent from the crawl entirely.

Two things I had recorded earlier are wrong or incomplete because of this:

1. **The 54% message-id gap is not mostly deletions.** I listed "deletions, album grouping,
   service messages" and treated albums as a minor term. An album swallowing 5–8 consecutive ids,
   occurring regularly, is a large part of that gap. **A missing id is not evidence a post was
   deleted**, and anything that infers deletion from absence will be wrong.
2. **The two sources disagree on an album's grain.** The web preview gives one post; TDLib gives
   *N* messages sharing a `media_group_id`. The ID transform is still correct — but a naive
   reconciler would create N rows from TDLib against 1 from the web and treat the difference as
   missing data. Folded into `TD-8`, which is already the Phase 2 gate.

**Decision:** the album's **first message id is the post identity**, `mediaCount` records the
span, and TDLib ingestion must group by `media_group_id` before writing rather than after.

## OPEN — should `telegram-kb` store `format` at ingest? *(seam question)*

TDLib's `SearchMessagesFilter` has 20 variants, so a video post is deterministically a video and
an audio post a podcast — **a free `format` label with no tokens spent and no hallucination
surface**. The analyzer's inclination is that we should store it and hand it over, making
`format` an input rather than a task for all but text-plus-link posts.

**My answer: yes, with a caveat the analyzer plan could not have known.** I probed the web
preview for exactly this: forwarded and poll markup are present, but **document, audio, voice,
sticker, location and round-video markup are entirely absent from 625 sampled posts**. So the
signal is TDLib-complete and web-*sparse* — not because the parser misses it, but because this
corpus does not contain those types.

Practically: store `format` where a source supplies it, mark it `source: tdlib|web|absent`, and
do not let the analyzer assume the field is populated for web-ingested posts. Also worth taking:
`searchMessagesFilterUrl` is a **server-side** "messages containing a URL" filter, which lets a
channel's link-bearing posts be enumerated without walking its whole history — directly useful
for a link corpus.

## Login happens in the CLI, never over MCP

**Decision.** `tgkb login` is an interactive CLI subcommand. The MCP server never authenticates;
it refuses to start if the store is missing, rather than starting and failing per call.

Interactive auth over a stdio MCP channel is an awkward problem, and the survey settles it:
**all four serious prior-art projects punted to a separate CLI step, and they were right.**
Nobody attempts login over the MCP channel. One idea worth taking beyond that — `chigwell`'s
**QR login**, which removes the SMS-code prompt from the flow entirely.

**One thing every surveyed project got wrong: the session file is unencrypted in all of them**
(plaintext JSON, or a Telethon SQLite session). On macOS there is a Keychain; secrets go there,
and the session lives in `~/Library/Application Support/`.

**Fail fast**, following `chaindead`: `serve` stats the store and refuses to start without it,
rather than surfacing the same error on every subsequent tool call.

## What the prior art does not do — and why that is a warning, not just an opening

Seven Telegram MCP servers surveyed. **None has a full-text index of any kind.** The only one
with a persistent message store searches it with `SELECT … WHERE text LIKE ?`; a grep of its
source for `fts5|MATCH` returns nothing. None filters by media type; none exposes reactions as a
filter.

So the gap this project targets is real. But three things keep that honest:

1. **The gap is unoccupied because it is expensive, not because nobody noticed.** Every project
   surveyed made a deliberate choice to stay stateless or cache-only. Our differentiator is the
   index, the backfill and survivable ingestion — *not* the tool schemas, which are the cheap
   part and where prior art is genuinely useful to copy.
2. **The field is crowded at a shallower depth.** The leader has ~1,500 stars and is actively
   committed to. We are not entering an empty field.
3. **Nobody handles `FLOOD_WAIT` — both primary targets have literally zero rate-limit code.**
   For a live-query wrapper that is a bug. For a backfilling indexer it is the main loop. This
   is the risk most likely to actually bite us, and prior art offers no help with it.

**Logging is a correctness issue, not a convenience.** On a stdio transport, **stdout *is* the
protocol** — the MCP spec states the server "MUST NOT write anything to its `stdout` that is not
a valid MCP message". A stray `print()` corrupts the session. The SDK's only protection is that
`StdioTransport` defaults to a no-op log handler, and — this is the trap — **the SDK README's own
"Debugging and Logging" example bootstraps `StreamLogHandler.standardOutput`, which breaks a
stdio server if followed literally**. All diagnostics go to stderr; the process redirects fd 1
defensively at startup.

## See Also

- <doc:Roadmap>
- <doc:TechDebt>
- <doc:Research>
