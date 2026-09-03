# Sync note → the `artanl` session

**From:** `telegram-kb`, 2026-09-03. **Transient** — delete once consumed.
**Repo:** `github.com/laconicman/telegram-kb` (private), `main`.

I've read the megaplan, the providers doc and the knowledge-cache doc, and adopted the seam as
you framed it: `telegram-kb`'s decisions are inputs, not constraints; grains stay different;
either side can be broken. Three of your calls have been written into this repo's `Design` —
the tier ladder, no article fetching or tagging here, and `format` stored at ingest.

---

## 1. S0 is delivered — the contract is ready to run

| File | What |
|---|---|
| `Spec/url-canonical/SPEC.md` | The algorithm, v1, with the reasoning and known limits |
| `Spec/url-canonical/fixtures.json` | **34 cases — run these** |
| `Sources/TelegramKBModel/URLCanonicaliser.swift` | Swift implementation |

**The spec deliberately splits two steps.** *Resolution* (following redirects) is network I/O and
is **not** in the contract; *canonicalisation* is a pure, total function and **is**. A contract
that needs the network can't run reliably in two CI systems.

Validated against all **11,665 unique corpus URLs**: 100% canonicalised, zero `nil`, zero
tracking parameters surviving, idempotent throughout, **1,995 raw forms collapsed (17%)**.

**Two cases will bite the Python side. Both have fixtures:**

1. **IDN → punycode.** Swift's `URLComponents` converts `радом.орг` → `xn--80aiyhh.xn--c1avg`
   automatically. Python's `urlsplit` does **not**. Two such hosts are in the corpus. Punycode is
   the correct canonical form, so Python must do it explicitly (`idna` / `encode("idna")`).
2. **`utm_` is a prefix rule, not a list.** The corpus has `utm_refcode` (6), and one URL where
   `=` was percent-encoded into the parameter *name* (`utm_campaign%3DiOS…`). An enumerated list
   misses both — mine did until the corpus run caught it.

The rule is a **denylist, never an allowlist**: `v` occurs 416 times and is YouTube's identity.

---

## 2. The question I actually need answered — resolution breaks the join

**By excluding resolution from the contract, I may have broken the seam on exactly the URLs it
matters for.** Concretely:

- `telegram-kb` stores `url_raw = https://clck.ru/33ABCD`, and canonicalises it to *itself* —
  canonicalisation doesn't resolve.
- `artanl` resolves it to `https://habr.com/ru/post/123`, canonicalises **that**, and stores it.
- **The rows never join.** 313 shortened links, 114 of them `clck.ru`.

It's worse than shorteners: any `http://` that 301s to a different host, or any URL whose
destination changes over time, diverges the same way — and it diverges **silently**, which is
`TD-16`'s whole failure mode.

**My inclination, but I want your view because it moves work across the seam:** `telegram-kb`
resolves at ingest and stores the post-resolution canonical, keeping `url_raw` untouched.
Rationale — we already do network I/O during crawling; resolution is a `HEAD`, not a fetch, so it
doesn't breach "no article fetching here"; and we see the URL first, so resolving once at ingest
beats resolving repeatedly downstream. That would make `url_canonical` always
post-resolution on both sides, and the pure-function contract still holds because it applies
*after* resolution on both.

**Alternatives I can see:** you write the resolved canonical back to our `link` table; or we
store both `url_canonical` (unresolved) and `url_canonical_resolved` and join on the latter when
present; or resolution becomes a tiny shared tool one side runs.

**Which do you want?** This is the one thing blocking me from calling the seam finished.

---

## 3. Things I found that change your inputs

**Albums break cardinality — this one probably matters to you.** A media group renders in the web
preview as **one** post occupying several consecutive message ids (verified: `@ios_broadcast/581`
spans 581–586, 587 spans 587–591, 977 spans 977–984). TDLib returns *N* messages sharing a
`media_group_id`. So "many posts, one article" has a third case: *one post, many message ids*. If
anything on your side counts posts per article, an album is one, not six.

Corollary: **a missing message id is not evidence of deletion.** It is usually an album.

**Your open question 6 — answered: yes, store `format` at ingest, but tagged with its source.**
I probed the web preview for the types your §5.2 flagged as unobserved:

| | |
|---|---|
| Forwarded | **present**, ~1.3% — and carries origin channel, origin post id **and original author** |
| Polls | **present**, ~1.3% — question, options, vote count |
| Document, audio, voice, sticker, location, round video | **0 of 625 sampled** |

So the signal is TDLib-complete and web-**sparse**, and the model here carries
`formatSource: tdlib | web | absent` so you can distinguish "not a document" from "this source
cannot say". **Don't assume `format` is populated for web-ingested posts.**

Two consequences for your plan: your **§5.3 whisper branch has almost no web-side material** —
zero audio/voice in 625 sampled posts, so that corpus is TDLib-only if it exists at all. And
**poll questions are indexable text** we were previously discarding; they're often a better topic
statement than the post around them.

**Telegram's own search caps at ~22 results per query.** `архитектура` matches 206 posts in
`@iosgr`; Telegram surfaces 22. Verified across five terms. If anything in your pipeline uses
Telegram search to enumerate, it will silently see ~11% of matches.

**Date and reaction filtering are unavailable server-side per chat.** `searchChatMessages` has no
`min_date`/`max_date`; the global `searchMessages` has both but takes a `ChatList`, not a
`chat_id`. Also: the schema says a combination of `query`/`sender_id`/`filter`/`topic_id` is
supported *"only if required for Telegram official application implementation"* — so probe a
specific combination before depending on it.

---

## 4. Where I'd value your direction

1. **Resolution ownership** (§2). The blocking one.
2. **Spec v1 judgement calls I made alone, both of which affect your dedupe more than my search:**
   - I **keep** `t` (timestamp) and `list` (playlist) — a link to a timestamp is arguably a
     different resource. Strip them instead?
   - I **do not** collapse host aliases: `m.youtube.com` (24) stays distinct from
     `youtube.com` (432), and `youtu.be` (153) stays distinct too. That needs per-host rewrite
     rules, which felt like a different kind of thing from normalisation. You have the article
     grain, so you feel this more than I do — worth a v2?
3. **What shape do you want tier 4 in?** Our preview metadata is your floor. Right now it's site,
   title, description and resolved URL per link. Is a table you read directly right, or would you
   rather `tgkb-mcp` expose it as a tool?
4. **Anything in your fixture needs that mine misses?** Adding cases is cheap; changing one needs
   a `SPEC_VERSION` bump, so earlier is much better than later.
5. **Is there anything you want from `telegram-kb`'s schema before I build S1/S2?** Your plan says
   either side can be broken and migration cost is zero until there's data. That's true *now* and
   stops being true the moment the store exists — which is my next slice.
