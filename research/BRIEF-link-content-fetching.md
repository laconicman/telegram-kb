# Research brief — fetching and indexing link content (for a Cowork/research session)

**Status: a task brief, not findings.** Paste into a fresh session, or run as-is.
Deliverable: `research/link-content-fetching.md`.

---

## Why this matters

`telegram-kb` indexes Telegram channel posts. **95% of posts carry a link** — 13,604 external
links across 1,654 domains in the real 7,406-post corpus. The corpus is really a *link* corpus,
and the post text is often just a one-line comment on someone else's article.

Telegram's own search indexes the **link preview it generated**, which is not guaranteed to hold
the target page's full content — sometimes it is only OpenGraph metadata. Fetching pages
ourselves is therefore the difference between matching Telegram and beating it, and it is the
single largest remaining source of retrieval quality.

Planned shape: fetch link content, store it in a **separate FTS table** so "search link content"
stays a query-time option rather than an ingestion-time commitment, and run **dual search** —
local index plus Telegram's live `?q=` — merging the results.

## The actual fetch profile (not hypothetical — measured from the corpus)

The top 10 domains are **40%** of all external links, and they have wildly different fetch
characteristics. **Ground every recommendation in this distribution, not in a generic crawler
design.**

| Domain | Links | Why it's interesting |
|---|---:|---|
| github.com | 1,235 | Has a real API; READMEs are the content. API vs scrape? |
| developer.apple.com | 1,176 | JS-rendered docs; also has structured alternatives |
| habr.com | 701 | Russian long-form; the main *content* payload |
| medium.com | 534 | Paywall/metered, aggressive bot handling |
| youtube.com + youtu.be | 703 | Not text at all — transcripts? titles only? |
| twitter.com | 369 | Effectively closed to unauthenticated fetch |
| boosty.to | 276 | Paywalled Russian platform |
| swift.org, forums.swift.org | 428 | Static and friendly; forums have an API |
| avanderlee / swiftwithmajid / swiftbysundell | 454 | Plain static blogs — the easy majority case |
| clck.ru, telp.cc | 225 | **URL shorteners — must be resolved before dedupe** |

Long tail: 1,654 domains. **A solution that only works for the top 10 is not a solution**, but
one that ignores their differences wastes most of its effort.

## Questions to answer

### 1. Fetching — what does the Swift ecosystem actually offer?
- Plain `URLSession` versus something browser-like. What breaks with plain `URLSession` on the
  real domains above — UA sniffing, TLS/JA3 fingerprinting, cookie walls, JS-only rendering?
- **Are there Swift packages that mimic a browser** — header-order fidelity, HTTP/2 fingerprints,
  cookie jars? Check `swift-server/async-http-client`, and honestly assess whether wrapping
  `curl-impersonate` is a real option (and what it costs in packaging — this project is already
  sensitive to binary weight; see `research/Swiftgram-TDLibFramework.md`).
- **JS-heavy pages on macOS:** `WKWebView` headless in a CLI process — does it actually work
  without an app bundle / run loop? What does it cost per page? This is the one capability a
  pure-HTTP client cannot replicate; establish whether it is available before designing around it.
- Politeness: per-host rate limiting, `robots.txt` parsing (is there a Swift parser?),
  concurrency control, retry/backoff. Conditional requests (`ETag`, `Last-Modified`) for re-fetch.
- URL shortener resolution and canonicalisation — needed *before* cross-channel dedupe, which
  already matters (479 links are shared across >1 channel).

### 2. Extraction — HTML to indexable text
- **Boilerplate removal / readability.** Indexing whole pages including nav and footers will
  wreck FTS ranking. Is there a Swift port of Readability/Trafilatura? If not, what is the
  cheapest defensible heuristic, and is a small ported implementation reasonable?
- **Parser choice**, benchmarked on real pages (fixtures exist in `research/fixtures/`):
  `scinfu/SwiftSoup` (currently chosen; ~26 ms per 159 KB page), `cezheng/Fuzi` (libxml2),
  `Kanna` (libxml2). Speed, memory, Linux support, Swift 6 concurrency, maintenance.
  **The author's own notes already flag Fuzi and Kanna** — start there, don't rediscover them.
- HTML → Markdown/plain text. `chriseidhof/HtmlToMarkdown` and the `DocumentsMiner` crawler
  (Kanna → markdown) are both in the author's notes. Are they usable, or reference-only?
- Non-HTML: PDFs (PDFKit), and YouTube — is there a legitimate transcript route, or is title +
  description the honest ceiling?

### 3. Storage and search impact
- Volume estimate: ~11,665 unique URLs × extracted text. What does that do to the SQLite FTS5
  index versus the current 3.38 MB of post bodies? Order of magnitude is enough.
- Schema: separate FTS table for link content (already the leaning) — confirm it composes with
  `bm25()` ranking and lets a query opt in or out cleanly.
- Re-fetch policy: content changes, link rot, and what to store to detect both.
- **Language:** the corpus is 90% Russian, and so is much of the linked content (habr, boosty).
  Whatever extraction is chosen must not be English-only.

### 4. Ethics, legality, robustness — state plainly, don't hand-wave
- `robots.txt` compliance and per-site ToS for the top domains. **Where fetching is clearly
  disallowed, say so and recommend not doing it** — the author decides, but give them the facts.
- Paywalled sources (medium, boosty): recommend storing metadata only, and say why.
- **Do not recommend CAPTCHA solving or anti-bot evasion.** If a site is closed to automated
  fetch, the correct answer is "index the preview and move on".
- Failure modes: what fraction of 1,654 domains will simply fail, and what the graceful
  degradation is (fall back to Telegram's preview, which we already have).

## Discipline

Explicit **Verified / Unverified** split. Verified = primary source: a repo file, official docs,
a release tag, or something you probed. **Prefer probing** — fetching a handful of real URLs from
the corpus and reporting what happened beats any amount of survey. Never infer from memory or URL
shape. If you cannot verify, write "Unverified — could not probe" and why.

Use the `deepwiki` skill for public repos where indexed; go to primary sources when not. This
host has hit unauthenticated GitHub API rate limits — fall back to `raw.githubusercontent.com`
and say so.

**Write the output file early and incrementally.** Earlier sessions on this project were killed
mid-flight by rate limits; the ones that batched their writing lost everything.

## Deliverable

`research/link-content-fetching.md`, leading with a **"Verdict / recommended stack"** section: a
concrete package choice for fetch, for parse, and for extraction, with the rejected alternatives
and the reason. Then the per-domain-tier strategy, then storage impact, then Verified/Unverified.

Be sceptical of complexity. `URLSession` + SwiftSoup + a readability heuristic covering the
static-blog majority, with graceful fallback to Telegram's existing preview, may well beat a
browser-automation stack that is fragile and heavy. **Say so if that is what the evidence shows.**
