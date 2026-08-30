# Phase 0 — open questions and disagreements

Deliverable 5 of the session brief. Transient: delete once consumed.

Split into three: **what I need from you**, **where I'd choose differently from the brief**, and
**what I could not verify**.

---

## 1. What I need from you

### 1.1 The channel list — the only true blocker

I could not answer *"what fraction of my target channels are affected"* (§3) without it, and
`evals/golden-queries.md` is currently placeholders built from one public test channel rather
than questions you would actually ask. Usernames alone are enough; private ones just get marked
Phase 2. `tgkb doctor` already has the three-way classifier ready to run over them.

### 1.2 Terms of Service — your call, not mine

I established the facts and deliberately stopped there. `https://t.me/robots.txt` returns
**HTTP 404** — no robots.txt exists, so no crawl directives are expressed. That is a factual
observation about crawl directives and explicitly **not** a claim about Telegram's Terms of
Service, which is a separate instrument I have not assessed and am not qualified to rule on.
Reading public web pages is not the same as API automation, but I would not overstate the
margin. Flagging it per §8; not legal advice.

### 1.3 Does `tgkb serve` exist, or only `tgkb-mcp`?

§4 lists `serve` among the CLI subcommands; §6.1 lists `tgkb` as "login, sync, query, doctor"
and `tgkb-mcp` as the stdio executable. Having both is redundant, and it weakens the split's
best property — that the MCP binary links nothing it does not need. **My recommendation: drop
`serve` from `tgkb`.** I have currently wired `tgkb` to depend on `TelegramKBMCP` so either
choice stays open; say the word and I will cut it.

---

## 2. Where I'd choose differently

### 2.1 §7 — promote links and reactions to Phase 1 *(recommended)*

The brief puts reaction indexing in Phase 2 and link-as-first-class-entity in Phase 3. **Both
should be Phase 1**, on evidence rather than ambition:

- **Reactions arrive free from the web preview**, with exact counts — no TDLib, no auth. 76 of
  136 posts in the test channel carry them, 1,026 reactions in total. Phase 2 was the right
  guess *before* we knew the web source had them.
- **Link previews arrive with Telegram's own resolved OG metadata** — site, title, description,
  canonical URL — in HTML we are already parsing. The Phase 3 plan to "resolve title/OG
  metadata" is mostly already done for us.

The cost of deferring is not effort, it is a **schema migration**: retrofitting reactions and
link entities into an FTS5 schema later means migrating an index we will by then care about.
Cheaper now, and it makes ranking real from the first milestone. Already reflected in
`Roadmap`; say if you disagree and I will move it back.

### 2.2 §3 — the web preview should be *primary*, not merely "first-class"

You proposed elevating it and asked for verification. Everything held, and the case is stronger
than the brief assumed: reactions present, history to message id 1, OG metadata included, no
rate limiting at casual volumes, and a complete 136-post channel backfilled in ~10 seconds.

So I would go further than §3 does: **TDLib is the completeness source, not the main one.** It
earns its place for private channels, Saved Messages, exact view counts, and the ~13% of posts
with no text — not for public-channel bulk history, which is the thing that carries account
risk and is freely readable without an account at all.

### 2.3 §6.1 — one package with a trait, not a second package

You asked whether traits can gate the artifact. **Verified: yes, with a control** — trait off
means no download and the dependency reported *absent from the dependency graph*. So the TDLib
side does not need to be a separate package, and a single package keeps one repo, one version
and one test suite. Implemented; `Scripts/check-invariants.sh` enforces your hard invariant
against the dependency graph, the artifact directory, and both binaries' symbols.

### 2.4 §2 — endorsed, with a caveat that must be designed for

The split survives pressure-testing and I recommend it. One thing to design for rather than
discover: GRDB's own guidance discourages database sharing, and the live hazard is that
**`DatabaseObservation` does not detect changes made by another process** — the MCP server
cannot watch the writer and must not be built as if it could. Plus a trap I hit empirically: a
`mode=ro` open of a WAL database **fails when the directory is not writable**, because it must
still create `-shm`, and the error names the *database*, misdirecting whoever debugs it. Two
mitigations, both required: writer sets `SQLITE_FCNTL_PERSIST_WAL`, and the directory stays
writable. `TD-6`.

### 2.5 A warning the brief did not anticipate

**A naive local index is *worse* than Telegram's search on Russian morphology.** Telegram
collapses `навигация`/`навигации`/`навигацию`; SQLite has no Russian stemmer, and `навигация*`
misses a post that Telegram finds. On a majority-Russian corpus that is a real regression
against the tool being replaced. Mitigated in Phase 1 by dual `unicode61` + `trigram` indexing,
closed in Phase 3 by `NLTagger` lemmatisation. `TD-4`, and `G1` in the eval file is its
regression test. **I would not ship Phase 1 without that eval passing.**

### 2.6 Naming

`tgkb` is good — short, unambiguous, types easily. No change proposed.

---

## 3. What I could not verify

Full ledger in `Research`; the ones that would change decisions:

1. **End-to-end ID reconciliation against a live TDLib client** (`TD-8`). The arithmetic is
   verified from TDLib source and corroborated by TDLib's own link builder, but never executed.
   **This is the Phase 2 gate — do it before any backfill**, or the two sources may write
   duplicate rows instead of reconciling.
2. **Forwarded-message markup.** No forwarded post appeared in my corpus, so the author/sender
   dimension is unproven for forwarded content — which is how a lot of shared material actually
   arrives. Probably the largest remaining unknown on the web source, and your channel list
   would let me settle it in minutes.
3. **Document/file, poll, audio and voice markup** — unobserved. Only text, photo and video seen.
4. **Where Telegram's real rate limit is.** 40 requests shows casual crawling is untroubled; it
   says nothing about a full multi-channel backfill.
5. **Scale.** Every storage result comes from 60-row and 136-post samples. Nothing here speaks
   to a 100k-post index, WAL growth during a long backfill, or checkpoint starvation.
6. **Whether `?q=` is stable.** Undocumented. Used as a test oracle only, never a runtime
   dependency — but it has already earned that keep by exposing a parser bug.
7. **`FLOOD_WAIT` handling has no prior art to borrow.** Both primary comparison projects have
   *zero* rate-limit code. For a backfilling indexer this is the main loop, and it is the risk
   most likely to actually bite us.

### A process note worth recording

I found a bug in my own extractor only because I cross-checked it against an independent oracle.
Two blocks share the class `tgme_widget_message_text`; the body is `js-message_text` and the
reply quote is `js-message_reply_text`, which Telegram truncates to ~256 characters. Matching the
shared prefix silently harvested quotes for 21 of 136 posts and reported 30 replies as zero.
**Nothing threw.** I also had to retract a claim I had already written down as Verified — that
Latin queries honour arbitrary prefixes — once a wider sample refuted it.

Both failures were silent, and both were caught by disagreement with an external source rather
than by inspection. That is the argument for `TD-1`'s fixture tests and for keeping the eval file
honest from Phase 1 — in this project the characteristic failure is quietly worse answers, not
an error.
