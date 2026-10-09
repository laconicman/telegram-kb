# tgkb-mcp evaluation

The evaluation the `mcp-builder` skill prescribes for an MCP server: ten questions a model should
answer using **only** `tgkb_search_posts`, `tgkb_find_links` and `tgkb_get_post`, each with one
answer checked by exact string comparison. It measures the tool surface — names, descriptions,
schemas, what the results carry — not retrieval quality, which `../golden-queries.md` measures on
the real corpus.

| File | What it is |
|---|---|
| `eval.xml` | The questions and answers, in the skill's `<evaluation><qa_pair>` format. |
| `corpus.json` | The archive they are asked of: **synthetic** — invented channels (`*_demo`), people and posts, every link on a reserved `example` domain. Real messages never go in this repository. |

**The answers are proved, not asserted.** `Tests/TelegramKBMCPTests/EvalCorpusTests.swift` seeds a
store from `corpus.json`, answers every question through the real server by a route a model could
take, and fails if any answer differs from `eval.xml`. It also checks that the corpus stays
synthetic. Mutant `answersAreReachable` moves one post's date and must turn it red.

**What each question exercises:**

| # | Needs |
|---|---|
| 1 | `tgkb_find_links` across a shortener resolution and a `utm_` spelling of one article |
| 2 | a poll, which has no body: its question is what is indexed; `kind` and date filters |
| 3 | searching in the posts' language — an English-only search finds a later post |
| 4 | the forward origin, which only `tgkb_get_post` carries |
| 5 | author names in the index, and `total` as a count |
| 6 | reactions as a total across emojis, inside a date window |
| 7 | an empty answer: nothing in the archive matches, and saying so |
| 8 | a word inside an identifier, which only the substring index sees |
| 9 | one sharing found by search, then every sharing of its link |
| 10 | more matches than one default page: the cursor, or a date bound |

**Grading a model.** `Scripts/run_mcp_eval.py` writes the store, builds `tgkb-mcp`, and asks each
question in its own `claude -p` session with only the three tools available — no built-in tool, and
no MCP configuration persisted. It needs a logged-in Claude Code CLI (`--claude PATH` or `$CLAUDE`
when it is not on `PATH`) and writes the transcripts and a report, including the model's feedback on
the tools, to `--out`. Results of runs are recorded in `research/s6-mcp-builder-review.md`.
