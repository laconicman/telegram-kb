# `url_canonical` — specification v1

**Status:** the co-owned seam between `telegram-kb` (Swift) and `artanl` (Python).
**Contract:** both repositories implement this spec and run `fixtures.json` in their own test
suites. **Divergence is a test failure, not a discovery.**

Bump `SPEC_VERSION` for any behavioural change and record it beside every stored value, so a
revision is a recompute over `url_raw` rather than a re-crawl.

```
SPEC_VERSION = 3
```

**v3 changes** (2026-09-06, from the first cross-implementation corpus diff — 11,778 rows,
which found one bug on each side that 42 fixtures had missed):

- **Decode only well-formed, semicolon-terminated entities.** One rule, two opposite bugs.
  Ours left `&#33;` undecoded, so a literal `#` survived to parse time, became the fragment
  delimiter, and step 8 discarded 35 characters of path — silently. Theirs decoded permissively,
  reading `&sect` inside `&amp;sectionName` and producing `§ionName`. Requiring the semicolon
  fixes both, and it is the only form two languages can implement identically: "use your
  platform's entity decoder" is by construction different everywhere.
- **Percent-decode `%XX` only where it maps to an *unreserved* character** (RFC 3986 §6.2.2.2).
  §2.2 makes decoding reserved octets a semantic change — `%2F` is not `/` — so a blanket
  unquote is wrong. Implementations must read `percentEncodedPath`, not `path`: the latter is
  already decoded and cannot tell the two apart.
- Seven fixtures added (49 total). **Changed exactly one row in the 11,773-row corpus.**

**v2 changes** (2026-09-04, after cross-implementation review):
- Adds **`effective_url`** — the join key — and the `url_resolution` relation behind it (§ below).
  `canonicalise` itself is unchanged.
- **Specifies percent-encoding of non-ASCII paths**, which was previously unstated and where the
  two implementations diverged. Swift already behaved this way; **the Python side must change**.
- Adds `time` to the explicitly-not-stripped list (documentation of existing behaviour).
- Adds seven fixtures, including two that caught real bugs.

Swift output is unchanged by v2, so no recompute is required on that side.

---

## Two steps, deliberately separated

| Step | Pure? | In the fixture contract? |
|---|---|---|
| **1. Resolve** — follow redirect hops to the final URL | No — network I/O | **No** |
| **2. Canonicalise** — normalise a URL string | **Yes** — deterministic | **Yes** |

Only step 2 is specified here, and that separation is the point: a contract that needs the
network cannot be run reliably in two CI systems. Resolution is I/O whose *output* is fed to
canonicalisation, and each side may implement it differently (or skip it) without breaking the
join.

Resolution notes, non-normative: follow every hop — `clck.ru` goes through an `sba.yandex.ru`
interstitial before its destination. Record the pre-resolution URL as `url_raw`. **`url_raw` is
never rewritten** — canonicalisation is derived.

---

## Canonicalisation algorithm

Applied in this order. Any step that cannot be performed leaves the value untouched and
continues; the function is **total** — it never throws and never returns nil.

1. **Decode HTML entities**, repeatedly until stable, maximum 3 passes. Real corpus data contains
   `&amp;amp;` (412 occurrences), which without this yields query parameters literally named
   `amp;amp;utm_medium`.
2. **Trim** leading and trailing whitespace.
3. **Parse.** If the string does not parse as an absolute URL with a host, **return it unchanged**
   and mark it non-canonical. Do not guess.
4. **Lowercase the scheme and the host.** Leave the **path untouched** — paths are
   case-sensitive, and 43 corpus URLs have mixed-case hosts.
5. **Upgrade `http` → `https`.** 642 corpus URLs. Non-`http(s)` schemes are returned unchanged
   at step 3.
6. **Drop `www.`** from the host.
7. **Drop the default port** (`:80` for http, `:443` for https).
8. **Strip the fragment.** 396 corpus URLs.
9. **Remove tracking query parameters** on the denylist below. Everything not on the list is
   **kept** — the safe direction.
10. **Sort remaining query parameters** by key, then by value, for determinism.
11. **Remove a trailing `/`** from the path, unless the path is exactly `/`, in which case the
    path becomes empty.
12. **Drop an empty query** (`?` with nothing after it).

### Entity decoding (step 1, normative)

Decode `&name;`, `&#NNN;` and `&#xHH;` **only when terminated by a semicolon**, repeatedly until
stable, max 3 passes. Never decode a `&` sequence lacking one. This must happen **before**
parsing, so that a decoded `#` cannot be mistaken for a fragment delimiter — and equally, an
undecoded `&#33;` must not be either.

### Percent-encoding (normative)

Decode `%XX` **only** when the octet is RFC 3986 *unreserved*: `ALPHA / DIGIT / "-" / "." / "_" /
"~"`. Leave every other escape byte-for-byte. Operate on the **percent-encoded** path and query,
never on the decoded forms.

### Tracking-parameter denylist

**Prefix rule:** any parameter whose name begins with `utm_` is removed. The corpus contains
`utm_refcode` (6), which an enumerated `utm_*` list missed, and one URL where `=` was
percent-encoded into the parameter *name* (`utm_campaign%3DiOS…`) — only prefix matching catches
that one.

**Exact names:**

```
ssource share startapp ref referrer referer
fbclid gclid yclid dclid msclkid twclid igshid
_openstat mc_cid mc_eid spm at_medium at_campaign
si s
```

`ssource` (152 corpus occurrences) is Habr's; `startapp` (109) is Telegram's; `si` is YouTube's
share token; `s` is X/Twitter's.

### Explicitly NOT stripped

`v`, `id`, `list`, `index`, `t`, **`time`**, `page`, `p`, `q` — and anything else absent from
the denylist.

**`time` is Apple's timestamp parameter** (`developer.apple.com/videos/play/wwdc…?time=N`, 23
corpus URLs) and is the exact same concept as YouTube's `t`. It was previously kept by accident
rather than by decision; naming it here stops someone later stripping it as obvious tracking
noise and silently breaking links into WWDC sessions — the best-structured content in the corpus.

**`v` alone occurs 416 times and is YouTube's video identity.** Stripping unknown parameters
would collapse every YouTube link in the corpus onto `youtube.com/watch`, which is why the rule
is a denylist and never an allowlist. `t`/`time` (a timestamp) and `list` (a playlist) are
tracking-adjacent in shape only. **Measured, they are identity-bearing:** six resources in the
corpus carry more than one distinct timestamp, and the spans are wide — `wwdc2024/10151` is
linked at 89s, 381s, 550s, 769s and 1180s, and one YouTube live stream at 450s, 1481s, 3848s and
6651s. Four moments across a 1h51m stream are four different recommendations, not four links to
one thing. Collapsing them is lossy in a way it never is for a blog post.

`list` is a separate case with **zero** both-ways evidence: a playlist is a different resource
from the bare video, not a view onto it.

---

## `effective_url` — the join key (v2)

**Canonicalisation never resolves, and resolution never mutates `url_canonical`.** The join key
is a third thing, derived from both.

```
url_canonical  = canonicalise(url_raw)        -- pure, total, offline, stable forever
url_resolution(url_canonical PK,
               resolved_canonical NULL,       -- NULL = unresolvable (dead link, timeout, 4xx)
               http_status, hops, resolved_at, spec_version)

effective_url(u) = COALESCE(url_resolution(u).resolved_canonical, u)
```

**Both sides join on `effective_url`.** Either may populate `url_resolution` — `telegram-kb` at
crawl time, `artanl` for URLs that never came from Telegram. Where both hold a row and they
disagree, that is a **reportable condition**, not a silent miss.

### Why the key is not simply post-resolution

An earlier proposal had `telegram-kb` resolve at ingest and store the resolved form *as*
`url_canonical`. It is wrong, for three reasons that all point the same way:

1. **Identity must not depend on I/O.** A URL that cannot be resolved would then have no
   computable key. Dead shorteners are not hypothetical — `bit.ly/3ARSuTJ` returns **404**
   (verified). Every answer for such a row poisons the key.
2. **Resolution is time-varying, so the key would be too.** A shortener's target can change, so
   two crawls of the same post produce two different keys — a silent divergence *inside* one
   store, which is strictly worse than the cross-repo divergence this contract exists to prevent.
3. **A pure key is recomputable; a resolved key is not.** The `SPEC_VERSION` guarantee — that a
   revision is a recompute over `url_raw` rather than a re-crawl — holds only while
   canonicalisation is total and offline. Folding resolution in would have broken the spec's
   own central promise.

Resolution notes, non-normative: follow every hop — `clck.ru` goes via an `sba.yandex.ru`
interstitial. Record `resolved_at`; a resolution is an observation with a timestamp, not a fact.

## Known limitations, recorded rather than hidden

- **Dropping `www.` assumes the two hosts serve the same resource.** Overwhelmingly true, not
  universally. Accepted for dedupe; revisit if a counter-example appears in the corpus.
- **Sorting query parameters assumes order is not significant.** True for every corpus host
  observed; not true in general.
- **IDN hosts become punycode**, and this is a **cross-language divergence hazard**. Swift's
  `URLComponents` converts `радом.орг` to `xn--80aiyhh.xn--c1avg` automatically; Python's
  `urlsplit` does **not**. Two such hosts appear in the corpus. Punycode is the correct canonical
  form, so the Python side must do it explicitly — there is a fixture for exactly this.
  *(An earlier draft of this spec claimed no such host existed. It was wrong, and the corpus run
  found it.)*
- **Host aliases are not resolved.** `m.youtube.com` (24), `m.habrahabr.ru` (2) and
  `m.facebook.com` (1) stay distinct from their parents, and `youtu.be` (153) stays distinct from
  `youtube.com` (432). Collapsing them needs per-host rewrite rules, which is a different kind of
  thing from normalisation; deliberately out of v1.
- **Non-ASCII path characters are percent-encoded** (UTF-8, uppercase hex) — RFC 3986 normal
  form, and what a browser puts on the wire. **This is where the two implementations actually
  diverged:** Swift's `URLComponents` encodes automatically, Python's `urlsplit` does not, so the
  Python side must `quote` the path explicitly. All 56 non-ASCII paths in the corpus already
  arrive percent-encoded, so no stored value changes — but `artanl` takes URLs from outside the
  corpus, where it would have split every such URL into two rows.
- **A trailing dot in the host is preserved** (`swift.org.` stays distinct from `swift.org`),
  which DNS says is wrong. Zero corpus occurrences; recorded rather than fixed.

---

## The contract

`fixtures.json` — an array of `{name, input, expected, note}`. `expected` is the exact output of
`canonicalise(input)`. A `null` expected means "returned unchanged and marked non-canonical".

Both sides run every case. Adding a case is cheap and encouraged; changing one requires a
`SPEC_VERSION` bump.

---

## Validated against the corpus

Run over all **11,665 unique external URLs** in the crawled corpus (`research/fixtures/*.jsonl`):

| | |
|---|---|
| Canonicalised | **11,665 / 11,665 (100%)** — zero `nil`, no crashes; the function is total |
| Unique canonical forms | 9,670 |
| **Raw forms collapsed** | **1,995 (17%)** |
| Tracking parameters surviving | **0** |
| Idempotent (`canonicalise(canonicalise(x)) == canonicalise(x)`) | **all 11,665** |

Largest legitimate collapses: 27 raw forms of `podlodka.io/ioscrew` (http/https, fragments),
14 of one `azamsharp.com` article (anchor variants), 11 of a `forums.swift.org` thread (post
anchors), 10 of a `hackernoon.com` article (including `#:~:text=` scroll-to-text fragments).

The corpus run is what found both bugs above — the enumerated `utm_*` list and the wrong IDN
claim. **Neither was caught by the 31 hand-written fixtures**, which is the argument for running
a spec against real data before trusting it.
