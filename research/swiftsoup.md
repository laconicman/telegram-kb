# SwiftSoup for `telegram-kb` — research notes

Date: 2026-08-23. SwiftSoup 2.13.7, Swift 6.3.3, macOS. Findings are marked **VERIFIED**
(compiled/measured here, or quoted from the repo) or listed under "Unverified / open".

## Verdict / what this means for us

1. **Adopt SwiftSoup.** Actively maintained — six releases in five months, latest **2.13.7
   on 2026-07-23**, **zero open issues**, 204 commits in the last 12 months, MIT. It is also
   effectively the only maintained pure-Swift WHATWG-conformant HTML5 parser; the libxml2
   alternatives are either dormant (Fuzi, last release 2020) or wrap a C library for no gain
   here (Kanna).

2. **Performance is a non-issue.** Measured on our own 159 KB / 20-message fixture:
   **~26 ms per page** end to end (parse + select + `text()` on every message), scaling
   x4.07 across 8 cores. A 10 000-page backfill is ~4 minutes of CPU sequentially. Telegram's
   rate limiting will dominate by orders of magnitude. Do not pick a parser on speed.

3. **The one thing that will bite us: `text()` silently drops `<br/>`.** Verified —
   `Строка один<br>Строка два` yields `Строка один Строка два`, and
   `text(trimAndNormaliseWhitespace: false)` does *not* fix it. Telegram uses `<br/>` for
   every line break inside a message body. **Write a small node walk** over `getChildNodes()`
   that maps `TextNode → getWholeText()` and `<br> → "\n"` (§2) — ~25 lines, and it also
   gives us `<a href>` URLs and `<code>` spans for free.

4. **Swift 6:** the library builds in Swift 5 language mode (no `swiftLanguageModes` in its
   manifest), but a **Swift 6-language-mode consumer target compiles clean against it** — I
   built one. `Document`/`Element`/`Elements` are deliberately **not `Sendable`** (compiler
   error, verified). That forces the right shape: parse and extract in one isolation domain,
   emit `Sendable` structs, never let a `Document` escape. Internal globals are
   `nonisolated(unsafe)` but genuinely mutex-guarded, and 8 concurrent parses returned
   correct results.

5. **Entities decode correctly**, including numeric Cyrillic refs (`&#1055;` → `П`) and
   `&mdash;`. `&nbsp;` becomes U+00A0 and is then collapsed by `text()`. Pipe extracted text
   through `.precomposedStringWithCanonicalMapping` before indexing — see the NFC note in
   `grdb-fts5.md` §7.

6. **Linux is supported and CI-tested** (Ubuntu 22.04, Swift 6.0 and 6.1). Not needed today;
   keeps a future server deployment open at zero cost.

---

## 1. Maintenance status as of 2026-08-23 — **VERIFIED** (`gh api`, today)

| Fact | Value |
|---|---|
| Latest release tag | **2.13.7**, published **2026-07-23** |
| Preceding releases | 2.13.6 (2026-07-01), 2.13.5 (2026-05-14), 2.13.4 (2026-03-26), 2.13.3 (2026-03-24), 2.13.2 (2026-03-18) |
| Last push to `master` | 2026-07-23 |
| Commits in the last 12 months | **204** |
| Commits in the last 3 months | 11 |
| Open issues (excluding PRs) | **0** |
| Open PRs | 1 |
| Stars / forks | 5 119 / 398 |
| Licence | MIT |
| Archived? | no |

Recent commit subjects (2026-06/07) show real upkeep, not drive-by merges:
`Workaround 6.4-snapshot compile crash`, `Drop malformed attributes instead of trapping on
them`, `Restore Carthage project support`.

**Read:** actively maintained, six releases in the last five months, and a **zero-issue
backlog** — unusual and a strong signal. Note the cadence tapered recently (11 commits in the
last quarter vs 204 in the year), consistent with a library that has reached maturity rather
than one being abandoned; the July release argues against abandonment.

---

## 2. API surface we need — **VERIFIED** (compiled and run, SwiftSoup 2.13.7)

I built a probe package (`swift-tools-version:6.1`, consumer target in
`.swiftLanguageMode(.v6)`) depending on `SwiftSoup from: "2.13.7"`, and ran it against the
real fixture `research/fixtures/swiftui_dev.html` (159 047 bytes, 20 messages).

```swift
import SwiftSoup

let doc  = try SwiftSoup.parse(html)                       // Document
let msgs = try doc.select("div.tgme_widget_message")       // Elements (Sequence)
let first = msgs.first()!                                  // Element?
try first.attr("data-post")                                // -> "swiftui_dev/262"
try first.select(".tgme_widget_message_text").first()?.text()
try first.select("a.tgme_widget_message_date").first()?.attr("href")
```

Probe output (unedited):

```
messages found: 20
data-post attr: swiftui_dev/262
body text (120): 🎆 Обновил либу Animatable. Добавил анимации для скелетонов (и для других view). …
absUrl test:    https://t.me/swiftui_dev/262
```

Everything we need is there and behaves: CSS selectors (class, tag, attribute, descendant),
`attr(_:)`, `text()`, emoji and Cyrillic round-trip intact. `Elements` is a `Sequence`, so
`for e in try doc.select(...)` works directly. Nearly every call is `throws` — SwiftSoup
inherits jsoup's exception style; budget for `try` everywhere.

### `<br/>` → newline: **it does NOT happen. VERIFIED, and this will bite us.**

`Element.text()` walks text nodes and normalises whitespace; `<br>` is in
SwiftSoup's *empty formatter* tag set (`Tag.swift`, `HtmlTreeBuilderState.swift`) and
contributes **nothing but a word break**. Measured:

```
input:             <div class='m'>Строка один<br>Строка два<br/>Line three</div>
text():            Строка один Строка два Line three          ← newlines LOST
text(trimAndNormaliseWhitespace: false):
                   Строка один Строка два Line three          ← still lost
html():            Строка один\n<br />Строка два\n<br />Line three
```

Note that `text(trimAndNormaliseWhitespace: false)` does **not** rescue it — that flag only
controls whitespace collapsing of existing text nodes, not `<br>` materialisation. Two
working fixes, both verified in the probe:

```swift
// A. Replace <br> with a sentinel before extracting (the jsoup-canonical trick)
for br in try el.select("br") { try br.after("\n"); try br.remove() }
let text = try el.text()

// B. Walk children yourself — also gives you control over <a>, <b>, <tg-emoji>
var parts: [String] = []
for n in el.getChildNodes() {
    if let t = n as? TextNode          { parts.append(t.getWholeText()) }
    else if let e = n as? Element,
            e.tagName() == "br"        { parts.append("\n") }
    else if let e = n as? Element      { parts.append(try e.text()) }
}
```

Both produced `Строка один\nСтрока два\nLine three`.

**Recommendation: use (B).** Telegram message bodies are not just `<br>` — they carry
`<a href>`, `<b>`, `<i>`, `<code>`, `<pre>`, `<tg-spoiler>` and `<tg-emoji>`. A hand-written
node walk is ~25 lines, gives us newline fidelity *and* the chance to keep link URLs (which
we want indexed and shown), and avoids mutating the parsed tree the way (A) does. Note (A)
mutates the document, so it must not run before anything else reads that subtree.

`TextNode.getWholeText()` is the un-normalised accessor and is what (B) relies on.

### HTML entities — **VERIFIED, decoded correctly**

```
input:  <p>A &amp; B &lt;tag&gt; &nbsp; &#1055;&#1088;&#1080; &mdash; ok</p>
text(): A & B <tag>   При — ok
```

Named entities, numeric character references (including Cyrillic `&#1055;`), and `&mdash;`
all decode. `&nbsp;` decodes to U+00A0 and is then collapsed by `text()`'s whitespace
normalisation — worth knowing, since a stray NBSP would otherwise reach the FTS index.
`Entities.swift` carries the full HTML5 named-entity table and is `Sendable`.

**Feeds directly into the GRDB notes:** apply `.precomposedStringWithCanonicalMapping` to
extracted bodies before insert, so numeric refs like `&#1080;&#774;` (и + combining breve)
normalise to precomposed `й`.

---

## 3. Performance on our real pages — **VERIFIED** (measured today)

Machine: this Mac (Apple silicon, `activeProcessorCount = 8`), Swift 6.3.3,
`swift build -c release`. Input: the real 159 KB / 20-message fixture.

```
parse only                                   7.63 ms/iter
parse + select(".tgme_widget_message_text") + text()   25.87 ms/page
select on an already-parsed doc               <0.01 ms
text() on 20 elements, doc already parsed      0.34 ms
```

The 7.63 → 25.87 gap is not selector cost — selectors are free. It is the **first** `text()`
per element; SwiftSoup caches text results (`Node.textMutationVersionToken`), so a repeated
`text()` on the same tree costs 0.34 ms while the first costs ~17 ms. Budget the honest
number: **~26 ms per page, end to end.**

### Parallel scaling

```
sequential :  5175 ms / 200 pages =>  25.87 ms/page
2 threads  :  2710 ms / 200 pages =>  13.55 ms/page   speedup x1.91
4 threads  :  1482 ms / 200 pages =>   7.41 ms/page   speedup x3.49
8 threads  :  1270 ms / 200 pages =>   6.35 ms/page   speedup x4.07
```

It parallelises cleanly (x1.91 on 2, x4.07 on 8 with 4 P + 4 E cores). SwiftSoup has two
global mutable caches — `StringBuilder.pool` and `QueryParser.cacheInstance` — but both are
guarded by an `os_unfair_lock`-backed `Mutex` (`Sources/Mutex.swift`), and the measured
scaling shows the contention is not pathological. A concurrent correctness check (8 threads
× 25 parses) returned identical, correct counts on every thread.

### What this means for the crawl

**Parsing is not the bottleneck; the network is.** At 26 ms/page single-threaded:

| Pages | Sequential | 4-way concurrent |
|---|---|---|
| 1 000 | 26 s | 7.4 s |
| 10 000 | 4.3 min | 1.2 min |
| 50 000 | 21.6 min | 6.2 min |

Even a full 50 k-page backfill is minutes of CPU. Telegram's own rate limiting will dominate
by orders of magnitude. **Do not optimise this, and do not pick a parser on speed.**

One real caution: peak memory. A parsed `Document` for a 159 KB page is a large object
graph. Parse → extract plain `String`s → **drop the Document** before fetching the next page;
never hold an array of `Document`s.

---

## 4. Swift 6 strict concurrency — **VERIFIED by compilation**

### The library itself is not in Swift 6 language mode

`Package.swift` @ master (`scinfu/SwiftSoup`, quoted in full):

```swift
// swift-tools-version:6.0
let package = Package(
    name: "SwiftSoup",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "SwiftSoup", targets: ["SwiftSoup"]),
        .executable(name: "SwiftSoupProfile", targets: ["SwiftSoupProfile"])
    ],
    targets: [ .target(name: "SwiftSoup", path: "Sources"), … ]
)
```

Note what is **absent**: no `swiftLanguageModes: [.v6]`, no `.enableUpcomingFeature`, no
`.swiftSettings` at all. With tools-version 6.0 that means SwiftSoup compiles in the **Swift
5 language mode** — its own sources are not strict-concurrency checked. (Contrast GRDB, whose
manifest ends `swiftLanguageModes: [.v6]`.)

### But it is perfectly usable from a Swift 6 target — measured

My probe's consumer target declared `.swiftLanguageMode(.v6)` and built clean:
**no errors and no SwiftSoup-attributed warnings.** Language mode is per-module, so our
Swift 6 code can depend on a Swift 5-mode library without inheriting its laxity.

### The one rule you must design around: the tree types are not `Sendable`

I asserted this by compiling `func requiresSendable<T: Sendable>(_ v: T) {}` against each
type. Result:

```
error: type 'Document' does not conform to the 'Sendable' protocol
error: type 'Elements' does not conform to the 'Sendable' protocol
error: type 'Element'  does not conform to the 'Sendable' protocol
```

**This is correct behaviour, not a defect** — they are mutable reference-type tree nodes.
It dictates our architecture, and pleasantly so:

> Parse and extract inside one isolation domain; only plain `String`/`struct` values cross
> the boundary.

```swift
// GOOD — the Document never escapes
func parsePosts(html: String) throws -> [ParsedPost] {   // ParsedPost: Sendable struct
    let doc = try SwiftSoup.parse(html)
    return try doc.select("div.tgme_widget_message").map { try extract($0) }
}
// then: await store.insert(parsePosts(html: html))
```

Attempting `Task { ... }` around a captured `Document` will not compile — which is the
compiler saving us from a real data race, since the tree is mutable and lazily caches text.

### Internal concurrency hygiene — reviewed

- `Sources/Mutex.swift`: `final class Mutex: NSLocking, @unchecked Sendable`, backed by
  `os_unfair_lock` on Darwin, with `#if os(Windows)` / Glibc branches.
- `StringBuilder.pool` — `nonisolated(unsafe) static var pool: [StringBuilder]`, but every
  access is bracketed by `poolLock.lock()` / `.unlock()` (lines 72–97). Guarded.
- `QueryParser.cacheInstance` — `nonisolated(unsafe) private static var`, with the doc
  comment *"Must always access this with the `QueryParser/cacheMutex`"*, and the public
  `QueryParser.cache` accessor does exactly that. Guarded.
- `Entities` and `Entities.EscapeMode` are properly `Sendable` (immutable static tables).
- ~65 `@unchecked Sendable` conformances, essentially all on `Evaluator` subclasses
  (immutable selector AST nodes). Defensible.

So the `nonisolated(unsafe)` markers are "we hand-roll the lock", not "we gave up". The
8-thread correctness run in §3 backs this up.

### Linux — **VERIFIED supported and CI-tested**

`.github/workflows/ubuntu.yml` builds and runs the full test suite on `ubuntu-22.04` against
official `swift:6.1` and `swift:6.0` container images, on every push and PR to `master`.
`macos.yml` does the same on `macos-15`. Sources carry `#elseif canImport(Glibc)` branches
(`Entities.swift`, `TextNode.swift`, `CharacterReader.swift`). Pure Swift, zero C
dependencies. Irrelevant to us today (macOS-only), but it means no libxml2 version-skew
surprises and it keeps a future Linux `tgkb` deployment open.

---

## 5. Alternatives, one line each — **VERIFIED metadata** (`gh api`, 2026-08-23)

- **`tid-kijyun/Kanna`** (libxml2) — 2 486 ★, latest **6.1.0 (2026-02-25)**, 13 open issues:
  the only credible libxml2-backed contender still maintained, but it wraps a C library
  (module-map friction, system-libxml2 version dependence) and its HTML parsing is
  libxml2's `HTMLparser`, which is *not* WHATWG-conformant on malformed markup.
- **`cezheng/Fuzi`** (libxml2) — 1 105 ★, last release **3.1.3 in 2020**, last push 2024-07,
  30 open issues: effectively dormant. **Rule out.**
- **`Foundation` / `NSAttributedString(data:options:[.documentType: .html])`** — WebKit-backed
  on Apple platforms, main-thread-only, catastrophically slow, and unavailable on Linux.
  Not a parser. **Rule out.**
- **Regex over the HTML** — Telegram's message markup is nested (`<a>`, `<b>`, `<tg-emoji>`
  inside `.tgme_widget_message_text`) and the pages are machine-generated but not stable.
  A parser costs 26 ms/page. **Not worth the fragility.**
- **`swift-html-parser` / hand-rolled** — no maintained WHATWG-conformant Swift alternative
  found. SwiftSoup is effectively the category.

**Verdict: SwiftSoup, no contest.** It is the only actively maintained, pure-Swift,
WHATWG-conformant HTML5 parser with a jsoup-compatible CSS-selector API, it is fast enough
by two orders of magnitude, and it has zero open issues.

---

## Unverified / open

- **`Document` memory footprint** for a 159 KB page — not measured. The advice in §3 to drop
  the `Document` before the next fetch is prudence, not a measurement.
  *Unverified — could not probe without Instruments.*
- **`SwiftSoup.parse(_:_:)`'s base-URI form and `absUrl(_:)`** — not exercised. Telegram
  emits absolute `href`s already (`https://t.me/swiftui_dev/262`, confirmed in the probe),
  so we likely never need `absUrl`.
- **`Parser.htmlParser().settings(...)` / `ParseSettings`** (case-preserving tags and
  attributes) — not exercised. Relevant only if Telegram ships mixed-case custom elements;
  `tg-emoji` and `tg-spoiler` are already lowercase.
- **Behaviour on truncated/malformed HTML** from a mid-response network failure — not
  probed. SwiftSoup is WHATWG-conformant so it will *not* throw, it will produce a partial
  tree. **We must validate at the crawler level** (e.g. require `</html>` or a plausible
  message count) rather than relying on a parse error.
- **`Cleaner`/`Whitelist`** — irrelevant to us; we extract text, we do not re-emit HTML.
- The claim that SwiftSoup builds in **Swift 5 language mode** follows from
  `swift-tools-version:6.0` + absent `swiftLanguageModes`. I verified the manifest text but
  did not inspect the emitted compiler invocation. *Reasoned from primary source, not
  directly probed.*
