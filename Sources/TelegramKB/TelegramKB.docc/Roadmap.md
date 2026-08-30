# Roadmap

Rationale lives in <doc:Design>. This is only what, and in what order.

## Now — Phase 1: walking skeleton, zero TDLib

Public channels only, via the `t.me/s/` web preview. No auth, no TDLib, no ban exposure.

- `TelegramKBModel` — `Channel`, `Post`, `LinkRef`, `Author`, `Reaction`. No I/O.
- `TelegramKBStore` — GRDB schema, migrations, dual FTS5 index (`unicode61` + `trigram`).
- `TelegramKBIngest` — `IngestionSource` protocol + `WebPreviewSource` (SwiftSoup).
- `tgkb sync` / `tgkb query` / `tgkb doctor`. **No `serve`** — see <doc:Design>.
- `tgkb-mcp` exposing `search_posts` and `find_links`.
- `evals/golden-queries.md` starts here and grows every phase.

**Exit criterion:** ask Claude "what has anyone shared about X" and get cited `t.me` links back.

Reactions and link entities stay in Phases 2 and 3 as originally planned. The web preview does
supply both for free, and the parser extracts them from day one — but *indexing* them is
deferred deliberately, to keep Phase 1 small. The cost is a later schema migration, accepted
knowingly.

## Next — Phase 2: TDLib ingestion

Private and colleague channels, Saved Messages.

- `tgkb login`, session in `~/Library/Application Support/`, secrets in Keychain.
- Throttled, resumable backfill with per-channel watermarks.
- **First task, before anything else: prove the ID reconciliation end-to-end** against a channel
  already crawled from the web. See <doc:Design> § *Two sources, one row*.
- Handle edits and deletes; treat `updateDeleteMessages(from_cache: true)` as *not* a deletion.
- Reaction counts via `updateMessageInteractionInfo` — **not** `updateMessageReaction`, which is
  bots-only.

## Next — Phase 3: retrieval quality

- Promote **links** to first-class indexed entities: URL, resolved title/description, every post
  that shared it, aggregate reactions. The corpus is really a link corpus — **95% of posts carry
  a link**, 11,665 unique across 16,789 sharings.
- **Per-domain shortcuts before any general crawler** — they are worth more. Apple docs via
  `tutorials/data/….json`, WWDC transcripts straight from HTML, GitHub READMEs via
  `raw.githubusercontent.com`, YouTube via oEmbed. ~2,100 of 13,604 links, and they convert
  Apple's documentation from unusable to the best-structured content in the corpus.
- **Fetch and index link *content*, not just its preview.** Telegram indexes the preview it
  generated, which is not guaranteed to hold the target page in full — sometimes only OpenGraph.
  Fetching the page ourselves is what makes us strictly better than Telegram on a link corpus
  rather than merely equal. Exposed as a **dedicated query option**; whether it is on by default
  is an open question (see <doc:Design>).
- **Dual search — live and cached, run together.** Query the local index *and* Telegram's own
  `?q=` concurrently, then merge. The two have complementary failure modes: ours has full recall
  but a crawl-time snapshot; theirs is current but caps at ~22 results. Neither alone is right.
- Cross-channel dedupe of the same link.
- Reaction count as a ranking signal.
- `NLTagger` lemmatisation for Russian morphology — **verified to work**; see `TD-4` for the
  explicit-language trap that must be encoded with it.
- Retrieval quality measured on lemmas **first**. Semantic search is a separate, later question —
  decide it with evidence from the golden queries, not in advance. `NLContextualEmbedding`
  (Cyrillic, 512 dims) is a free baseline; the open problems are mean-centering and the fact that
  Cyrillic and Latin are separate vector spaces (`TD-9`).
- Optional `search_live` tool via TDLib.

## Later — Phase 4: write operations

Send, forward-to-Saved-with-tag, drafts. Explicit MCP tool annotations and human confirmation
on every one. Note that `readOnlyHint` defaults to *false* and `destructiveHint` to *true* when
omitted, so every read tool must set them explicitly long before this phase.

## See Also

- <doc:Design>
- <doc:TechDebt>
- <doc:Research>
