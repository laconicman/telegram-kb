# Fetching and indexing link content

Research notes, 2026-08-30. Answers `BRIEF-link-content-fetching.md`. Feeds the
`Design.md` OPEN question *"link-content fetching: default or opt-in?"*.

Everything numbered below was **probed on this machine today** unless marked Unverified.
Raw probe transcripts are reproducible from the commands quoted inline.

---

## Verdict / recommended stack

**`URLSession` + SwiftSoup + a ported jusText classifier, plus four per-domain shortcuts.
No browser automation, no `curl-impersonate`, no new binary dependency.**

| Layer | Choice | Why |
|---|---|---|
| Fetch | `URLSession` (`URLSessionConfiguration.ephemeral`), redirect-following, `Accept-Encoding` default, per-host serial queue | Probed: it reaches everything that is reachable at all. The four domains that refused it also refuse a Safari UA — the wall is not at the HTTP layer, so no client can climb it politely. |
| Parse | **`scinfu/SwiftSoup` — keep it** | Already chosen, already benchmarked, and the only candidate that is alive *and* Swift 6. Kanna/Fuzi are 2–4× faster, which is worth ~7 ms against a 1–3 s fetch. Irrelevant. |
| Extract | **Port jusText (~400 lines) on top of SwiftSoup** | Language-aware by construction (stopword-density classifier); the reference port ships a Russian stoplist. The corpus is 90% Russian, which kills every English-only heuristic. |
| Shortcuts | `raw.githubusercontent.com` READMEs · Apple DocC `.json` · Apple WWDC transcripts (already in HTML) · YouTube oEmbed | Each replaces a bad scrape with a cheap, stable, structured source. Together they cover ~2,000 of the 9,235 unique external URLs. |

**Rejected, with reasons:**

- **`cezheng/Fuzi`** — *dead.* Last tag 3.1.3 was cut **2020-04-17**; the only commit since is a
  2023 README typo fix. `swift-tools-version:5.0`, 30 open issues. The GitHub API's
  `pushed_at: 2024-07-12` is branch noise, not development. Do not adopt.
- **`tid-kijyun/Kanna`** — alive (6.1.0, pushed 2026-02-25) and the fastest thing measured, but
  `swift-tools-version:5.5`, a libxml2 system-library dependency, and it buys ~7 ms/page.
  Not worth churning a working parser. Reconsider only if parsing ever shows up in a profile.
- **`exyte/ReadabilityKit`** — **archived** by its owner, and depends on `Ji`, another abandoned
  libxml2 wrapper. It is the obvious-looking answer and it is a trap.
- **`nchapman/trafilatura-swift`** — a `.binaryTarget` xcframework wrapping a Rust crate,
  0 stars, one author. This project already fights TDLib's binary weight
  (`research/Swiftgram-TDLibFramework.md`); adding a second opaque binary to save 400 lines of
  Swift is the wrong trade.
- **`chriseidhof/HtmlToMarkdown`** — 9 stars, untouched since 2021-12-10, self-described
  "quick and dirty". Reference-only: read it, don't depend on it.
- **`ernesto-elsaesser/WebArchiver`** — solves *offline reading* (`.webarchive` for `WKWebView`),
  not text extraction, and it is built on the dead Fuzi. Wrong problem.
- **`yamoridon/DocumentsMiner`** — 0 stars, last touched 2019-06-09, a `main.swift` script.
  Reference-only, and its Kanna→Markdown loop is ~30 lines you'd write anyway.
- **`danny1113/html-parser-builder`** — a `@resultBuilder` DSL for *known* page shapes. Genuinely
  neat for the four per-domain shortcuts; useless for 1,817 unknown domains. Not needed.
- **`curl-impersonate` / JA3 spoofing** — would require vendoring a patched libcurl+BoringSSL.
  It exists to defeat exactly the four walls below, i.e. it is an evasion tool. Out of scope
  per the brief, and the payoff is ~10% of links.
- **Headless `WKWebView`** — *works* (probed, see §4), but costs 2–15 s/page against 1–3 s for
  HTTP, and on the one domain that motivated it (`developer.apple.com`) the JSON API is both
  faster and better. Keep it in the back pocket; do not build on it.

**Biggest risk, stated once: ranking pollution, not fetching.** Extracted link text is
**~50–80 MB against 3.38 MB of post bodies — a 15–25× volume increase** (§5). Dropped into one
FTS5 table, link content would dominate `bm25()` and every query would return the post that
merely *links* to a long article about X rather than the post *about* X. The separate-table
decision in `Design.md` is not a convenience; it is the thing that makes this safe.

---

## 1. What actually happens when you fetch — ~100 live requests

Corpus recount from `research/fixtures/*.jsonl` (7,542 posts): **17,046 URL references,
1,817 distinct hosts, 11,773 unique URLs**. Excluding `t.me` self-links: **10,903 external
references, 9,235 unique external URLs**. 529 are `http://` and need upgrading before dedupe.

### 1a. Top-domain probes — VERIFIED

Plain `curl -sSL --compressed`, default UA, one request per host. "text" = tags stripped,
`script`/`style`/`nav`/`footer` removed.

| Domain / URL probed | Status | Bytes (gz) | Naive text | Content in initial HTML? |
|---|---|---:|---:|---|
| `github.com/pointfreeco/swift-url-routing` | 200 | 49 KB | 7,619 | **Yes** — README is in `article.markdown-body` (4,014 chars); the other 3,600 chars are GitHub chrome |
| `developer.apple.com/documentation/…` | 200 | 5.9 KB | **45** | **No — pure JS shell.** Title only |
| `developer.apple.com/videos/play/wwdc2021/10022/` | 200 | 34 KB | **37,069** | **Yes — the full session transcript is in the HTML.** Biggest surprise of the probe |
| `habr.com/ru/company/deliveryclub/blog/548792/` | 200 | 36 KB | 15,377 | **Yes**, full Russian article. 301s to canonical `/companies/…/articles/…` |
| `medium.com/2-minutes-read-tip/…` | **403** | 2 KB | — | Cloudflare "Attention Required!" interstitial |
| `swiftbysundell.com/articles/…` | 200 | 6.8 KB | 13,340 | **Yes**, whole article |
| `swiftwithmajid.com/2019/09/18/…` | 200 | 6.6 KB | 9,242 | **Yes** |
| `www.avanderlee.com/swift/async-await/` | 200 | 30 KB | 20,727 | **Yes** (plus a lot of newsletter chrome) |
| `forums.swift.org/t/…/66241` | 200 | 4.2 KB | 2,665 | **Yes** — Discourse server-renders the first posts. Note it 301s to the *retitled* slug |
| `telegra.ph/Daty-reliza-iOS-11-09-07` | 200 | 2.6 KB | 847 | **Yes**, trivially |
| `twitter.com/…/status/…` | 200 (→`x.com`) | 24 KB | **945** | Only the OG card — i.e. exactly what Telegram's preview already holds. **No gain** |
| `boosty.to/ios_dev/posts/<uuid>` | 200 | 147 KB | 2,665 | **No** — that text is the blog sidebar, not the post. Paywalled/JS |
| `youtube.com/watch?v=…` | 200 | 286 KB (1.2 MB raw) | **216** | **No** — footer boilerplate only; no `shortDescription`, no `captionTracks` |
| `clck.ru/32jgcy` | 200 | — | — | **Resolves**, 2 hops, to `swiftbook.org/pages/1529?utm_…` |
| `telp.cc/AEe` | 200 | — | — | **Resolves**, 2 hops, to `developer.apple.com/support/…` |

### 1b. UA sniffing is not the problem — VERIFIED

Re-probed the three 403s with a full Safari 17.4 UA string:

```
swiftpackageindex.com/blog/…   custom UA → 403   Safari UA → 403
doordash.engineering/…         (default) → 403   Safari UA → 403
levelup.gitconnected.com/…     (default) → 403   Safari UA → 403
medium.com/…                   (default) → 403   Safari UA → 403
```

**Conclusion: the walls are TLS/behavioural (Cloudflare bot management), not header-based.**
This is the finding that kills `curl-impersonate` as a *proportionate* answer — it would work,
which is precisely why it is evasion rather than politeness. `URLSession` loses nothing to
`async-http-client` or a hand-rolled client here; there is no header-order fix to be had.

`Accept-Encoding` matters and `URLSession` sends it by default: habr is **255,745 bytes
identity vs 48,788 compressed — 5.2×**. Do not disable it.

### 1c. Long-tail sample — 40 URLs, 40 distinct hosts, weighted by link frequency — VERIFIED

Random seed 20260830, one URL per host, `Accept-Encoding` on, custom UA
`TelegramKB/0.1 (+…) URLSession`.

| Outcome | Count | Notes |
|---|---:|---|
| **200 with ≥1,000 chars of extractable text** | **24 / 40 (60%)** | habr ×2, vercel, ted, hackingwithswift, kean.blog, peterfriese, steipete, ploeh, apptractor, swiftbook, fivestars, telegra.ph, sundell, kulman, 60fps.design, swiftdifferently, alexcodes, fastlane, gmshaders, boosty (sidebar only), web.archive.org, … |
| 200 but thin / JS-only | 5 | `developer.apple.com` (→ use `.json`), Notion, an Alchemer survey, a GitHub repo page (→ use raw README), TED (610 chars = abstract) |
| **403 bot wall** | 4 | swiftpackageindex, medium, levelup.gitconnected (Medium-family), doordash.engineering |
| **404 link rot** | 3 | mathrecreation (2008 post), martinmitrevski, steipete.com→steipete.me slug change |
| Host dead / unreachable | 3 | `tech.delivery-club.ru` (gone), `tinkoff.ru` (timeout), `ozon.ru` shortener → redirect loop |
| YouTube blocked from this host | 1 | see Unverified |

`web.archive.org` returning 17 KB of `windows-1251` Russian is a reminder that **encoding
detection cannot be skipped** — `String(data:encoding:.utf8)` would have returned `nil`.

---

## 2. The four shortcuts that are worth more than any crawler improvement

### 2a. `developer.apple.com/documentation/**` → the DocC render JSON — VERIFIED

The HTML is a 45-character shell. The data behind it is a public, stable, `application/json`
endpoint:

```
https://developer.apple.com/tutorials/data/documentation/<path>.json
```

Probed on `swiftui/view/animation(_:)-1hc0p` → **200, `application/json`, 1.4 s**, with
`abstract`, `primaryContentSections`, `deprecationSummary`, `hierarchy`, `references`.
This is the same feed the docs site consumes, so it is neither scraping nor evasion — and it
gives *better* text than a rendered page would, because it has no navigation chrome at all.

Covers **408 of the 985 unique `developer.apple.com` URLs**.

### 2b. `developer.apple.com/videos/**` → transcripts are already in the HTML — VERIFIED

No JS, no API needed. `wwdc2021/10022` yields **37,069 characters** of naive text, and the
session transcript starts right after the "Resources / Related Videos" block:

> `… Search this video… ♪ Bass music playing ♪ ♪ Matt Ricketson: Hi, I'm Matt, and later on I'll be joined by Lu…`

Covers **195 more Apple URLs**, and it is the single highest-value-per-byte content in the
whole corpus: a WWDC session transcript is exactly what someone searching a Swift channel wants.

### 2c. `github.com/<o>/<r>` → `raw.githubusercontent.com/<o>/<r>/HEAD/README.md` — VERIFIED

- Scraping the repo page: **316 KB decompressed**, 7,619 chars of text of which **3,605 is
  GitHub navigation chrome** ("GitHub Copilot Write better code with AI…") that would poison FTS.
- `raw.githubusercontent.com/…/HEAD/README.md`: **200, 5,282 bytes, pure Markdown.** `HEAD`
  works — no need to guess `main` vs `master` (both probed, both 200, identical).

**Do not use the GitHub REST API.** Probed: `api.github.com/rate_limit` reports
`limit: 60, remaining: 60` unauthenticated. At 60/hour, the **905 unique `github.com` URLs**
take 15 hours. `raw.githubusercontent.com` is a plain CDN with no such limit and no robots.txt
(404 — probed).

Path shapes of those 905: 588 repo roots, 191 `/blob/`, 34 `/tree/`, 20 releases,
20 discussions, 17 issues, 14 PRs. **`/blob/` → raw file** is the same trick; `/tree/`,
`/blame/`, `/raw/` and `/archive/` are `Disallow`ed in GitHub's `robots.txt` for
`User-agent: *` (repo roots and `/blob/` are **not**).

### 2d. YouTube → oEmbed, and that is the honest ceiling — VERIFIED

611 unique YouTube URLs. The watch page is a 1.2 MB JS shell with 216 chars of footer text.
But the documented oEmbed endpoint works unauthenticated:

```
https://www.youtube.com/oembed?url=<watch-url>&format=json   → 200
{"title":"Rambler.iOS #4: Задачи синхронизации…","author_name":"Rambler&Co", …}
```

Title + channel + thumbnail. **No description, no transcript.** The timedtext/caption endpoints
are undocumented, signature-gated, and fetching them is against YouTube's ToS — so:
**title + author is the ceiling, and Telegram's preview already gives roughly that.**
Store the oEmbed title as canonical metadata (it is more reliable than the preview) and index
nothing else. 611 URLs — 6.6% of the corpus — contribute metadata only, and that is correct.

---

## 3. Extraction: HTML → indexable text

### 3a. Parser benchmark, real pages, Swift 6.3.3 release build — VERIFIED

Measured today on this machine (Apple silicon, `swift build -c release`, 10 iterations after
one warm-up). SwiftSoup 2.13.x, Fuzi 3.1.3, Kanna 6.x.

| Page | Bytes | SwiftSoup `parse+text()` | Fuzi | Kanna |
|---|---:|---:|---:|---:|
| `fixtures/swiftui_dev.html` | 159,047 | **9.8 ms** | 2.6 ms | 2.7 ms |
| `fixtures/durov.html` | 142,553 | **9.6 ms** | 3.5 ms | 3.5 ms |
| habr article | 168,082 | **11.0 ms** | 5.5 ms | 5.7 ms |
| GitHub repo page | 316,184 | **23.6 ms** | 8.9 ms | 11.4 ms |
| WWDC session page | 197,065 | **28.4 ms** | 4.3 ms | 4.4 ms |
| Sundell article | 26,926 | **2.9 ms** | 0.6 ms | 0.5 ms |

Consistent with `research/swiftsoup.md`'s ~26 ms for a 159 KB page (that figure included
`select()` + `text()` on 20 elements). **Fuzi and Kanna are 2–4× faster.**

Two caveats that flatten the gap:

1. **The raw comparison is unfair to SwiftSoup.** Fuzi's `stringValue` and Kanna's `.text`
   include `<script>` and `<style>` bodies — habr came back as *74,768* chars vs SwiftSoup's
   16,058, and the extra 58 KB is minified JavaScript. SwiftSoup's `text()` skips them for you.
   Re-benchmarked with explicit `//script | //style | //noscript` stripping, Kanna's advantage
   on habr narrows to **2.2 ms vs 9.8 ms**.
2. **7 ms is noise against the network.** Measured fetch times in §1 ranged **0.5 s – 5.6 s**.
   Parsing is 0.2–2% of the per-link budget. *Parser speed is not a decision input here.*

One real SwiftSoup wart worth recording: **DOM mutation is slow.**
`try d.select("script, style, noscript").remove()` on the 316 KB GitHub page pushed the run from
19.8 ms to **75.1 ms**. Prefer selecting the content subtree and calling `text()` on it over
removing junk from the whole document.

Maintenance, checked via the GitHub API today:

| Package | Latest tag | Last real commit | tools-version | Verdict |
|---|---|---|---|---|
| `scinfu/SwiftSoup` | 2.13.9 | pushed **2026-08-27** (3 days ago) | **6.0** | Alive, Swift 6, Linux. **Keep.** |
| `tid-kijyun/Kanna` | 6.1.0 | pushed 2026-02-25 | 5.5 | Alive; libxml2 system dep |
| `cezheng/Fuzi` | 3.1.3 | **2020-04-17** (README typo 2023) | 5.0 | **Dead** |

### 3b. Boilerplate removal — there is no maintained Swift Readability

Searched GitHub for Swift readability/trafilatura/boilerplate/article-extractor packages:

- **`exyte/ReadabilityKit`** — 835 stars, MIT, and **`archived: true`**. Depends on `Ji`,
  itself abandoned. The high star count makes it look like the answer; it is not.
- **`nchapman/trafilatura-swift`** — pushed 2026-03-10, Apache-2.0, but a
  `.binaryTarget` xcframework built from `trafilatura-rs`, 0 stars, single author. Rejected on
  binary weight and supply-chain trust (see `research/spm-traits-binarytarget.md`).
- **`mrowlinson/jusText-swift`** — pushed 2026-03-17, `swift-tools-version: 6.2`, **depends on
  SwiftSoup**, ships **101 stoplists including `Russian.txt`**. Whole implementation is
  **~28 KB of Swift including tests — ~13 KB of source across 5 files**
  (`Classifier`, `ParagraphMaker`, `Paragraph`, `Utils`, `jusText`).
  **It has no LICENSE file**, so it cannot be vendored as-is — but it demonstrates the
  algorithm ports cleanly onto the parser already in the tree.

**Recommendation: port jusText ourselves (~400 lines).** Reasons, in order:

1. **It is language-agnostic by design.** jusText classifies each paragraph by *stopword
   density* + link density + length, against a per-language stoplist. Readability's
   heuristics lean on English-ish DOM idioms; jusText leans on a word list. With the corpus at
   90% Russian and habr/boosty/apptractor among the top domains, that is the whole ballgame.
2. It sits on SwiftSoup, which is already a dependency — zero new packages.
3. Original jusText (Jan Pomikálek) is BSD-2; the algorithm and the stoplists are reusable.
4. It is small enough to test properly against the fixtures already in `research/fixtures/`.

**Cheap defensible fallback for v1**, if the port slips: `article, main, [role=main],
.post-content, .entry-content, .tm-article-body` in that order, else the `<div>` with the
highest `<p>`-text-to-markup ratio. Probed on the 40-URL sample this crude version reached
**20/40** on its own; combined with plain `<p>` concatenation it matched or beat naive
stripping on 24/40. jusText should close most of the remainder.

`text()` **drops `<br/>`** — already documented in `research/swiftsoup.md` §2 with the
`getWholeText()` workaround. The same node-walker is needed here, and matters more: article
bodies use `<br>` between stanzas of code and prose far more than Telegram messages do.

### 3c. Non-HTML

- **PDF** — `PDFKit.PDFDocument(url:).string` is on-device, free, and already linked on macOS.
  Gate on `Content-Type: application/pdf` and a size cap. Not probed; low risk, low volume.
- **YouTube** — see §2d. Metadata only, deliberately.

---

## 4. Headless `WKWebView` in a CLI — it works, and you still should not use it

**VERIFIED.** Compiled a 30-line `swiftc` executable — no app bundle, no `NSApplication`, no
`@main`, no Info.plist — that creates a `WKWebView`, loads a URL, pumps
`RunLoop.current.run(mode:before:)` until `didFinish`, then reads `document.body.innerText`.

| URL | Elapsed | innerText |
|---|---:|---:|
| `developer.apple.com/documentation/…/animation(_:)` | **14.75 s** | 3,629 chars — and mostly the docs *sidebar*, not the symbol |
| `swiftbysundell.com/articles/…` | **1.91 s** | 13,769 chars |
| Notion page from the sample | 7.98 s | 188 chars — the page is genuinely 404 (link rot, not a JS failure) |

So the capability exists on macOS in a plain CLI process. But:

- **2–15 s/page vs 0.5–5.6 s for HTTP**, and the variance is the bad kind — unbounded on
  ad-heavy pages.
- On the one domain that motivates it, `developer.apple.com`, the **DocC JSON (§2a) is 10×
  faster and yields cleaner text**. The motivating case evaporated under probing.
- It drags WebKit, a run loop, and a per-process singleton into `tgkb`, which is a CLI that
  wants to be an FTS indexer.
- Pointing it at Cloudflare-walled domains is evasion. Not probed, deliberately.

**Verdict: available, documented here so nobody re-derives it, not adopted.** If a future
domain tier genuinely needs rendering, this note is the starting point.

---

## 5. Storage and search impact

### 5a. Volume — measured, not guessed

From the 40-URL sample, the 24 pages that yielded ≥1,000 chars:

```
extracted text, UTF-8 bytes:  median 9,869   mean 12,635   p90 24,903   max 44,674
```

Against **9,235 unique external URLs**:

| Assumed fetch-to-text success | Pages | Extracted text (median-based) | (mean-based) |
|---|---:|---:|---:|
| 50% | 4,617 | 46 MB | 58 MB |
| **60%** | **5,541** | **55 MB** | **70 MB** |
| 70% | 6,464 | 64 MB | 82 MB |

**Call it 50–80 MB of text against the current 3.38 MB of post bodies — 15–25×.** With an FTS5
index roughly the size of its text at `detail=full`, the store goes from single-digit MB to
**~120–160 MB**. That is fine on disk and *not* fine in one ranking pool.

### 5b. Schema — the separate table is confirmed, and it is load-bearing

`Design.md` already leans toward a separate FTS table. **The 15–25× ratio confirms it and
raises the stakes:** with link text merged into the post index, `bm25()` term statistics are
computed over a corpus that is 95% link text, so a 200-character post about X will lose to a
5,000-word linked article that mentions X once. Two tables means two `bm25()` scorings the
query layer combines explicitly, which is what makes "search link content" a real query-time
switch rather than a slogan.

Practical shape (matches the existing GRDB/FTS5 work in `research/grdb-fts5.md`):

- `link(url_canonical PK, url_original, resolved_at, http_status, etag, last_modified, content_hash, fetch_error, tier)`
- `link_content_fts(url_canonical UNINDEXED, title, body)` — `external content` off; it is not
  mirroring a table the way post FTS does.
- Many-to-many `post_link(post_id, url_canonical)` — **479 links are already shared across more
  than one channel**, so fetch once, join many. This alone is a reason canonicalisation happens
  before fetch, not after.

Both tables need the **same tokeniser decision** as posts (`unicode61 remove_diacritics 2` +
the dual-index plan in `Design.md`), or Russian link content will be unfindable by the same
queries that find Russian posts.

### 5c. Canonicalisation and shorteners — probed

Order matters: **resolve → canonicalise → dedupe → fetch.**

- **Shorteners resolve on a `HEAD`**, cheaply: `clck.ru/32kBRU` and `telp.cc/AHx` both
  resolved in 2 hops with `curl -I -L`. 225+ shortener links in the corpus.
- **Follow every hop.** `clck.ru`'s first hop is *not* the target — it is
  `sba.yandex.ru/redirect?url=…`, a Yandex interstitial. Single-hop resolution lands on Yandex.
- **Shorteners rot.** `bit.ly/3ARSuTJ` → 404.
- Canonicalisation must strip tracking params. habr's own `robots.txt` declares
  `Clean-param: utm_source&utm_medium&utm_term&utm_campaign` — the site is *telling* you those
  params are not part of identity. Strip `utm_*`, `ssource`, `share`, and fragments.
- habr 301s `/company/<x>/blog/<n>/` → `/companies/<x>/articles/<n>/`; `forums.swift.org` 301s to
  a retitled slug; `twitter.com` → `x.com`. **Store the post-redirect URL as canonical**, keep
  the original for provenance.
- 529 corpus URLs are `http://`; upgrade to `https://` before dedupe or you double-count.

### 5d. Re-fetch policy

Conditional requests are widely supported — probed:

```
swiftbysundell.com        last-modified + cache-control: max-age=14400
habr.com                  etag: W/"3e49e-27uHjy0…"
kean.blog                 etag + last-modified + max-age=600
hackingwithswift.com      cache-control: no-store   ← no validator, must re-fetch or skip
```

Store `etag`, `last_modified`, and a `content_hash` of the *extracted text* (not the HTML —
HTML churns on every ad rotation, extracted text does not). Re-fetch on a long cadence
(quarterly is generous for a KB of archived posts), send `If-None-Match`/`If-Modified-Since`,
treat 304 as free. A 404 on re-fetch is **link rot, not a bug** — keep the last good text and
mark the row; §1c measured **3/40 ≈ 7.5% already dead**, and this corpus goes back to 2017.

---

## 6. Ethics and legality — plainly

**Where fetching is disallowed or walled, the answer is "index Telegram's preview and move on."**
The preview already carries site name, title, description and canonical URL, resolved by
Telegram (`research/web-preview-probe.md` §"Link previews carry resolved OG metadata"). That is
a real fallback, not a consolation prize.

`robots.txt`, fetched today:

| Domain | `User-agent: *` says | Action |
|---|---|---|
| `github.com` | Disallows `/*/tree/`, `/*/raw/`, `/*/blame/`, `/*/archive/`, `/*/*/commits/`, `/*/*/issues/new`. **Repo roots and `/blob/` are allowed.** | Fetch via `raw.githubusercontent.com` (no robots.txt at all — 404) |
| `developer.apple.com` | Disallows `/click/`, `/search/`, `/reference/`, some `/forums/` paths. `/documentation/`, `/videos/`, `/news/` allowed | Fetch |
| `habr.com` | Named-agent groups (Yandex, Googlebot) only; **no `User-agent: *` group.** Disallows search/fans/workers. `Clean-param` for `utm_*` | Fetch articles; honour `Clean-param` |
| `forums.swift.org` | Disallows `/search`, `/admin/`, `/my`, `.rss`; blanket-bans SEO crawlers. **`/t/…` topics allowed** | Fetch |
| `medium.com` | `*` group allows article paths — **but a second group lists `GPTBot, ClaudeBot, Bytespider, Amazonbot, Applebot-Extended, GoogleOther, meta-externalagent` with `Disallow: /`** | **Metadata only.** See below |
| `boosty.to` | Disallows `/*purchase/`, `?share=`, settings. Post paths allowed by robots — but the content is paywalled and not served | **Metadata only** |
| `x.com` | Elaborate per-agent rules; unauthenticated pages give the OG card only | **Metadata only** — no gain over the preview |
| `swiftwithmajid.com` | Sitemap line only, no rules | Fetch |
| `www.avanderlee.com` | `/wp-admin/`, `/sendy/` | Fetch |
| **`clck.ru`** | **`Disallow: /` with `Allow: /$`** | See below |
| `www.youtube.com` | *(timed out from this host)* | oEmbed only anyway |

Three judgement calls, stated so the author can overrule them:

1. **Medium (534 links) and its family (`levelup.gitconnected`, `betterprogramming.pub`, ~70
   more): store metadata only.** Two independent reasons, either sufficient: the Cloudflare
   403 (§1a/1b), and a robots.txt group that explicitly names AI crawlers with `Disallow: /`.
   Medium has stated its position; the metered paywall means much of the text is not served to
   anyone unauthenticated regardless. **Do not attempt to get past it.**
2. **Boosty (276 links): metadata only.** Paywalled by design; the 147 KB we got back was
   navigation. Fetching a paywalled body would be circumvention even if it worked.
3. **`clck.ru` (114 links) `Disallow: /` is real, and it is awkward.** A strict reading says do
   not even resolve the shortener. The pragmatic reading — which I'd take, and flag — is that
   following a redirect you were handed in a message is not *crawling* `clck.ru`; you never
   index anything from that host, you fetch one `HEAD` and index the destination (subject to
   *its* robots). **This is the one place where the recommendation is a judgement call rather
   than a rule.** The conservative alternative is to keep the shortened URL unresolved, which
   costs cross-channel dedupe.

Baseline politeness, none of it optional: identify honestly in the `User-Agent` with a contact
URL; **one in-flight request per host** with ≥1 s spacing; global concurrency ~4–8; exponential
backoff on 429/503 and honour `Retry-After`; a 25 s timeout and a body cap (~5 MB) so a
misbehaving host cannot stall the run. **No Swift `robots.txt` parser is worth depending on** —
the format is ~60 lines of RFC 9309 to implement (group selection, longest-match Allow/Disallow,
`$` and `*`), and per-host caching of the parsed file is required regardless.

### Failure budget

Extrapolating §1c to the whole corpus — **Unverified extrapolation from n=40**, but it is
measured rather than assumed:

- ~60% of unique external URLs yield ≥1,000 chars of useful text on the first plain fetch
- ~8% are dead links (404 / host gone) and will never yield anything
- ~10% are bot-walled or paywalled → preview metadata only
- ~12% are JS-only or thin, of which the **Apple and GitHub slices (≈2,000 URLs) are recoverable
  via §2's shortcuts**, pushing the realistic ceiling to **~70%**
- ~7% (YouTube) are metadata-only by nature

**Graceful degradation is already built:** every URL has a Telegram preview row. A failed fetch
writes `fetch_error` and the search path falls back to preview title+description, which is what
Telegram itself indexes. **Worst case, we match Telegram; typical case, we beat it on ~70% of
links, including every habr long-read and every WWDC transcript.**

---

## Verified

Everything above marked with a probe; the load-bearing ones restated:

1. `developer.apple.com/documentation/**` HTML is a **45-character** JS shell; the
   `tutorials/data/…json` endpoint returns **200 application/json** with full content.
2. `developer.apple.com/videos/**` HTML **contains the full session transcript** (37,069 chars
   for wwdc2021/10022) with no JS.
3. `raw.githubusercontent.com/<o>/<r>/HEAD/README.md` → **200**, 5,282 bytes, and has **no
   robots.txt (404)**. `api.github.com` unauthenticated is **60 req/hour**.
4. YouTube watch pages give **216 chars**; `youtube.com/oembed` gives **200 + title + author**.
5. **UA spoofing does not open medium / swiftpackageindex / doordash / gitconnected** —
   403 with both a custom and a Safari 17.4 UA.
6. Parser benchmark (Swift 6.3.3, release, 10 iters): SwiftSoup 9.8/9.6/11.0/23.6/28.4/2.9 ms;
   Kanna and Fuzi 2–4× faster; SwiftSoup `.remove()` on a 316 KB page costs **+55 ms**.
7. **Fuzi's last code commit is 2020-04-17**; `exyte/ReadabilityKit` is **archived**;
   `mrowlinson/jusText-swift` ships **101 stoplists incl. Russian** in ~13 KB of source and has
   **no LICENSE**.
8. **Headless `WKWebView` runs in a plain CLI process with no app bundle**, 1.9–14.8 s/page.
9. 40-URL long-tail sample: **24/40 ≥1,000 chars**, 4 bot walls, 3 link-rot 404s, 3 dead hosts.
10. Shorteners resolve on `HEAD -L`; `clck.ru` routes through `sba.yandex.ru/redirect` first.
11. habr: **255,745 bytes identity vs 48,788 gzip**.
12. Conditional-request validators present on habr (ETag), kean.blog (both), Sundell
    (Last-Modified); absent on hackingwithswift (`no-store`).
13. Corpus recount from the committed fixtures: 7,542 posts, 17,046 URL refs, 1,817 hosts,
    11,773 unique URLs, 9,235 unique external, 529 `http://`.
14. `robots.txt` contents quoted in §6 were fetched today.

## Unverified

- **The 60%/70% corpus-wide fetch-success figures are extrapolated from n=40.** The sample was
  drawn at one URL per host, which *over*-weights the long tail relative to link volume — the
  top-10 domains are 40% of links and their behaviour is known exactly from §1a, so the true
  number is probably a little better than 60%. Re-measure on n≈400 before committing.
- **YouTube reachability from this host is unreliable.** `youtube.com/robots.txt` and one
  `youtu.be` link timed out; a `watch` page succeeded on retry and oEmbed succeeded first try.
  Cannot distinguish local network conditions from YouTube rate-limiting. Immaterial — the
  recommendation is metadata-only regardless.
- **PDFKit extraction not probed.** Low volume, low risk, but unmeasured.
- **jusText port quality not measured.** The claim that it beats the CSS-selector fallback on
  Russian pages is inference from the algorithm, not a measurement. **Port it, then run both
  over the same 40 fixtures and compare** before deleting the fallback.
- **FTS5 index-size multiplier assumed ≈1× text.** Order-of-magnitude only; not measured on
  this schema.
- **`.binaryTarget` supply-chain risk of `trafilatura-swift` not audited** — rejected on
  weight and stars alone, without inspecting the Rust crate.
- **Cloudflare-walled domains were not probed with `WKWebView`.** Deliberate: that is an
  evasion test, and the brief rules it out.

## See Also

- `research/swiftsoup.md` — parser API, the `<br/>` trap, entity handling
- `research/web-preview-probe.md` — what the Telegram preview already gives us (the fallback)
- `research/grdb-fts5.md` — FTS5 tokenisers and `bm25()`
- `research/spm-traits-binarytarget.md` — why a second binary dependency is expensive here
- `Sources/TelegramKB/TelegramKB.docc/Design.md` — the OPEN question this feeds
