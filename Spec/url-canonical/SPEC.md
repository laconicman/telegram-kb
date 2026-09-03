# `url_canonical` — specification v1

**Status:** the co-owned seam between `telegram-kb` (Swift) and `artanl` (Python).
**Contract:** both repositories implement this spec and run `fixtures.json` in their own test
suites. **Divergence is a test failure, not a discovery.**

Bump `SPEC_VERSION` for any behavioural change and record it beside every stored value, so a
revision is a recompute over `url_raw` rather than a re-crawl.

```
SPEC_VERSION = 1
```

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

`v`, `id`, `list`, `index`, `t`, `page`, `p`, `q` — and anything else absent from the denylist.

**`v` alone occurs 416 times and is YouTube's video identity.** Stripping unknown parameters
would collapse every YouTube link in the corpus onto `youtube.com/watch`, which is why the rule
is a denylist and never an allowlist. `t` (a timestamp) and `list` (a playlist) are arguably
tracking-adjacent, but a link to a timestamp is plausibly a different resource, so v1 keeps them.

---

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
- **No percent-encoding normalisation** beyond what the URL parser performs. The two languages'
  parsers may differ here, which is exactly what the fixtures exist to detect.

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
