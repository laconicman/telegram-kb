# S6 — the `mcp-builder` review, after the fact

Roadmap § S6 told the slice to **load the `mcp-builder` skill first**. The environment that built
it — its fix rounds ran in a Devin session on Linux, with no Claude client — could not load the
skill, and substituted the SDK notes and a DeepWiki pass; its done test — "Claude answers 'what has
anyone shared about X' with cited `t.me` links" — was never run.
This is the review that was skipped, done on 2026-10-06 against `main` at `cd1997b`, and what
changed because of it. The done test is in `s6-done-test.md`.

## Method

- **The skill:** `anthropic-skills:mcp-builder` (from `anthropics/skills`). Read: `SKILL.md`,
  `reference/mcp_best_practices.md`, `reference/evaluation.md`, and the quality checklists of
  `reference/node_mcp_server.md` and `reference/python_mcp_server.md`. Its harness,
  `scripts/evaluation.py`, calls the API with a key; `Scripts/run_mcp_eval.py` drives Claude Code
  instead, so the model sees the tools as a Claude client presents them.
- **The spec, read rather than recalled:** `modelcontextprotocol/modelcontextprotocol`,
  `docs/specification/2025-06-18/server/tools.mdx`, and for 2025-11-25 `server/tools.mdx`,
  `basic/lifecycle.mdx` and `changelog.mdx`.
- **The SDK:** source in `.build/checkouts/swift-sdk` (0.12.1, `a0ae212e`), and a DeepWiki pass
  indexed at that same commit
  ([conversation](https://deepwiki.com/search/for-swift-sdk-0121-and-say-if_67b43597-cb05-460a-99be-51e5862c18b8?mode=deep)).
  The two agreed on every point below.
- **A prospective DeepWiki review of the planned diff** on `laconicman/telegram-kb`
  ([conversation](https://deepwiki.com/search/prospective-review-before-i-ch_958cfa98-b62f-4c34-b0ac-ee500ecf0425?mode=deep)).
  It listed the mutants the diff would move — all six it named did go stale — warned that
  cancellation must not be folded into a tool error, and asked that the unknown-tool direction be
  checked against the spec rather than assumed. Both held.
- **Measurements on a copy of the owner's corpus** (7,467 posts, migrated v5 → v6 with `tgkb sync
  --import-resolutions <empty file>`; the original's sha1 was unchanged after. The owner migrated
  the original in place later, separately, to serve it to Claude Desktop.)

## Findings, by the skill's checklist

| Area | The skill, or the spec | `tgkb-mcp` at `cd1997b` | Outcome |
|---|---|---|---|
| Error channels | Tool errors in results. Spec 2025-11-25: input validation is a tool execution error "to enable model self-correction" (SEP-1303); an unknown tool is a protocol error | Inverted: validation threw -32602, an unknown tool returned `isError` | **Flipped**, `dad1877` — the repo owner's call |
| Naming | `{service}_{action}_{resource}`, so tools from two servers cannot be confused | `search_posts`, `find_links`, `get_post` | **Prefixed `tgkb_`**, `f97b384` — the repo owner's call over keeping them |
| Silent wrong results | — | `startup OR launch` matched 0 (`startup` 11, `launch` 58); `swiftui NOT uikit` returned 6 posts, each containing "uikit" | **Refused** with what to do instead, `d799bfd` |
| Descriptions | Narrow and exact; parameters, return shape, examples | Sound core. Missing: what is indexed, that every word must appear, that nothing is translated, that `find_links` takes a whole link. `channel` claimed records emit `@username` — they emit the bare name. `kind` and `mode` undescribed; no examples | **Fixed**, `546e70c` |
| Actionable errors | Say what to do next | Cursor errors good. An unknown argument did not list the accepted ones; a `get_post` miss gave no next step; a search with no match was a blank line and "0 result(s)" | **Fixed**, `546e70c` |
| Text vs structured | `structuredContent` + `outputSchema` + text. Spec: SHOULD also put the serialized JSON in a text block | The text is a rendering, not the JSON — and it dropped fields: `find_links` had no snippet, `get_post` no links. Claude Code 2.1.291 gives the model the JSON and never the text (done test) | Rendering **kept** for text-only clients (below); the two gaps **fixed**, `546e70c`; guidance a model needs lives in the descriptions, which every client shows |
| Response size | ~25,000-character cap, truncate with a message | Compact records. Measured: limit 20 → 4,510 chars of text + 7,133 of JSON; limit 100 → 23,024 + 36,132; `tools/list` 3,867. Claude Code's model sees the JSON | No change: the default page is 7,133 characters; a model must ask for 100 to pass the skill's figure, and the cap stops it there |
| Output schemas | Define them where possible | Declared, but every record is `{"type": "object"}` | **Deferred**, `TD-27` |
| Annotations | All four, explicit | All four: read-only, non-destructive, idempotent, closed-world | No change |
| Pagination | Respect `limit`; return a continuation and a total; default 20–50 | Opaque cursor, `total`, a drift flag; default 20, cap 100 | No change |
| `response_format` | A `json`/`markdown` parameter | None; both always | No change (below) |
| Transport, logging | stdio for local; never log to stdout | stdio; stderr logging; fd 1 `dup2`-guarded | No change |
| End of input | — | A client that closes stdin gets no answers, `initialize` included (5 of 5) | **Not drained**, recorded in Design |
| Archive scope | (The skill is silent; the evaluation asked for it on both builds) | No way to learn which channels exist: "the architecture channel" had to be guessed, and an empty answer could not be told from an uncovered topic | **Fixed**, `334ac40`: `instructions` at `initialize` name the channels and their post counts |
| Permalinks everywhere | Design: every record carries a `t.me` link | A forward's origin was `@channel/id` only | **Fixed**, `334ac40` |

## Where the design differs from the skill, on purpose

Each is argued in Design; this lists them so the next review does not re-raise them.

- **An opaque cursor, not `next_offset`.** It is an offset inside, fingerprinted to its query and
  stamped with a corpus generation, so a cursor cannot page another query and drift is reported
  (Design § *Filtering and paging*). `has_more` is the presence of `next_cursor`.
- **No `response_format`.** MCP's own `structuredContent` is the JSON channel; the text block is
  for clients that show only `content`. A parameter would duplicate what the protocol already
  separates.
- **A text rendering, not the serialized JSON, in `content`.** The spec's SHOULD is for backwards
  compatibility. A rendering is a fraction of the JSON's size — 23,024 against 36,132 characters
  for a full page — and the review's fix was to make it complete for what an answer needs,
  not to replace it.
- **No `maximum` on `limit`, no `format: date-time` on dates.** A validating client would refuse a
  value the handler clamps, and the `YYYY-MM-DD` spelling the decoder accepts (PR #5).
- **Few composable tools, not "comprehensive API coverage".** The archive's surface is search,
  links, and one post (Design § *MCP tool surface*).
- **Swift, not the TypeScript or Python the skill recommends** — decided in Design § *Two
  executables over one store* and not re-argued.

## The evaluation set

Ten questions over a synthetic corpus: `evals/tgkb-mcp/` (its README lists what each exercises).
`EvalCorpusTests` answers every one through the real server and must agree with `eval.xml`;
mutant `answersAreReachable` moves one post's date and turns it red.

Graded with `Scripts/run_mcp_eval.py` — Claude Code 2.1.291, `claude-fable-5-1`, one session per
question, only the server's tools:

| # | Needs | `main` (`cd1997b`) | review (`8f38aa7`) | + scope (`334ac40`) |
|---|---|---|---|---|
| 1 | shortener + `utm_` spellings | ✓ 8 calls | ✓ 8 | ✓ 8 |
| 2 | a poll's indexed question | ✓ 6 | ✓ 3 | ✓ 3 |
| 3 | the posts' own language | ✓ 10 | ✓ 8 | ✓ 6 |
| 4 | a forward origin | ✓ 3 | ✓ 3 | ✓ 4 |
| 5 | author names, `total` | ✓ 30 | ✓ 33 | ✓ 31 |
| 6 | reaction totals in a window | ✓ 4 | ✓ 4 | ✓ 5 |
| 7 | an empty answer | ✓ 14 | ✓ 9 | ✓ 10 |
| 8 | the substring index | ✓ 6 | ✓ 9 | ✓ 3 |
| 9 | search, then the link | ✓ 6 | ✓ 9 | ✓ 10 |
| 10 | past one page | ✓ 6 | ✓ 7 | ✓ 4 |
| | | **10/10, 93 calls** | **10/10, 93** | **10/10, 84** |

**The score does not separate the builds** — this model answers all ten either way, and single runs
of call counts are noise. What separates them is the model's own feedback, which the harness asks
for on every question:

- *On `main`*, it named what the descriptions did not say: "the English query returned zero hits
  with no hint that the archive content is in another language"; "documenting what fields are
  indexed would help"; it was unclear how far lemmatisation went.
- *On the branch*, it credited the new lines for the same moves: "the explicit 'nothing is
  translated' warning prompted me to search in both languages up front"; "every word must appear
  and … there are no OR operators made it clear I needed one call per alternative".
- *On both*, the same asks: a way to learn the archive's scope (fixed since, `334ac40`); a way to
  list a channel's posts by date without a query word (question 5 took 30+ calls of stopword
  guessing); the URLs a post shared in its search record; a link on a forward's origin (fixed,
  `334ac40`); results ordered by date.
- *And a bug:* "searching `SE-0413` … returned nothing while … snippets clearly contained
  `SE-0413`". Reproduced — the query is lemmatised as Spanish (`TD-28`).
- *With the archive's scope at `initialize`* (`334ac40`), the model cited it in six of ten answers:
  "the server instructions listing channel names made picking the architecture channel trivial";
  for the empty answer, the channels and counts "made it clear up front that a physics topic was
  unlikely". Question 5 still took 31 calls: scope is not browsing.

Ten questions a strong model clears are a regression net and a feedback channel rather than a
benchmark. Harder ones would need what the tools cannot yet do — browsing by date — and belong
with that work.

## Left out, and why

- **Output schemas for the records** — `TD-27`: a hand-written schema is a second copy of
  `Records.swift`, and it is only worth having with the drift test that keeps it true.
- **Real `OR` and `NOT`** — a grammar change in `QueryParser`, which is Track A and is shared with
  `tgkb query`; the MCP surface refuses them meanwhile (Roadmap, Phase 3).
- **Draining requests at end of input** — closing stdin is how a stdio client initiates shutdown
  (2025-11-25 `basic/lifecycle`, § Shutdown); see Design § *MCP tool surface*.
- **Browsing by date, ordering by date, URLs in search records, a forwarded flag** — what the
  evaluation asked for beyond this review's reach; each needs Track A or a record-shape decision
  (Roadmap § S6).
- **`TD-28`, the query-language bug** — in `Search.swift` and `TextNormalizer.swift`, Track A, where
  a parallel session is working; recorded with its reproduction instead.
