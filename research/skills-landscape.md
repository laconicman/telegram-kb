# Agent skills for this project's non-Swift domains — a survey

Researched 2026-09-06, seeded from the upstreams this repo's owner already vendors
(`agent-config/README.md`): **AvdLee**, **charleswiltgen/axiom**, **anthropics/skills**,
**sosumi.ai**, **xcodebuildmcp**. Then outward via `skills.sh`, the registry behind
`npx skills find`.

---

## Verdict

**Install nothing for scraping. The domain is well covered and almost none of it fits.**

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

## Unverified

- Install counts and rankings are `skills.sh`'s own figures, read from its leaderboard; not
  independently checked.
- I read `SKILL.md` summaries rather than auditing full skill contents. For anything that would
  actually be installed, the owner's manual-review practice should apply — these are third-party
  instruction sets that execute inside an agent's context.
