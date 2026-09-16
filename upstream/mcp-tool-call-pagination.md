# Upstream draft — pagination for `tools/call`

**Status: DRAFT, not posted.** Target: [modelcontextprotocol#229 — *Pagination for tool/call*](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/229),
open since 2025-03-26, five comments, still unresolved. Post only on the maintainer's say-so.

## Why we have something to add

The thread is mostly design opinion. We can bring an implementation's measurements: a read-only
MCP server over a local SQLite index where the result sets are genuinely larger than a page
(`swift` matches 3,741 of 7,444 indexed posts), and where we already hit the failure the most
recent commenter names — *"the client or agent stops early and answers from partial data."*

## What we would say

**1. The protocol's pagination is list-only, and that is a real gap — but the fix is smaller than
it looks.** `tools/list` and friends carry `cursor`/`nextCursor`; `CallToolResult` has no cursor
field, so every server invents its own convention as a tool parameter and an output field. Ours:
`cursor` in `inputSchema`, `next_cursor` in `structuredContent`. That works, but because it is
per-server, a client cannot *recognise* a paginated tool result, and so cannot decide to continue.
The cheapest useful change is not new machinery; it is a **conventional place to put the answer**,
so `nextCursor` on `CallToolResult` means the same thing everywhere.

**2. Completeness must be stated, not inferred.** This is the part we have evidence for. Our
combined search ranks word-index hits before substring-only hits. When a page filled with word
hits, the substring-only tail vanished with nothing saying so — an answer that looked complete and
was not. We now return `total` beside the page, and the CLI prints `20 of 3,741`. A truncated page
that says how much it left behind is the difference between "no results about X" and "no results
*on this page* about X", and only the server can know which.

So: `nextCursor` says *more exists*; a count says *how much*. A boolean `hasMore` would be cheaper
for servers that cannot count exactly, and we would rather the spec asked for one of the two than
for neither.

**3. Direction, and what it costs.** The maintainer of this repo suggests
`next(max:)` / `previous(max:)` rather than a single forward cursor — pagination you can walk both
ways. For a **keyset** ordering this is nearly free: our posts are ordered by `(date, message_id)`,
so a cursor is just that pair plus a direction, stable while new posts arrive, and symmetric.
For a **ranked** result it is not free: bm25 order is recomputed per query, so paging backwards
means re-running the query or caching the ranked list server-side, which reintroduces the
"server exits between calls" problem raised earlier in the thread. Our own reading of that:
an opaque cursor should be allowed to encode either, and the spec should not promise
bidirectionality it cannot guarantee for ranked tools. Say instead that a cursor is opaque, that
servers **may** accept a direction, and that clients must tolerate a server supporting only
forward.

**4. Date-stepping is a special case worth naming.** For time-ordered corpora — chat history,
logs, mail — the natural page boundary is a timestamp, not an offset, and the underlying APIs
often agree: TDLib's `getChatMessageByDate` seeks to a message by date and history is then walked
from that anchor. A date is also the one cursor a *model* can construct unaided, which matters
when the caller is an LLM. This does not need protocol support beyond opacity; it needs saying in
the guidance, so servers stop inventing offset pagination over data that has a better key.

## What we are NOT asking for

- Not automatic continuation in the client. Whether to fetch page two is the caller's judgement,
  and an agent that loops until exhaustion is a worse default than one that is told what it is
  missing.
- Not page-based pagination. Offsets over live data skip and repeat rows.

## Evidence we can cite if asked

- A 7,444-post corpus where one common query matches half of it.
- The measured cost of exactness: computing `total` with `COUNT` rather than by materialising
  every hit took a 20-row page of `swift` from 0.99 s to 0.12 s.
- The silent-truncation bug and its fix, in this repository's `Store.search` and Design notes.
