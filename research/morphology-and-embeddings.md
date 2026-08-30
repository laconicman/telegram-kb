# Morphology and embeddings on Apple platforms — what actually works for Russian

Empirical, run by me 2026-08-24 on macOS 26 / Swift 6.3.3. Scripts:
`scratchpad/{lemma,embed}.swift`. Prompted by `TD-4` and by the LearnWords prior art.

---

## Verdict

**Two answers, pointing in opposite directions.**

1. **`TD-4`'s discharge plan is sound.** `NLTagger` lemmatises Russian correctly and completely —
   every inflected form of the test words collapsed to the right lemma. Phase 3 can close the
   morphology gap exactly as planned, with no third-party dependency.
2. **The brief's Phase 3 semantic plan needs adjusting — but less drastically than I first
   wrote, and my first version of this line was wrong.** `NLEmbedding` has no Russian model at
   all. But **`NLContextualEmbedding(script: .cyrillic)` does** — 512 dims, ru/bg/kk/uk, asset
   provided and shared by the OS, so it costs the package nothing. I had concluded "MLX is the
   only path"; that was a claim about one API generalised into a claim about the platform.
   There *is* a zero-packaging-cost semantic baseline for a 90%-Russian corpus.

And one trap that applies to both this project and LearnWords: **lemmatisation silently returns
nothing on a single Russian word unless you set the language explicitly.**

---

## Verified — `NLTagger` lemmatisation

With `setLanguage(.russian, …)`:

| Input | Lemma |
|---|---|
| навигация, навигации, навигацию, навигацией, навигациями | **навигация** (all five) |
| подписка, подписки, подпиской | **подписка** |
| библиотека, библиотеки | **библиотека** |

Full-sentence lemmatisation, on real text from the crawled corpus:

> Один из **блоков вопросов** … **вопросы навигации** всегда **находятся** сбоку
> → Один из **блок вопрос** … **вопрос навигация** всегда **находиться** сбоку

Nouns *and* verbs, correctly. `навигации → навигация` is precisely the case where FTS5 prefix
matching failed and Telegram's own search succeeded — so this closes the measured gap.

English control behaves as expected: `animation`/`animations` → `animation`,
`animating` → `animate`.

### The trap: no explicit language ⇒ no lemma

Without `setLanguage`, relying on auto-detection:

| Input | Lemma |
|---|---|
| навигация | **∅ — no tag returned** |
| навигации | навигация |
| навигацию | навигация |

A single word is too little text for reliable language identification, and the failure is
**silent** — the enumeration simply yields no lemma rather than raising. Note it hit the
*nominative* form, the one most likely to be typed as a query.

**Consequence for us:** set the language explicitly. Detect once per *post* (which has enough
text), store it on the row, and reuse it when lemmatising that post's tokens and any query
matched against it. Never lemmatise a bare query word with auto-detection.

**Consequence for LearnWords** — worth passing on, since this came from reading it: its
`lemmas(from:)` builds an `NSLinguisticTagger` with no language constraint and is called on
single imported words (`lemmas(from: importedString).first ?? importedString`). The `?? ` fallback
means a miss degrades to the raw string rather than crashing, so it will look like it works —
but for single non-English words it is frequently doing nothing at all. A one-line
`setLanguage`/`languageConstraint` fix, and it is exercised on exactly the input that fails.

### Unknown words return no lemma — and that is fine

`Animatable` → ∅. Library names and proper nouns have no lemma, and should be indexed verbatim.

This also explains the Telegram behaviour I measured earlier: `anim`≡`animation` formed one
bucket and `animat`≡`Animatable` a different one. A lemmatiser puts inflections of a known word
together and leaves unknown tokens alone — which is consistent with what Telegram's search does,
without my having to guess its algorithm.

---

## Verified — embeddings: I tested the wrong API first

### `NLEmbedding` — genuinely nothing for Russian

| Language | `sentenceEmbedding` | `wordEmbedding` |
|---|---|---|
| **Russian** | **nil** | **nil** |
| English | dim 512 | dim 300 |
| German | dim 640 | dim 300 |
| French | dim 640 | dim 300 |

`NLEmbedding.supportedRevisions(for: .russian)` is the **empty set** — there is nothing to
enable, no asset to download, ever.

### `NLContextualEmbedding` — a different API, and it *does* cover Russian

**This corrects what I wrote earlier.** I concluded "no on-device embedding model exists for
Russian" from `NLEmbedding` alone. That was a claim about one API stated as a claim about the
platform. `NLContextualEmbedding` is a separate, transformer-based API, and it has a **Cyrillic
model**. Verified on this machine:

```
NLContextualEmbedding(script: .cyrillic)
  dimension: 512   maximumSequenceLength: 256
  languages: bg, kk, ru, uk
  hasAvailableAssets: true       load + first embed: 0.08 s
```

The asset is **downloaded and shared by the OS**, so it costs the package nothing — no bundled
model, no MLX dependency, no binary growth. For a 90%-Russian corpus this changes Phase 3
materially: there *is* a zero-packaging-cost baseline after all.

### Two caveats — one verified, one I could not reproduce

**Verified: mean-centering materially changes ranking, so it is a real decision.** Whatever is
chosen must be applied identically at index and query time, in both processes, which means the
corpus mean is **schema**, not a local variable.

**Not reproduced: the claim that raw cosine *inverts* ranking.** The storage research reported
raw cosine scoring an unrelated pair above a same-topic pair (0.934 vs 0.809), fixed by
centering. My own probe found the opposite:

| | same-topic | unrelated | margin |
|---|---|---|---|
| **Raw cosine** | 0.609 | 0.394 | **+0.214** (correct order) |
| **Mean-centered** | -0.439 | -0.184 | **-0.255** (wrong order) |

Both rankings nonetheless placed the unrelated sentence **last** overall, so neither is inverted
in practice. **The likely reason for the disagreement is sample size** - my mean is computed over
8 sentences, far too few to be representative, and mean-centering is only meaningful against a
mean that represents the corpus. Recorded as **unresolved** rather than picking a winner: settle
it against the real 7,406-post corpus, not a toy set.

**A quality signal worth more attention than either caveat:** in my probe, *both* raw and
centered ranked `анимация переходов в UIKit` **above** `координатор для навигации между экранами`
for the query `библиотека для навигации в SwiftUI`. The embedding is picking up "transitions
between screens" over the literal topic. That is exactly what `evals/golden-queries.md` exists to
catch, and it argues for measuring lemma-only retrieval first before adding semantics.

## Borrowed from LearnWords

Its documented tiering is a good model, and transfers directly to result ranking here:

1. exact match →
2. Levenshtein edit distance + lemma comparison (`NLTagger`) →
3. semantic near-miss via `NLEmbedding` cosine

Tiers 1–2 work for Russian. **Tier 3 does not**, in LearnWords either — the same nil model
applies there, so if it supports Russian vocabulary, its semantic tier is silently inert for it.

---

## Unverified

- **Whether a Russian `NLEmbedding` exists on other OS versions or via a downloadable asset.** I
  tested this machine only. Worth one check before committing to MLX.
- **Lemmatisation throughput.** Not measured. Lemmatising every token of a large corpus at index
  time has a cost, and it is on the ingestion path.
- **Mixed-language posts.** This corpus routinely mixes Russian prose with English technical
  terms in one sentence. Per-*post* language detection may be too coarse; per-sentence or
  per-token may be needed, and I have not measured how badly the coarse version does.
- **Lemmatising the query.** Whether to lemmatise the whole query string or token-by-token
  (which reintroduces the single-word detection failure) is untested.
- LearnWords uses the older `NSLinguisticTagger`; I tested `NLTagger`. They share an
  implementation, but I did not verify the older API behaves identically.

---

## Addendum — lemmatisation measured on the real corpus

Run over the author's four channels (7,406 posts, 90% Russian-dominant, 3.38 MB of body text).

**Throughput: 4,326 posts lemmatised in 10.7 s** (~404 posts/sec, `swiftc -O`, language detected
per post then set explicitly). The whole corpus takes ~18 s. **Lemmatisation at index time is
cheap** — this closes the throughput question I had left open, and it removes any argument for
deferring it on performance grounds.

**Recall, on `@iosgr` (4,388 posts), against Telegram's own results:**

| Query | Telegram | FTS5 `unicode61` + `*` | FTS5 over lemmas |
|---|---|---|---|
| `навигация` | 22 | 11 | **36** |
| `тестирование` | 22 | 50 | **91** |
| `анимация` | 22 | 25 | **77** |
| `архитектура` | 22 | 54 | **152** |
| `многопоточность` | 22 | 15 | **20** |
| `верстка` | 11 | 5 | 5 |

**The lemma index roughly doubles recall over prefix matching** (aggregate agreement with
Telegram's returned set rises from 40% to 81%), and finds several times more than Telegram
surfaces at all — because Telegram caps at ~22 (see `web-preview-probe.md`).

Read the "vs Telegram" column carefully: it is **not** a recall ceiling, because the denominator
is capped. For `архитектура` the honest comparison is 206 literal matches in the corpus,
152 found by the lemma index, 54 by prefix, and 22 by Telegram.

**`верстка` is the instructive case, and it took three attempts to explain honestly.** Lemmas
found 5, Telegram 11. Chasing the gap produced two wrong answers before a partly-right one:

1. *"Telegram has an index horizon — it can't see old posts."* Refuted: the floor varies per
   query and `верстка` misses nothing below its own floor. It is a **result cap** (~22).
2. *"The gap is ё/е."* I checked, found **zero** `вёрстк` posts, and concluded the ё/е
   explanation was wrong. **That check was itself wrong** — it searched only message *bodies*,
   with a regex spelled `верст`, which by construction cannot match `вёрст`. I made the exact
   error I was investigating.
3. Redone properly across body **and** preview text, both spellings:

| Scope | `верстк` (е) | `вёрстк` (ё) | union |
|---|---|---|---|
| body only | 8 | 0 | 8 |
| body + preview | 8 | **1** | **9** |
| Telegram | | | **11** |

So of the three posts Telegram found that we did not:

- **Post 2081 is explained** — it carries `вёрстку` in its **link-preview description**, not its
  body. Two lessons, both actionable: **index preview titles and descriptions as first-class
  text** (they carry matchable content the body does not), and **normalise ё→е**, which
  `unicode61 remove_diacritics 2` does *not* do — verified directly: indexing `вёрстка` and
  querying `верстка` returns 0 hits. **5% of posts in this channel contain ё**, so this is worth
  roughly 200 posts here alone.
- **Posts 2576 and 2859 remain unexplained.** Neither contains any `верст`/`вёрст` in body,
  preview title, or preview description. 2576 is about *типографика* (typography); 2859 is a
  media post whose body we extract as empty. Candidate explanations, **all Unverified** — I am
  not picking one on this evidence:
  - Telegram indexes more of the linked page than the preview shows (the Habr article behind
    2081 contains `вёрстку` 12 times, so the linked-content hypothesis is live and would matter
    a lot for a corpus that is **95% links**);
  - some semantic or synonym expansion;
  - content our crawler does not capture at all (media captions, document filenames, poll text).

**The honest summary:** our index can be made to match Telegram on 9 of its 11 results with two
cheap changes (index previews, fold ё→е), and we already return several times more than it does
overall because of its ~22 cap. What the last two posts prove is that **Telegram's search reaches
content we do not extract** — which is a real open question worth settling before Phase 3 decides
how much link-target content to ingest.
