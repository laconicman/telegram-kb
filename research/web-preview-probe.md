# Web-preview ingestion probe — `https://t.me/s/<channel>`

Empirical results for brief §3. **All probes run by me on 2026-08-23** from a residential
macOS host via `curl`, desktop Chrome UA. Fixtures in `research/fixtures/`, reproducible via
`research/probe.sh`.

Everything under **Verified** below I observed directly. Everything under **Unverified** I
could not probe in this session and must not be relied on.

---

## Verdict

**The web preview is a stronger ingestion source than the brief assumed, and it should be the
primary one.** Three findings change the design:

1. **Reactions are present** in the preview HTML (emoji + count, including paid/star
   reactions). The brief marked this uncertain and "materially affects ranking design" — it is
   now settled in favour of reaction-aware ranking from Phase 1, with no TDLib dependency.
2. **Full history is reachable.** `?before=` walks back to message id 1. There is no shallow
   window. A complete public-channel backfill needs no login at all.
3. **There is an undocumented server-side search endpoint** — `?q=<query>` — that works with
   no login, no `api_id`, and composes with pagination. The brief did not know about this. It
   does **not** remove the need for a local index — it has no substring matching and its
   normalisation is opaque — but it is an excellent *oracle*: I used it to measure our own
   index's recall, and that is how I found a parser bug (below) that would otherwise have
   shipped.

**One finding cuts against the plan, and it should be read before the good news.** On Russian
morphology Telegram's own search is *better* than a naive FTS5 index: it collapses inflected
forms, and SQLite has no Russian stemmer. A local index that does nothing about this has
**worse** recall than the thing it replaces, on the corpus's dominant language. This is
solvable and I recommend how below, but it must be solved rather than assumed away —
`TD-4` is a real risk, not a formality.

Also material: **link previews arrive with Telegram's own resolved OG metadata** (site name,
title, description, canonical URL). The brief's Phase 3 plan to promote links to first-class
entities with "resolved title/OG metadata" mostly does not require us to fetch the target URLs
ourselves — Telegram already did it, and the result is in the HTML we are already parsing.

**The brief's "load-bearing question for a two-source design" — message-ID alignment — is
answered.** The web preview's `data-post` number and TDLib's `message_id` differ by exactly a
20-bit shift, and TDLib's own link builder emits `t.me/<username>/<message_id >> 20>`, so the
identifier in a `t.me` URL *is* the TDLib id unshifted. The two sources already share a key.
Formulas, guards and sources are below; an end-to-end join against a live client remains a
Phase 2 gate.

---

## Verified

### Access and politeness

| Probe | Result |
|---|---|
| `https://t.me/robots.txt` | **HTTP 404** (nginx default 404 body). No robots.txt exists at all. |
| 40 back-to-back `?before=` requests, zero delay | **All HTTP 200.** No 429, no Cloudflare challenge, no CAPTCHA, no degradation. |
| Wall time for those 40 requests | **113 s ≈ 2.8 s/request average**, entirely server-side latency. |
| Latency distribution | Bimodal: ~0.45–0.6 s (warm) vs ~4–6 s (cold). |

Two honest readings of this:

- There is **no robots.txt to violate**, and under RFC 9309 an absent robots.txt means no
  crawl directives are expressed. That is a factual observation, *not* a licence — Telegram's
  Terms of Service are a separate instrument and I have not assessed them. Flagging for the
  author to decide, per brief §8.
- **The endpoint's own latency is the binding constraint, not a rate limiter.** At ~2.8 s
  average per 20-message page, a 10 000-message channel backfills in roughly 25 minutes of
  wall time without any artificial throttle. There is no need to crawl aggressively, and a
  1–2 s inter-request delay costs little relative to the server's own cost. Recommend a
  polite default of one request at a time, ~1 s gap, single-threaded per host.
- 40 requests is a small sample. It establishes that *casual* crawling is untroubled; it does
  **not** establish where a limit lives. Do not extrapolate to tens of thousands.

### Channel availability, and reading the 302

`https://t.me/s/<name>` returns **200** for a public broadcast channel with preview enabled,
and **302 → `https://t.me/<name>`** otherwise. The redirect is ambiguous on its own. Fetching
the plain page disambiguates it:

| Plain-page signature | Meaning |
|---|---|
| `tgme_page_title` present, `tgme_page_extra` = "N subscribers" | Broadcast channel, exists, previewable |
| `tgme_page_title` present, `tgme_page_extra` = "@username" | Exists but **not a previewable broadcast channel** — group/supergroup, or preview off |
| Only `tgme_page_description` = "If you have Telegram, you can contact @X right away." | **Not publicly resolvable** (private, nonexistent, or deleted) |

Observed: `swiftui_dev` → 200, "992 subscribers". `swiftmasters` → 302, title "SWIFT",
extra "@swiftmasters". `iosdevlib` → 302, contact-only signature — identical to a name I
invented (`zzqx_no_such_channel_9931`), so that signature carries no information beyond
"not publicly readable".

`tgkb doctor` should implement exactly this three-way classification per configured channel.

### Page structure

Default page = **20 messages**, oldest→newest, ending at the channel's latest post.

Per message, inside `div.tgme_widget_message_wrap`:

| Datum | Source | Notes |
|---|---|---|
| Channel + post id | `data-post="swiftui_dev/268"` | Per-channel sequence number |
| Raw channel id | `data-view` — base64 JSON | Decodes to `{"c":-1492664793,"p":268,"t":<epoch>,"h":"<hash>"}` |
| Timestamp | `<time datetime="2024-06-26T15:36:00+00:00">` | **Full ISO 8601 UTC.** Not abbreviated. |
| Author | `.tgme_widget_message_owner_name`, `.tgme_widget_message_from_author` | Channel signature author |
| Body | `.tgme_widget_message_text` | `<br/>` for newlines; emoji as `<i class="emoji"><b>👍</b></i>` |
| Edited flag | literal `edited` in `.tgme_widget_message_meta` | |
| Views | `.tgme_widget_message_views` | **Abbreviated and lossy** — "1.4K", "1.67K" |
| Permalink | `a.tgme_widget_message_date[href]` | `https://t.me/<channel>/<id>` — ready-made citation link |

`data-view.t` is the *request* time, not the post time — it is part of a signed view-tracking
token, not content. Do not mistake it for a timestamp.

### Reactions — present (this was the open question)

```html
<div class="tgme_widget_message_reactions js-message_reactions">
  <span class="tgme_reaction">
    <i class="emoji" style="background-image:url('//telegram.org/img/emoji/40/F09F918D.png')"><b>👍</b></i>3
  </span>
  <span class="tgme_reaction">…<b>🔥</b>4</span>
</div>
```

Emoji **and** count, one `span.tgme_reaction` per distinct reaction.

**In my sample every single message carried reactions — 20/20 on the default page of
`swiftui_dev`**, frequently several per message (one post had five distinct reactions). This is
not a rare decoration to be treated as optional; for this corpus it is a dense, always-present
signal, which is exactly what a ranking function wants.

Three shapes to handle, all observed in the wild:

| Shape | Markup | Extraction |
|---|---|---|
| Ordinary emoji | `<i class="emoji" style="…/40/F09F918D.png"><b>👍</b></i>3` | `<b>` text, count is the span's trailing text node |
| ZWJ sequence | `<b>❤\u200d🔥</b>2` | Same path; survives intact — do not normalise it away |
| Paid / star | `span.tgme_reaction_paid`, **no `<b>`, no sprite URL** | Detect by class; there is no emoji to read |

Two extraction caveats worth writing into the parser tests:

- The count does **not** sit immediately after `</b>` — the markup is `<b>👍</b></i>3`, so the
  `</i>` intervenes. A naive `</b>\s*(\d+)` pattern silently yields zero reactions on every
  message. Mine did, until I checked it against a post I had already read by eye; that near-miss
  is the argument for SwiftSoup over regex (brief §3) and for fixture-based parser tests.
- **Paid reactions carry no emoji at all**, so any extractor keyed on the sprite URL or the `<b>`
  node drops them. Where both are present the sprite hex (`F09F918D` = 👍) and the `<b>` text
  agreed in every case I checked, so there is no robustness advantage to the sprite — prefer the
  `<b>` text, and branch on `tgme_reaction_paid`.

Caveat on the data itself: counts are a **snapshot at crawl time** and drift afterwards. This is
brief `TD-3`, and it applies to the web source exactly as it does to TDLib.

### Link previews carry resolved OG metadata

```html
<a class="tgme_widget_message_link_preview" href="https://medium.com/@lexkraev/…">
  <div class="link_preview_site_name">Medium</div>
  <div class="link_preview_title">Настраиваем подключение к гиту</div>
  <div class="link_preview_description">Сразу оговорюсь, что данная статья…</div>
</a>
```

Site name, title, description and canonical URL, already resolved by Telegram. For a corpus
that is really a link corpus, this is the single most valuable field group on the page.

Links inside message text are trivially separable by shape:

- **External:** absolute `href`, `target="_blank" rel="noopener"`, plus an `onclick` confirm.
- **Hashtag:** relative `href="?q=%23readthis"` — which is also how I found the search endpoint.

### Pagination

- `?before=<id>` — strictly older. `?after=<id>` — strictly newer.
- **History reaches message id 1.** `?before=20` returned ids 1, 3, 4, 5, 6, 8, 10. There is
  no depth cap.
- **Post ids are non-contiguous** and **page size varies**: I observed 20, 19, 14, 7 and 5
  messages per response. **A large part of the gap is albums, not deletions** — a media group
  renders as *one* post occupying several consecutive ids (`@ios_broadcast/581` spans 581–586,
  587 spans 587–591, 977 spans 977–984, and the trailing ids never appear). **A missing id is
  therefore not evidence a post was deleted**, and anything inferring deletion from absence is
  wrong. My earlier wording listed album grouping as one cause among several and understated it.

Therefore: **page by the min/max id actually returned, never by an assumed count or stride.**
A crawler that decrements by a fixed step will silently skip posts. Terminate on an empty
result, not on a count heuristic.

### Search semantics — `?q=` (undocumented; works without login)

Composes with pagination: `?q=animation&before=180` correctly returned the 6 matches older
than 180. Probed against `swiftui_dev` (136 posts, full history):

| Query | Hits | |
|---|---|---|
| `imation` | **0** | **no substring matching** |
| `animation` / `animations` / `anim` | 15 — *identical set each time* | inflections collapse |
| `animat` / `Animatable` | **2** — *a different set* | a derivational variant maps elsewhere |
| `навигация` / `навигации` / `навигацию` / `навигац` / `НАВИГАЦИЯ` | 3 — *identical set each time* | Russian inflection handled; case-insensitive |
| `навига` | **0** | shorter-than-stem query fails |
| `swiftui animation` | 11 — a strict subset of `animation`'s 15 | multi-word is **AND** |

**The headline conclusion the brief needed is confirmed: there is no substring and no fuzzy
matching.** `imation` finds nothing, and the local index is therefore justified.

**But my first reading of *how* it matches was wrong, and the correction matters.** I initially
recorded "Latin honours an arbitrary prefix", because `anim` returned exactly the `animation`
set. Widening the sample refuted it: a true `anim*` prefix would have to be a superset of both
the `animation` set and the `Animatable` set, and it is not — `anim` returns the 15 and omits
post 262 ("Обновил либу **Animatable**"), while `animat` returns 262 and omits the 15.

So `?q=` is doing **opaque query normalisation — some stemming/lemmatisation step — not prefix
expansion**. Inflections of one lemma collapse together; a different derivational form of the
same root lands in a different bucket. I cannot reproduce the mapping from first principles and
I am not going to guess at the algorithm.

That is a *stronger* argument for owning the index than "prefix-only" was. The problem is not
that Telegram's search is limited in a predictable way we could work around — it is that its
recall is **unpredictable and uncontrollable**, and we would be unable to explain to a user why
a query missed a post we know exists.

**The genuine surprise runs the other way, though: on Russian morphology Telegram is *better*
than a naive local index.** `навигация`, `навигации` and `навигацию` all return the same three
posts. SQLite FTS5 has no Russian stemmer — `unicode61` tokenises Cyrillic correctly but does
not lemmatise — so a naive local index is *worse* here. Measured below. This is brief `TD-4`,
now quantified rather than suspected.

### Telegram's channel search caps results at ~22 — the single strongest finding

Measured on `@iosgr` (4,388 posts, 2016–2026, the author's real corpus), by paginating `?q=`
to exhaustion and comparing against the same terms counted in the crawled corpus:

| Query | Telegram surfaced | Literal matches in corpus | Missed below Telegram's lowest id |
|---|---|---|---|
| `архитектура` | **22** | **206** | 184 |
| `тестирование` | **22** | 100 | 78 |
| `анимация` | **22** | 96 | 74 |
| `навигация` | **22** | 49 | 26 |
| `верстка` | 11 | 8 | **0** |

**Every term with more than ~22 matches returns exactly 22.** Pagination is not the limit — the
crawl walks `?q=…&before=` until the endpoint returns empty, and it returns empty immediately
after the 22nd result.

My first reading of this was wrong and worth recording. Seeing `архитектура` bottom out at post
3635 in a channel that starts at post 1, I inferred an **index horizon** — that Telegram simply
does not index old history. The fuller data refutes it: the lowest id returned varies per query
(2081, 3278, 3635, 3746, 3851 — dates from 2021 to 2023) and is just wherever the 22nd
most-recent match happens to fall. Decisively, **`верстка` has only ~8 matches, returns 11, and
misses nothing below its floor.** A horizon would have truncated it too. It is a result cap,
newest-first.

**So for the corpus's most useful queries, Telegram surfaces about 11% of the matches and the
rest are unreachable.** Not ranked lower — unreachable. A ten-year archive is, through
Telegram's own search, effectively a three-year archive for any common term.

This is the justification for the whole project, and it is stronger than the brief assumed. The
brief's case was that Telegram's search is *imprecise* (no substring, no fuzzy). The real problem
is that it is *incomplete*, and silently so — it returns a plausible-looking page of results and
gives no indication that 90% of the matches were withheld.

Incidental detail worth keeping: `верстка` returned **more** than my literal `верстк` regex
found, because Telegram normalises **ё/е** (`вёрстка` ≡ `верстка`). Our tokeniser should too;
`unicode61 remove_diacritics 2` does not fold ё→е on its own.

### Local FTS5 index vs Telegram — measured, not assumed

I crawled the full 136-post history of `swiftui_dev`, indexed it into SQLite FTS5 two ways, and
compared recall against Telegram's own results on the same corpus.

| Query | Telegram `?q=` | FTS5 `unicode61` + `*` | FTS5 `trigram` |
|---|---|---|---|
| `imation` (substring) | **0** | 0 | **14** ✅ |
| `навига` (short prefix) | **0** | **3** ✅ | **3** ✅ |
| `навигация` | **3** | **2** ❌ *(misses 288)* | 2 ❌ |
| `навигац` | 3 | 3 | 3 |
| `animation` | **15** | 14 ❌ *(misses 194)* | 14 ❌ |

Read that honestly — **the local index is not strictly better**:

- **Where it wins decisively:** substring (`imation`: 0 → 14) and short prefixes (`навига`:
  0 → 3). `trigram` solves substring completely, which nothing on the Telegram side can do.
- **Where it loses:** inflected forms. `навигация*` misses post 288 because 288 says
  *навигаци**и***, and a prefix match on `навигация` cannot reach it — the `я`/`и` ending
  diverges before the prefix ends. `animation*` misses 194 for the same reason in English.

**The fix is not a better prefix, it is normalisation at index time.** Both the stored token and
the query token must be reduced to a common form. Options, in ascending cost:

1. **Index the body twice** — once `unicode61` for ranked word search, once `trigram` for
   substring — and union the results. Costs disk, no linguistics. Trigram alone would in fact
   have caught every case above except that it cannot rank well.
2. **A `FTS5WrapperTokenizer` doing light Russian suffix stripping** at index and query time.
   Cheap, no dependency, and handles the common noun/adjective cases that dominate this corpus.
   Whether a custom tokenizer is even usable from a *second reader process* is an open question
   I have flagged for the store research.
3. **Apple's `NLTagger` lemmatisation** (`.lemma`), which handles Russian, applied at index
   time to produce a parallel lemma column. Most accurate, macOS-native, no third-party
   dependency — and the same framework we would reach for in Phase 3 for `NLEmbedding`.

I recommend **(1) now and (3) in Phase 3**, and I would not build (2). Option 1 is a few lines
of schema and needs no linguistic judgement; option 3 subsumes option 2 and arrives anyway with
the semantic-search work. This belongs in `Design.md` as a decision with (2) recorded as
rejected.

Ranking sanity check: `bm25()` over the corpus put post 213 top for `навигац*` (bm25 −5.39,
17 reactions), then 268 (−3.88, 3 reactions), then 288 (−1.31, 16 reactions). Reaction counts
are dense enough to be a usable ranking signal — 76 of 136 posts carry reactions, 1026 reactions
in total across the corpus.

### Message bodies, replies, and a parser trap worth writing a test for

**Two different blocks share the class `tgme_widget_message_text`:**

| Block | Class | Content |
|---|---|---|
| Reply quote | `tgme_widget_message_text **js-message_reply_text**` | The *replied-to* message, truncated by Telegram to ~256 chars with a trailing `…` |
| Actual body | `tgme_widget_message_text **js-message_text**` | The real message |

Selecting on the shared prefix harvests the **quote** instead of the body. My first extractor
did exactly this, and the failure was near-silent: 21 of 136 posts came out ~260 characters long
ending in `…`, which looks like plausible content. I only caught it because a search comparison
disagreed with Telegram by one post, and chasing that single discrepancy led here. Post 214 came
out as 267 characters of the *previous* post's Russian text; it is actually a 1476-character
English message replying to post 213.

Fixing the selector to `.tgme_widget_message_text.js-message_text` reduced truncated bodies from
21 to **0** and additionally surfaced **30 reply relationships** (22% of the corpus) that my
first pass reported as zero — my earlier note that the sample contained no replies was wrong,
and wrong because of this same bug.

This is the concrete argument for the brief's two instincts in §3 and §8: **use SwiftSoup rather
than regex, and write fixture-based parser tests.** A brittle-parser defect here does not throw
— it quietly degrades recall in a way no runtime check would catch. Feeds `TD-1`.

**Corpus shape** (136 posts, full history of one channel, one crawl):

| Property | Count |
|---|---|
| Posts with reactions | 76 / 136 (1026 reactions total) |
| Posts with a link preview | 25 / 136 |
| Posts with hashtags | 99 / 136 |
| Replies | 30 / 136 |
| **Media posts with no caption at all (empty body)** | **18 / 136** |
| Message-id gaps | 161 of 297 ids absent (54%) |

Those 18 empty-body posts are a design input: a purely text-driven index silently drops 13% of
the corpus. They still carry a date, author, reactions and often a link preview, so they should
be indexed on those fields rather than skipped.

### Albums — one post, many ids

`tgme_widget_message_grouped` (with `_wrap` and `_layer` siblings) renders a media group as a
**single** message wrapper carrying one `data-post` id and several media. The consecutive ids the
album occupies are absent from the listing entirely.

This matters twice: it is the main explanation for the message-id gap (above), and it means the
web preview and TDLib **disagree on an album's cardinality** — one post here, *N* messages
sharing a `media_group_id` there. The ID transform is unaffected; the grain is not. Folded into
`TD-8`.

### Media and message-type markup — the probe the analyzer plan asked for

Sampled 625 posts across the four channels, plus 42 targeted fetches of text-less posts.
This closes two Unverified items and opens one extraction gap.

| Markup | Frequency | Status |
|---|---|---|
| `tgme_widget_message_forwarded_from` | **1.3%** (~96 posts) | **Newly observed** |
| `tgme_widget_message_poll` | **1.3%** (~96 posts) | **Newly observed** |
| giveaway | 0.3% | Observed, not characterised |
| document, audio, voice, sticker, location, round video | **0 / 625** | **Absent from this corpus** |

The last row is the useful negative: these are unobserved *because a link-sharing developer
channel does not contain them*, not because I failed to look. That is a different claim from the
one previously in the ledger, and it means the `whisper` branch in the analyzer plan has almost
no web-side material to work on — the audio corpus, if any, is on the TDLib side.

**Forwarded posts — the biggest previously-open gap, now closed.**

```html
<div class="tgme_widget_message_forwarded_from accent_color">Forwarded from
  <a class="tgme_widget_message_forwarded_from_name" href="https://t.me/mobiledevnews/1428">
    <span>Mobile Developer</span></a>
  (<span class="tgme_widget_message_forwarded_from_author">Алексей Гладков</span>)
```

We get **origin channel, origin post id, and the original author's name** — so a forwarded post
can be attributed to whoever actually wrote it and linked back to the original. The
"author/sender dimension is unproven for forwarded content" concern is resolved in the good
direction: attribution is *better* for forwards than for ordinary posts, because the origin is
explicit rather than inferred from the channel.

**Polls carry indexable text we are currently dropping.** A poll renders its question, its type,
its vote count and every option:

```
question: Опрос для iOS-разработчиков. Какой процент кода в вашем приложении написан на SwiftUI
type:     Anonymous Poll
votes:    595 votes
options:  0-20 / 20-40 / 40-60 / 60-80
```

This explains the 161 "empty body" posts recorded earlier — **most are polls**, and the poll
question is real, searchable content that the body-only extractor discards. A poll question is
often a better topic signal than the average post, because it states a subject explicitly.

**Consequence:** the extractor must read three more blocks — `poll_question` (+ options),
`forwarded_from` (origin channel, post id, author), and the proper `tgme_widget_message_reply`
wrapper. The reply case was already found the hard way; these two were found by looking, which
is the cheaper route and the one the ledger should have prompted sooner.

### Non-finding, recorded to stop it misleading the parser

`message_media_not_supported` occurs 165 times across my fixtures. It is **not** a data
limitation — it is the browser-compat placeholder rendered next to every `<video>` ("This
media is not supported in your browser"). Text, dates, reactions and links are all present on
those messages. Do not treat it as a signal.

---

## Unverified

- **Message-ID alignment with TDLib — arithmetic now RESOLVED; end-to-end join still open.**
  The formulas are verified from TDLib source (see `tdlib-td.md`, and I spot-checked the source
  myself rather than relying on the summary):

  ```
  chat_id    = ZERO_CHANNEL_ID - channel_id     // ZERO_CHANNEL_ID = -1000000000000 (DialogId.h:27)
  message_id = int64(post_seq) << 20            // SERVER_ID_SHIFT = 20 (MessageId.h:27, :60)
  ```

  On my real probe data: channel `1492664793` (from `data-view.c`) → `chat_id -1001492664793`;
  post `268` (from `data-post`) → `message_id 281018368`; both round-trip exactly.

  The decisive corroboration is that **TDLib's own public-link builder emits
  `t.me/<username>/<message_id >> 20>`** — that is, the number in a `t.me` URL *is* the shifted
  TDLib id, which is precisely the number `data-post` gives us. The two sources are already
  speaking the same identifier; we are not inventing a mapping.

  Two guards to encode, both from source:
  - A TDLib id is a *server* id only when `id & 0xFFFFF == 0`. Non-zero low bits mean a local,
    unsent or scheduled message, which has no web counterpart.
  - **The `-100` prefix must be applied arithmetically, never by string concatenation.**
    Monoforum channel ids reach `3000000000000` (`ChannelId.h`), producing chat ids near
    `-4000000000000` — outside the `-100…` text pattern entirely. The string trick works for
    ordinary channels and fails silently for those.

  **Still unverified:** an actual end-to-end join against a live TDLib client. Confidence is
  high but this remains a Phase 2 gate — the first TDLib probe should fetch a post from a
  channel already crawled via the web and assert the rows reconcile.

- **Can channel owners explicitly disable the preview?** I observed 302s but could not isolate
  the cause — group-vs-channel and an owner setting are confounded in my sample.
- **What fraction of the author's target channels are previewable** — needs the actual channel
  list; not yet supplied.
- **Document/file rendering.** No document posts occurred in my sampled corpus, so I have not
  seen the markup for a shared file (name, size, MIME). Audio, voice, polls, stickers,
  location, contact, invoice and giveaway markup are likewise unobserved.
- **Forwarded markup.** Replies are now covered (30 in the sample, see above), but no
  *forwarded* message occurred in my corpus, so `tgme_widget_message_forwarded_from` is
  unobserved. The "author/sender" search dimension therefore remains unproven for forwarded
  content — which in practice is how a great deal of shared material arrives, and is likely the
  single biggest remaining unknown on the web-source side.
- **HTML stability over time.** Single point in time; no basis for a churn estimate. Register
  as `TD-1` regardless — the class names are clearly internal and carry no compatibility
  contract.
- **Where the actual rate limit is.** 40 requests is a small sample (see above).
- **Whether `?q=` is stable or supported.** It is undocumented. Treat it as a convenience, and
  never as a dependency the design rests on.

---

## Consequences for the design

1. A **zero-TDLib walking skeleton is fully viable** for public channels, including reactions
   and full history. Brief §7 Phase 1 is not merely a reduced-scope milestone — it is close to
   the whole read-side product for public channels.
2. **Crawl politely by choice, not by necessity.** One request at a time, ~1 s gap. The
   server's own ~2.8 s latency dominates anyway.
3. **Page by returned ids, not by count or stride.** Non-contiguous ids and variable page
   sizes make any stride-based crawler lossy.
4. **Model reactions and link-preview metadata in the schema from day one** — both arrive free
   from the web source, and retrofitting them into an FTS5 schema later means a migration.
5. **Plan for Russian morphology from Phase 1** — dual `unicode61` + `trigram` indexing now,
   `NLTagger` lemmatisation in Phase 3. Without it the local index regresses against Telegram
   on inflected Russian, which is most of this corpus.
6. **Index media-only posts too** — 13% of posts have no text but do have date, author,
   reactions and often a link preview.
7. **Parse with SwiftSoup and pin every extractor with a fixture test.** The `js-message_text`
   trap cost me a silent 15% body-truncation rate and a 30-reply blind spot, and nothing but a
   cross-check against an independent oracle revealed it.
8. **Store `(channel_raw_id, post_seq)` as the natural key** so the TDLib source can reconcile
   into the same rows once the ID transform is confirmed empirically.
