# S6's done test, run — 2026-10-06

Roadmap § S6: *"Claude answers 'what has anyone shared about X' with cited `t.me` links."* S6 merged
as `5422cc9` without it ever having run. It passes, on `main` as merged.

## Setup

| | |
|---|---|
| Client | Claude Code 2.1.291, headless (`claude -p`), logged in with `claude.ai`; model `claude-fable-5-1`, the account's default |
| Server | `tgkb-mcp` from `main` at `cd1997b` (debug build), the three tools as S6 shipped them: `search_posts`, `find_links`, `get_post` |
| Store | A **copy** of the owner's corpus, 7,467 posts in four channels: `sqlite3 -readonly kb.sqlite ".backup copy"`, then migrated v5 → v6 with `tgkb sync --db copy --import-resolutions <empty file>`, which opens for writing and fetches nothing. `tgkb doctor` opens read-only and would not have migrated it. The original's sha1 was the same before and after. |
| Isolation | `--mcp-config <file> --strict-mcp-config`: the server is registered for this run only, and nothing is written to any MCP configuration. `--tools ""`: no built-in tool, so every fact in the answer came through the server. |

```bash
claude -p "What has anyone shared about app startup time?" \
  --mcp-config mcp.json --strict-mcp-config --tools "" \
  --allowedTools "mcp__tgkb__search_posts mcp__tgkb__find_links mcp__tgkb__get_post" \
  --output-format stream-json --verbose --no-session-persistence
```

The question is the done test's own, with X = app startup time (`G5` in `evals/golden-queries.md`).
It does not ask for links: whether the answer cites them is what is being tested.

## What Claude did

27 turns, about 41 seconds. Five searches, then the full record of each promising post:

| Call | Arguments |
|---|---|
| `search_posts` | `app startup time` — 2 matches |
| `search_posts` | `launch time` |
| `search_posts` | `время запуска приложения` — unprompted: the archive is mostly Russian |
| `search_posts` | the same, with the first page's `cursor` |
| `search_posts` | `pre-main dyld` — 0 matches |
| `get_post` × 21 | each hit worth reading in full |

`find_links` was never called. Each search hit carries a snippet but not the URL it shared, so
every "what was shared" fact needed a `get_post`.

## The answer — an excerpt

> The archive has a solid body of posts on app startup time, almost all from iOS channels. They
> cluster into a few themes.
>
> **Order files and linking (the most-shared technique)**
> - Egor Tolstoy in iosgr (Feb 2022) shared Emerge Tools' write-up on feeding the linker an order
>   file so only launch-critical symbols are paged in first. https://t.me/iosgr/2589
> - …
>
> **Analysis of real App Store apps**
> - iOS Dev (Sep 2022) and iosgr (Sep 2022) shared Emerge Tools' teardown of five popular apps, with
>   an average 28% possible saving. … https://t.me/iosdev/611
>
> …
>
> No Android or backend startup posts turned up. Every hit is about iOS cold launch.

Six themes in all: order files and linking, third-party SDK cost, teardowns of shipped apps,
general tips, measuring in production, and older Yandex material. **16 `t.me` links, all
distinct, and every one returned by a tool call in the same session** (checked against the
transcript; none invented):

`iosgr/2589`, `iosgr/4407`, `iosdev/1637`, `ios_broadcast/322`, `iosgr/3646`, `iosdev/1008`,
`ios_broadcast/376`, `iosdev/611`, `iosdev/478`, `ios_broadcast/97`, `iosdev/866`,
`ios_broadcast/2515`, `ios_broadcast/1012`, `iosgr/473`, `iosgr/670`, `iosgr/874` — each under
`https://t.me/`.

## What the run showed beyond the verdict

- **Claude Code hands the model the `structuredContent` JSON, and never the text block.** Every
  tool result in the transcript is the serialized structured output; the text rendering — its
  footer, its cursor line, its "no match" advice — did not reach the model at all. Seen on
  2.1.291; other clients may differ, which is why the rendering stays (Design § *MCP tool
  surface*). It also makes the JSON the size that counts: a 100-record page is 36,132 characters
  of it.
- **The stream stays open for the whole session.** 26 tool calls, all answered: the end-of-input
  behaviour (Design) does not touch an interactive client.
- **Searching in the archive's language was the model's own idea** here, after two English
  queries. The descriptions now say nothing is translated, so it no longer has to guess.

The repository holds no transcript file: it would copy other people's posts. The command above
reproduces the run against any store; `Scripts/run_mcp_eval.py` runs the synthetic questions.
