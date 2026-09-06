# Agent skills for this project's non-Swift domains — a survey

Researched 2026-09-06, seeded from the upstreams this repo's owner already vendors
(`agent-config/README.md`): **AvdLee**, **charleswiltgen/axiom**, **anthropics/skills**,
**sosumi.ai**, **xcodebuildmcp**. Then outward via `skills.sh`, the registry behind
`npx skills find`.

---

## Verdict

**Install nothing, in either pass.** The scraping domain is well covered and almost none of it
fits; the second pass over FTS5, MCP, extraction and archives found one candidate worth
revisiting later (`wayback-archives`) and nothing worth adopting now.

Two things *are* worth taking: one skill already installed and overlooked, and two operational
practices from a skill not worth installing.

---

## What exists, and why each is rejected

| Candidate | Source | Verdict |
|---|---|---|
| `firecrawl/cli`, `scrapfly/skills`, `scrapegraphai/just-scrape` | commercial | **Reject — hosted paid services.** Scrapfly requires `SCRAPFLY_API_KEY` and ships SDKs for Python/TS/Go/Rust, **no Swift**. A hosted scraper contradicts the local-first, no-daemon design and is a dependency far larger than the problem. |
| `D4Vinci/Scrapling` | community | **Reject on principle.** Its selling point is anti-bot bypass — "Cloudflare Turnstile", stealth headless. `research/link-content-fetching.md` concluded the opposite: where a site is closed to automated fetch, index the preview and move on. Installing an evasion toolkit would contradict a decision already taken. |
| `vercel-labs/agent-browser` (795K installs) | vercel-labs | **Reject on measurement**, not principle. Headless browsing was already tested and rejected — `WKWebView` works in a plain CLI, but the domain that motivated it has a JSON API ~10× faster and cleaner. |
| `ZLStas/skills` web-scraping-python, `bcharleson/webscraping-skill` | community | **Reject as skills** — Python-bound (asyncio, BeautifulSoup, Crawl4AI); the code does not transfer to Swift. But see below: two *practices* do. |

None come from the trusted upstreams. AvdLee's nine skill repos are entirely Apple/Swift domain;
`anthropics/skills` has 19 skills and **none** touch scraping, HTTP clients, or SQLite.

## What to take

### 1. `mcp-builder` — already installed, and directly relevant to S6

From **`anthropics/skills`**, so it is inside the trusted set and needs no new install. It covers
authoring MCP servers, which is precisely `S6`. **Load it when starting `S6`** rather than
designing the tool surface from the SDK research alone.

This is the actual find: the gap was not an uncovered domain, it was a skill already present and
unused.

### 2. Two operational practices, from a skill not worth installing

`bcharleson/webscraping-skill` is Python-bound, but two items are language-agnostic and one
exposes a real defect in what I have already built:

- **Atomic checkpoint writes — write to a temp file, then rename.** My `Scripts/resolve_urls.py`
  appends and flushes, which is *not* atomic: a kill mid-write can leave a truncated JSONL line.
  It survived two session deaths by luck, not design. **Adopt in `S4`.**
- **Handle interruption and save progress**, rather than relying on append-as-you-go. `S4`'s
  crawler should checkpoint per-channel watermarks deliberately.

Its resumability advice I had already arrived at independently — the resolver skips URLs already
present, which is what let it restart cleanly at 2,250/9,770.

And one place this project is **ahead** of that skill: it explicitly does *not* address per-host
concurrency. That was the load-bearing design decision here, derived from the corpus's own
1,654-host distribution with heavy head concentration.

---

## Second pass — registry search across the other domains (2026-09-06)

`npx skills find` over FTS5, HTML extraction, MCP servers and web archives. Assessed on content,
not install count — several of these are niche topics where a low count is expected rather than
damning.

| Candidate | Installs | Verdict |
|---|---:|---|
| `github/awesome-copilot@*-mcp-server-generator` | 8–12K | **Reject — no Swift variant** (TS, Python, Rust, Go, PHP). Reputable source, but `mcp-builder` from `anthropics/skills` is already installed, language-agnostic, and inside the trusted set. |
| `rodydavis/skills@how-to-do-full-text-search-with-sqlite` | 72 | **Reject — below our current state.** Introductory: virtual tables and `MATCH`. No demonstrated coverage of tokenizers, `bm25`, external-content tables or non-English text, and Node-oriented. We already have dual `unicode61`+`trigram`, `bm25`, ё-folding and `NLTagger` lemmas, all measured. |
| `google-labs-code/stitch-skills@extract-static-html` | 7.3K | **Reject — wrong problem.** Extracting HTML from Stitch designs, not readability/boilerplate removal. |
| `existential-birds/beagle@sqlite-vec` | 174 | **Defer to Phase 3.** `sqlite-vec` is the chosen vector route; revisit if semantic search is actually built. |
| **`useosint/skills@wayback-archives`** | 599 | **The one live candidate — surface, do not install yet.** |

### `wayback-archives` — assessed, not adopted

It became relevant only because the bot-walled policy changed from "index the preview and move
on" to "try a mirror, mark its provenance". It catalogues **free** archive sources — Wayback,
`archive.today`, Google/Bing caches, country-specific archives — which is exactly the source list
that policy needs and which I would otherwise assemble by hand.

**Not installing it now**, for three reasons worth stating rather than hand-waving:

1. Its page does not confirm the part that matters — CDX API usage, rate limits, retrieval
   mechanics. The value claimed is a source *list*, and a list is cheap to verify directly.
2. 599 installs, unknown author, and an OSINT framing whose ethics posture differs from this
   project's. We attempt public mirrors and refuse evasion; OSINT tooling does not always draw
   that line in the same place, and an instruction set executes inside the agent's context.
3. The owner's practice is manual review before install. This has not had it.

**Revisit when the mirror path is actually built**, and audit the content then rather than
adopting on topical match.

## Unverified

- Install counts and rankings are `skills.sh`'s own figures, read from its leaderboard; not
  independently checked.
- I read `SKILL.md` summaries rather than auditing full skill contents. For anything that would
  actually be installed, the owner's manual-review practice should apply — these are third-party
  instruction sets that execute inside an agent's context.
