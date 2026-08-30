# Prior art: Telegram MCP servers

Research date: 2026-08-23. Status: complete.

Method note: GitHub's unauthenticated REST API rate limit (60/hr) was exhausted early in this
run. Metadata captured before exhaustion is marked Verified; everything after was traced via
`raw.githubusercontent.com` file fetches at branch `main` (no commit pin available without the
API, so file contents are "main as of 2026-08-23").

---

## Verdict / what this means for us

**The gap is real.** Across seven Telegram MCP servers, none supports date range + sender +
media type + reactions together, none exposes a media-type filter, none exposes reaction data
as a *filter* (only send-a-reaction and read-one-message's-reactions), and — the sharpest
finding — **none has a full-text index of any kind.** The single project with a persistent
message store (`jgalea/telegram-mcp`, 5 stars) searches it with `SELECT * FROM messages WHERE
text LIKE ?`; a grep of its whole source for `fts5|fts4|USING fts|MATCH` returns nothing. The
field leader (`chigwell/telegram-mcp`, 1 499 stars) has no persistence at all and enforces date
bounds by walking results client-side, with an in-source comment saying so.

Also unoccupied: **not one of the seven emits a `t.me` deep link.** `chaindead` drops the
message ID from its response record entirely, so its output *cannot* be cited even in
principle. `dryeab` ships a well-written `t.me` URL parser and uses it only inbound.

Three caveats to keep us honest:
1. The gap is unoccupied because it is *expensive*, not because it is unnoticed. Every project
   surveyed made an explicit choice to stay stateless or cache-only. The differentiating work is
   the index, the backfill, and FLOOD_WAIT-survivable ingestion — not the tool schemas.
2. `chigwell/telegram-mcp` is at 1 499 stars and committing this week. We are not entering an
   empty field; we are entering a crowded field at an unoccupied *depth*.
3. Nobody handles FLOOD_WAIT. Both target repos have literally zero rate-limit code
   (verified by grep). For a live-query wrapper that is a bug; for a backfilling indexer it is
   the main loop. This is the risk that will actually bite us, and prior art offers no help.

**Three tool-schema ideas worth stealing:**
1. **`chaindead`'s round-trippable peer literal.** One `name: string` parameter accepting
   `@username` *or* the synthetic `chn[<channelID>:<accessHash>]` / `cht[<chatID>]`, with the
   listing tool emitting exactly the literal the next tool accepts. One string instead of an
   id/hash/type triple, and no resolve-call in the model's loop.
2. **`dryeab`'s `parse_telegram_url` regex — run in both directions.** It already handles
   `t.me/<user>/<id>`, `telegram.me/…`, and private `t.me/c/<internal_id>/<id>`. They only parse;
   we should parse *and* emit, putting the permalink on every returned record.
3. **`dryeab`'s `mcp-telegram tools` CLI command**, which introspects the live
   `await mcp.list_tools()` and pretty-prints name/description/params with required markers.
   Self-documenting, and it cannot drift from the real schema the way a README table does.

Plus two design decisions to copy outright: **`chaindead`'s fail-fast** (`os.Stat` the session
in `serve` and refuse to start without it) over `dryeab`'s start-anyway-and-fail-per-call; and
the **proxy + detached singleton daemon over a Unix socket** that `jgalea` and
`mcp-telegram/mcp-telegram` independently converged on, which is directly relevant to our
cross-process SQLite question.

**On the awkward stdio-login problem: all three serious projects punted, and they were right.**
`chaindead` uses a separate `auth` subcommand reading the SMS code from a TTY via `bufio`;
`dryeab` a separate `login` Typer command with `rich` prompts; `jgalea` a standalone `login.py`
CLI; `chigwell` a separate `session_string_generator.py` that additionally supports **QR login**
(`--qr`), which is the one genuinely better idea in the group because it removes the SMS-code
prompt from the flow. Nobody attempts login over the MCP channel. We should not either.

One thing every one of them got wrong and we should not: **the session file is unencrypted in
all four** (gotd plaintext JSON, or a Telethon SQLite session). On macOS we have Keychain;
use it.

---

## 1. chaindead/telegram-mcp — Go, gotd/td MTProto

**Verified metadata** (GitHub REST API, fetched 2026-08-23 before rate-limit exhaustion):
MIT licence · Go · 343 stars · 58 forks · 12 open issues · created 2025-04-01 ·
`pushed_at` **2026-05-28** · not archived · default branch `main` ·
topics `mcp, mcp-server, mtproto, telegram, telegram-api`.
Last commit **2026-05-28** (verified independently via `commits/main.atom`, which also shows
2026-02-27 and 2025-08-21 — a slow but live cadence).
Maintenance signal: **alive but slow — ~3 months since the last commit**, and the most-starred
Telegram MCP server. Deps pinned at `gotd/td v0.121.0`, `metoro-io/mcp-golang v0.8.0` (`go.mod`).

### 1.1 Exact tool schemas

Registration is five calls in `serve.go`. Parameter schemas are generated from Go struct tags
by `invopop/jsonschema`, so the struct *is* the schema:

```go
server.RegisterTool("tg_me",      "Get current telegram account info",                        client.GetMe)
server.RegisterTool("tg_dialogs", "Get list of telegram dialogs (chats, channels, users)",    client.GetDialogs)
server.RegisterTool("tg_dialog",  "Get messages of telegram dialog",                          client.GetHistory)
server.RegisterTool("tg_send",    "Send draft message to dialog",                             client.SendDraft)
server.RegisterTool("tg_read",    "Mark dialog messages as read",                             client.ReadHistory)
```

That is the complete tool surface — **five tools, and none of them is a search tool.**

| Tool | Params (source struct) | Returns (JSON, as one text content block) |
|---|---|---|
| `tg_me` | none (`EmptyArguments{}`, `internal/tg/me.go`) | `{id:int64, first_name:string, last_name:string, username:string}` |
| `tg_dialogs` | `offset: string` (opt, "Offset for continuation"), `only_unread: bool` (opt) — `DialogsArguments`, `internal/tg/dialogs.go` | `{dialogs:[DialogInfo], offset:DialogsOffset}` |
| `tg_dialog` | `name: string` (**required**, "Name of the dialog"), `offset: int` (opt, "Offset for continuation") — `HistoryArguments`, `internal/tg/history.go` | `{messages:[MessageInfo], offset:int}` |
| `tg_send` | `name: string` (**required**), `text: string` (**required**, "Plain text of the message") — `DraftArguments`, `internal/tg/draft.go` | `{success: bool}` |
| `tg_read` | `name: string` (optional — note: *not* marked required, unlike the others) — `ReadArguments`, `internal/tg/read.go` | `{result: string}` — literally `"done"` or `"unread messages not found"` |

Record shapes (`internal/tg/dialogs.go`):

```go
type MessageInfo struct {
	Who      string `json:"who,omitempty"`
	When     string `json:"when"`          // time.DateTime, "2006-01-02 15:04:05", local tz
	Text     string `json:"text,omitempty"`
	IsUnread bool   `json:"is_unread,omitempty"`
	ts       int    // unexported — NOT serialised
}

type DialogInfo struct {
	Name        string       `json:"name,omitempty"`  // username, or cht[id] / chn[id:hash]
	Type        string       `json:"type"`            // user|bot|chat|channel|unknown
	Title       string       `json:"title"`
	LastMessage *MessageInfo `json:"last_message,omitempty"`
	Empty       bool         `json:"empty,omitempty"`
}
```

**The single most important observation: `MessageInfo` has no message ID field.** `who / when /
text / is_unread` and nothing else. `t.me/<channel>/<msgID>` cannot be constructed from a
`tg_dialog` response — the ID is available in `history.Info()` (it reads `m.ID` for the offset)
and is deliberately dropped from the record. **This server cannot cite.** That is the clearest
differentiator for us and the first thing to do differently.

### 1.2 Addressing scheme (worth stealing)

`getInputPeerFromName` (`internal/tg/history.go`) accepts one `name` string in three forms:
a resolvable `@username`, or the synthetic literals `cht[<chatID>]` and
`chn[<channelID>:<accessHash>]`. `getUsername` (`internal/tg/helpers.go`) emits those same
literals when a chat/channel has no public username, so the identifier a listing returns is
directly re-feedable to the next tool. **This round-trip property is the good idea in this
repo:** one opaque-but-inspectable string parameter instead of an id/hash/type triple, and no
separate "resolve" tool call in the loop.

### 1.3 Pagination

Two different cursor styles, both string/int scalars echoed back by the caller:
- `tg_dialog`: `offset` is an `int`, the raw MTProto `OffsetID` (`history.Offset()` returns the
  last message's `ID`). Passed straight into `MessagesGetHistoryRequest{OffsetID: args.Offset}`.
- `tg_dialogs`: `offset` is an opaque **string** `"<peertype>-<id>-<msgid>-<date>"`, or the
  sentinel `"end"` when exhausted (`DialogsOffset.String()`, `internal/tg/dialogs_offset.go`).

The `"end"` sentinel is a nice touch — the model gets an explicit stop signal rather than
having to infer exhaustion from an empty array.

Note `MessagesGetHistoryRequest` is built with only `Peer` and `OffsetID` — **no `Limit`**, so
page size is whatever the zero value yields from the server. Not a pattern to copy.

### 1.4 Session / auth — they punted, deliberately and correctly

Interactive login is a **separate CLI subcommand**, not an MCP tool:

```
telegram-mcp auth -p <phone> [--password <2fa>] [--new]
```

`internal/tg/auth.go` reads the SMS code with `bufio.NewReader(os.Stdin).ReadString('\n')`
after printing `📩 Enter code: ` — i.e. it assumes a TTY, which is exactly what a stdio MCP
server does not have. They resolved the conflict by making the two modes different processes:
`main.go` wires `auth` as a subcommand and `serve` as the default action.

The serve path then **hard-fails if the session file is absent** rather than trying to log in
over the MCP channel (`serve.go`):

```go
_, err := os.Stat(sessionPath)
if err != nil {
    return fmt.Errorf("session file not found(%s): %w", sessionPath, err)
}
```

- **Location**: `~/.telegram-mcp/session.json` (`main.go`: `dir = ".telegram-mcp"`), overridable
  via `--session` / `TG_SESSION_PATH`.
- **Format**: gotd `telegram.FileSessionStorage` — **plain JSON, not encrypted.** The directory
  is created `0700` (`os.MkdirAll(sessionDir, 0700)`); the file's own mode is left to gotd.
- Credentials `TG_APP_ID` / `TG_API_HASH` come from env vars; `auth` helpfully prints a
  ready-to-paste MCP client config block on success (`auth.go`).
- `--dry` runs a self-test (GetMe, GetDialogs, three GetHistory shapes, SendDraft, ReadHistory)
  and exits — a cheap "is my config good?" path that avoids debugging through the MCP client.

**Verdict on this: copy the split.** Separate `auth` subcommand + refuse-to-serve-without-session
is the right answer to the stdio-login problem, and it is the same conclusion two independent
projects reached (see dryeab below). The `--dry` self-test and the config-block printing are
both worth copying. What to improve: encrypt the session (Keychain on macOS), and make the
refusal message a *structured* MCP error the model can relay, since the current failure happens
before the MCP transport is even up, so the user sees a dead server with no in-client
explanation.

### 1.5 Local index? No.

There is none. Every tool call opens a **fresh MTProto connection**: each method calls `c.T()`
to construct a brand-new `telegram.Client` and wraps the work in `client.Run(...)`
(`internal/tg/client.go` + every tool file). `NoUpdates: true` is set in the serve path, so it
does not even hold an update stream. Consequence: full connect/auth handshake per tool call,
and no cross-call caching whatsoever.

### 1.6 Rate limits / FLOOD_WAIT

**No handling.** Grepping the entire Go source for `floodwait|ratelimit|middleware|backoff|retry`
returns exactly one hit, and it is a transitive `// indirect` line in `go.mod`
(`cenkalti/backoff/v4`). gotd ships a `telegram/middleware/floodwait` waiter and a `ratelimit`
middleware, but both are opt-in via `telegram.Options.Middlewares`, and `internal/tg/client.go`
sets only `SessionStorage` and `NoUpdates`. `golang.org/x/time` is a direct dependency but no
rate limiter is constructed in any tool path. A FLOOD_WAIT therefore surfaces as a raw wrapped
error to the model. **Avoid this.** For an indexer that backfills a channel this is not a
corner case, it is the main loop.

### 1.7 Copy / avoid

**Copy:** the round-trippable `name` peer literal (`chn[id:hash]`); the `"end"` cursor sentinel;
the `auth`-subcommand/`serve`-default split; `--dry` self-test; printing the client config block
after login.

**Avoid:** dropping message IDs (kills citation); no `Limit` on history requests; a fresh
MTProto client per tool call; plaintext session file; zero FLOOD_WAIT handling; `tg_read`'s
`name` not being marked required when the code requires it.

## 2. dryeab/mcp-telegram — Python, Telethon

**Verified metadata**: MIT licence (`LICENSE`, "Copyright (c) 2025 Yeabsira Driba") ·
Python `>=3.10` · package version **0.1.11** (`pyproject.toml`) · **248 stars**
(github.com/dryeab/mcp-telegram HTML, "248 users starred", 2026-08-23 — the REST API was
rate-limited by this point) · deps `mcp[cli]>=1.6.0`, `telethon>=1.39.0`.
Last commit **2025-06-15** (`commits/main.atom`; previous entries 2025-04-20).
Maintenance signal: **dormant — ~14 months with no commits.**

### 2.1 Exact tool schemas

Nine tools, registered as `@mcp.tool()`-decorated async functions in `src/mcp_telegram/server.py`.
FastMCP derives the JSON Schema from the Python type hints and the Google-style docstring, so
the signature *is* the schema. Return types are Pydantic models (`src/mcp_telegram/types.py`),
so returns are structured, not stringified JSON.

| Tool | Parameters (type, default) | Returns |
|---|---|---|
| `send_message` | `entity: str` (req) · `message: str = ""` · `file_path: list[str] \| None = None` · `reply_to: int \| None = None` | `str` — `f"Message sent to {entity}"` |
| `edit_message` | `entity: str` (req) · `message_id: int` (req) · `message: str` (req) | `str` — `f"Message edited in {entity}"` |
| `delete_message` | `entity: str` (req) · `message_ids: list[int]` (req) | `str` — `f"Messages deleted from {entity}"` |
| `search_dialogs` | `query: str` (req) · `limit: int = 10` · `global_search: bool = False` | `list[Dialog]` |
| `get_draft` | `entity: str` (req) | `str` (empty string if no draft) |
| `set_draft` | `entity: str` (req) · `message: str` (req) | `str` — `f"Draft saved for {entity}"` |
| `get_messages` | `entity: str` (req) · `limit: int = 10` · `start_date: datetime \| None` · `end_date: datetime \| None` · `unread: bool = False` · `mark_as_read: bool = False` | `Messages` |
| `media_download` | `entity: str` (req) · `message_id: int` (req) · `path: str \| None = None` | `DownloadedMedia` |
| `message_from_link` | `link: str` (req) | `Message` |

**`search_dialogs` searches dialog titles and usernames — not message text.** Its docstring is
explicit: "only dialogs where the query string is found within the dialog's title or username".
There is **no message-full-text-search tool in this server either.**

Return models (`types.py`), verbatim field sets:

```python
class Message(BaseModel):
    message_id: int
    sender_id: int | None = None
    message: str | None = None      # full text, not truncated
    outgoing: bool
    date: datetime | None = None
    media: Media | None = None
    reply_to: int | None = None

class Media(BaseModel):
    media_id: int
    mime_type: str | None = None    # the closest thing to a "media type" anywhere in the field
    file_name: str | None = None
    file_size: int | None = None

class Messages(BaseModel):
    messages: list[Message]
    dialog: Dialog | None = None

class Dialog(BaseModel):
    id: int; title: str; username: str | None; phone_number: str | None
    type: DialogType            # user | group | channel | bot
    unread_messages_count: int
    can_send_message: bool

class DownloadedMedia(BaseModel):
    path: str; media: Media
```

**No `reactions` field. No `views` field. No `url` / permalink field.** Message bodies are
returned in full (`message.text` verbatim), so responses are token-heavy on long channel posts.

### 2.2 Citation: they parse `t.me` links but never emit them

`message_from_link` is the inverse of what we need. `utils.parse_telegram_url` holds the regex:

```python
pattern = r"^(?:https?://)?t(?:elegram)?\.me/(?:(?P<username>[A-Za-z0-9_]+)/(?P<message_id>\d+)|c/(?P<chat_id>\d+)/(?P<chat_message_id>\d+))/?$"
```

It handles `t.me/<user>/<id>`, `telegram.me/...`, and the private `t.me/c/<internal_id>/<id>`
form. So the repo has already done the fiddly half of link handling — **and then only uses it
inbound.** Nothing in `Message.from_message` constructs a link on the way out. A caller can
paste a link in, but cannot get one back to cite with.

That regex is worth lifting wholesale (it is the cleanest primary-source artefact in either
repo), and then run in **both** directions.

### 2.3 Date filtering — real, but a linear scan, not an index

This is the closest any surveyed server gets to our target, so the mechanism matters
(`telegram.py`, `Telegram.get_messages`):

```python
if end_date is None:
    end_date = datetime.now(timezone.utc)
# make it very old if start_date is not provided
if start_date is None:
    start_date = end_date - timedelta(days=10000)
...
async for message in self.client.iter_messages(_entity, offset_date=end_date):
    ...
    if message.date < start_date or len(results) >= limit:
        break
```

- `end_date` maps to Telethon's `offset_date` — genuinely server-side, but it is only a
  *starting point* ("messages older than"), not a bound.
- `start_date` is enforced **entirely client-side**, by walking messages newest-to-oldest and
  `break`ing. This is the empirical fact from the brief showing through in someone else's code:
  because `searchChatMessages`/`messages.getHistory` has no `min_date`, the only way to bound
  the older end is to page until you cross it.
- The "no start date" default is `end_date - timedelta(days=10000)` — a ~27-year sentinel.
- `limit` (default 10) also breaks the loop, so **date range and limit interact badly**: ask for
  a year of a busy channel with the default limit and you get the 10 newest in the window, with
  nothing in the response indicating truncation.
- Note the `limit` default disagrees between layers — `server.py` declares `limit: int = 10`,
  `telegram.py` declares `limit: int = 20`. The tool-facing 10 wins.

**No `offset`/cursor parameter on `get_messages` at all.** There is no way to ask for the next
page: the only knobs are `limit` and the date window, so continuation means the model
re-guessing a narrower `end_date`. That is a real design defect to avoid.

### 2.4 Session / auth — punted to a CLI, same conclusion as chaindead

Separate Typer CLI commands (`src/mcp_telegram/cli.py`), independently arriving at the same
split as the Go project:

- `mcp-telegram login` — interactive `rich` prompts for API ID, API hash (both entered with
  `password=True`), phone, then `code_callback` and `password_callback` for the SMS code and 2FA.
- `mcp-telegram start` — the actual MCP server (`mcp.run()`), no interactivity.
- `mcp-telegram logout` — **prints instructions telling the human to revoke the session in the
  Telegram app themselves**; it does not call `log_out()`.
- `mcp-telegram clear-session` — deletes the local session file.
- `mcp-telegram tools` — introspects `await mcp.list_tools()` and renders name/description/
  parameters as a `rich` table, marking required params. **Steal this.** A self-documenting
  `tools` subcommand that reads the real registered schema (not a hand-maintained README table)
  is cheap and keeps docs honest.

- **Location**: `$XDG_STATE_HOME/mcp-telegram/session` → Telethon appends `.session`
  (`clear_session` uses `.with_suffix(".session")`, confirming the real filename). Downloads go
  to `$XDG_STATE_HOME/mcp-telegram/downloads`.
- **Format**: a **Telethon SQLite session file — not encrypted.** The auth key sits in plain
  SQLite; anyone with read access to the file has the account.
- API ID / hash come from env at serve time via `pydantic_settings.Settings` (`api_id`,
  `api_hash` as a `SecretStr`) — note `login` takes them interactively but the *server* re-reads
  them from the environment, so they must be supplied twice, in two different ways.
- Unlike chaindead, the server does **not** check for a session before starting: `app_lifespan`
  calls `tg.client.connect()` and yields regardless. An unauthorised server starts happily and
  fails per tool call.

**Verdict: same punt, better ergonomics, worse failure mode.** Copy the `login`/`start` split
and the `tools` introspection command; copy chaindead's fail-fast-on-missing-session instead of
this one's start-anyway.

### 2.5 Local index? No.

Every tool is a live Telethon call. The only persistence is the session file, the Telethon
entity cache inside it, and downloaded media. `get_messages` re-walks history from the network
on every invocation.

One structural improvement over chaindead: the client is created **once** in the FastMCP
`app_lifespan` context manager and connected for the process lifetime, rather than reconnecting
per tool call.

### 2.6 Rate limits / FLOOD_WAIT

**No repo-level handling.** Grep for `flood|ratelimit|rate_limit|sleep_threshold|retry|backoff`
across `src/mcp_telegram/` returns nothing. `TelegramClient` is constructed with only
`session`, `api_id`, `api_hash`, so Telethon's built-in `flood_sleep_threshold` default (60 s —
below which it sleeps and retries silently, above which it raises `FloodWaitError`) applies by
default rather than by choice. Anything above the threshold surfaces as an unhandled exception.
The only `try/except` in the message loop guards `mark_read`, not the fetch.

### 2.7 Copy / avoid

**Copy:** the `parse_telegram_url` regex (both directions); Pydantic return models instead of
JSON-in-a-string; the `tools` CLI introspection table; connect-once-in-lifespan; `reply_to` on
the message record (cheap, and it gives thread context for free); `media.mime_type` as the
honest media discriminator.

**Avoid:** `get_messages` having no cursor; `limit` silently truncating a date range with no
"more results exist" signal; the 10-vs-20 default mismatch; returning full message bodies
unconditionally; never emitting `t.me` links despite owning the parser; starting the server
without a session; `logout` that does not log out.

## 3. Landscape

Seven Telegram MCP servers surveyed. Star counts and dates verified 2026-08-23 (REST API where
the quota allowed, otherwise the repo HTML page's "N users starred" and `commits/<branch>.atom`).

| Server | Lang | Transport | Message-content search | Filters actually exposed | Local index | Reactions | Stars / last commit |
|---|---|---|---|---|---|---|---|
| **chaindead/telegram-mcp** | Go (gotd) | stdio | **none** | offset only | no | no | 343 · 2026-05-28 |
| **dryeab/mcp-telegram** | Python (Telethon) | stdio | **none** (`search_dialogs` = titles only) | date range, unread | no | no | 248 · 2025-06-15 |
| **chigwell/telegram-mcp** | Python (Telethon) | stdio | yes (`search_messages`, `search_global`, `list_messages.search_query`) | **text + date range** (`from_date`/`to_date`); no sender; no media type | no | read-only, per-message (`get_message_reactions`) | **1 499** · 2026-08-23 |
| **jgalea/telegram-mcp** | Python (Telethon) | stdio → daemon over Unix socket | yes (`search_messages` LIKE, `search_regex`) | `search_regex`: text + date range; `read_messages`: sender + one-sided date; never combined | **yes — SQLite `cache.db`** | write-only (`send_reaction`) | 5 · 2026-06-17 |
| **mcp-telegram/mcp-telegram** | TypeScript | stdio → daemon over Unix socket | yes (`telegram-search-messages`, `-search-global`) | per Telegram API | no ("stateless cursors; agent owns `{pts, qts, date}`") | richest set (send/get/top/recent/paid), but per-message, not a filter | 33 · 2026-08-20 |
| **n24q02m/better-telegram-mcp** | Python | stdio | yes | per Telegram API | no | react/search listed | 11 · 2026-08-23 |
| **Muhammad18557/telegram-mcp** | Python | stdio | yes (`list_messages`) | limited | no | no | 24 · 2025-04-07 |

Two independent projects (jgalea, mcp-telegram/mcp-telegram) have converged on the same
architecture we should note: **a thin stdio proxy that spawns a detached singleton daemon and
proxies tool calls to it over a Unix socket**, so one long-lived MTProto connection is shared
across MCP client restarts. `jgalea/telegram-mcp` `src/telegram_mcp/server.py` does this with
`_spawn_daemon()` / `_ensure_daemon_ready()` / `_call_daemon()`, `start_new_session=True`, an
flock singleton, and a `~/.telegram-mcp/daemon.log` so a daemon that dies during Telethon
connect is diagnosable. That is directly relevant to our own cross-process SQLite question.

---

## 4. The gap verdict

**The gap is real. Nobody supports date range + sender + media type + reactions together.
Nobody is even close on reactions, and nobody has a real full-text index.**

Taking the four axes one at a time, against primary source:

**Reactions — no one, anywhere.** This is the cleanest part of the verdict. Across all seven
servers, reaction support is exclusively *per-message* and *imperative*: send a reaction, or
read the reaction list of one known message ID. `chigwell/telegram-mcp` has
`get_message_reactions(chat_id, message_id, limit, account)` — you must already know the
message. `jgalea/telegram-mcp` has only `send_reaction`; grepping its entire source for
`reaction` returns four hits, all on the write path (`SendReactionRequest`, `ReactionEmoji`,
`send_reaction`), and its SQLite schema has **no reactions column**.
`mcp-telegram/mcp-telegram` has the largest reaction surface in the field (`-send-reaction`,
`-get-reactions`, `-set-default-reaction`, `-get-top-reactions`, `-get-recent-reactions`,
plus paid-reaction tools) and still offers no way to say "messages with more than N reactions".
This matches the brief's given: there is no reaction-based search in the API outside Premium
Saved Messages tags, and **no one has worked around it by indexing reaction counts locally.**

**Media type — no one filters on it.** `jgalea` is the only project that even *stores* it
(`media_type TEXT` in the `messages` table), and no tool exposes it as a filter.

**Sender — one project, never combined with text.** `jgalea`'s `read_messages` takes
`from_user`, but `read_messages` has no query parameter; its two search tools
(`search_messages`, `search_regex`) have no sender parameter. So sender-filtered search is not
reachable in any surveyed server.

**Date + text — two projects, both by client-side scan.** This is where the field tops out, and
the most useful corroboration in this whole survey is a comment in the most-popular server's
own source. `chigwell/telegram-mcp`, `telegram_mcp/tools/messages.py`, in `list_messages`:

```python
# IMPORTANT: Do not combine offset_date with search.
# Use server-side search alone, then enforce date bounds client-side.
params["search"] = search_query
messages = []
async for msg in cl.iter_messages(entity, **params):  # newest -> oldest
    if to_date_obj and msg.date > to_date_obj:
        continue
    if from_date_obj and msg.date < from_date_obj:
        break
```

A maintainer with 1 499 stars has independently hit and documented exactly the constraint the
brief states as given — text search and date bounds cannot be combined server-side, so the date
window has to be enforced by walking results. `dryeab` does the same thing without the search
(`if message.date < start_date ... break`). **Everyone pays the linear-scan tax; nobody has
built the index that removes it.**

**And the one project with a local index does not have a full-text index.** This is the
sharpest technical finding of the survey. `jgalea/telegram-mcp` is the only surveyed server
with a persistent message store, and it is a cache, not a search index:

```python
# src/telegram_mcp/cache.py
def search(...):
    """Search messages by text using LIKE, optionally filtered by chat_id."""
    sql = "SELECT * FROM messages WHERE text LIKE ?"
```

Grepping its entire source for `fts5|fts4|USING fts|MATCH` returns **nothing.** The README's
`CREATE INDEX idx_messages_text ON messages(text)` is a plain B-tree on a TEXT column, which
does nothing for the `LIKE '%…%'` queries it is ostensibly there to serve. `search_regex` is
worse: it issues `SELECT * FROM messages WHERE text IS NOT NULL`, `fetchall()`s the entire
result set into memory, and applies a Python `re` in a loop.

So the honest competitive picture is:

- Nobody has FTS5. Nobody has any full-text index at all.
- One project (5 stars) has a passive SQLite cache and reaches "text + date range" or
  "sender + date", never a conjunction of three, never reactions.
- The 1 499-star leader has no persistence whatsoever and scans linearly for date bounds.
- **Not one of the seven emits a `t.me` deep link.** `dryeab` owns a good `t.me` URL parser and
  uses it only inbound. Citation is unoccupied ground.

**What this does not mean:** the gap is not unoccupied because it is easy. It is unoccupied
because it requires committing to a real local index with a backfill path, which every project
here declined to do (jgalea explicitly: "The cache supplements live data, it doesn't replace
it"). The work is the index, the backfill, and FLOOD_WAIT-survivable ingestion — not the tool
schemas. Our differentiation is real but it is all in the part nobody wanted to build.

---

## 5. Secondary: archiver / exporter prior art

There is good local-index prior art, and the best of it is **`knadh/tg-archive`** (1 164 stars,
last commit 2026-03-01, Python/Telethon). It is the closest thing in the ecosystem to what we
are building minus the MCP layer: it syncs a group into a local `data.sqlite` **incrementally**
("downloading only new messages since the last sync"), then generates a static site. Its schema
(`tgarchive/db.py`) is a `messages` table with `id, type, date, edit_date, content, reply_to,
user_id, media_id`, a `users` table, and a normalised `media` table (`id, type, url, title,
description, thumb`) joined by FK — note it **normalises media into its own table with a `type`
column and even parses polls out of `media_description` as JSON**, which is more media
modelling than any MCP server in the survey. Two things worth stealing: the incremental
resumable sync keyed on last-seen message id (the backfill problem we actually have), and the
media-as-separate-table shape. What is *not* worth copying is its search story — grepping
`tgarchive/db.py` for `fts|virtual table` returns zero, and there is no `search` method at all;
searching is left to the generated static site's year/month/day index pages. So even the best
archiver stops exactly where we would start.

The other name people will point at, **`expectocode/telegram-export`** (now `tnjd/telegram-export`,
484 stars), is **dead — its README states "This project is currently archived" and the last
commit is 2019-10-23.** Do not build on it. It is still worth two minutes of reading for its
rationale, which is our thesis stated in 2018: its README argues "SQLite instead of jsonlines
allows for far more powerful queries". It also exposes `--search` over the exported DB. But it
is seven years stale against a Telethon and MTProto that have both moved.

Net: borrow `tg-archive`'s incremental-sync and media-normalisation shape, and note that
**nobody in the archiver world has put FTS5 on it either** — so the FTS5 layer is ours to write
whether we start from prior art or not.

## 6. Verified / Unverified ledger

### Verified — traced to primary source

All file contents below were fetched from `raw.githubusercontent.com` at the named branch on
2026-08-23. No commit pin was obtainable for most (the REST API quota was exhausted), so these
are "branch `main`/`master` as of 2026-08-23".

**chaindead/telegram-mcp** — every claim in §1 traced to a downloaded file: `serve.go` (the five
`RegisterTool` calls; the `os.Stat` session guard; the `--dry` self-test), `main.go` (CLI wiring,
`~/.telegram-mcp`, env var names), `auth.go` + `internal/tg/auth.go` (interactive flow, stdin
code prompt, `os.MkdirAll(…, 0700)`), `internal/tg/{client,me,dialogs,dialogs_offset,history,draft,read,helpers}.go`
(all argument/response structs quoted verbatim; peer-literal parsing; the `"end"` sentinel),
`go.mod` (dep versions). Absence of FLOOD_WAIT handling verified by grep for
`floodwait|ratelimit|rate_limit|middleware|backoff|retry` across all downloaded Go sources —
one hit, an `// indirect` line in `go.mod`. Repo metadata (MIT, 343 stars, 58 forks, `pushed_at`
2026-05-28, topics) from a GitHub REST API response captured before the quota ran out;
last-commit date independently confirmed via `commits/main.atom`.

**dryeab/mcp-telegram** — every claim in §2 traced to `src/mcp_telegram/{server,telegram,types,cli,utils}.py`,
`pyproject.toml`, `LICENSE`. All nine tool signatures, all Pydantic models, the `get_messages`
date logic, and the `parse_telegram_url` regex are quoted verbatim from those files. Absence of
FLOOD_WAIT handling verified by grep for `flood|ratelimit|rate_limit|sleep_threshold|retry|backoff`
across `src/mcp_telegram/` — zero hits. Star count (248) from the repo's HTML page
("248 users starred"), **not** the API. Last commit 2025-06-15 from `commits/main.atom`.

**Independent corroboration**: a DeepWiki `deep` query over both repos returned file+line
citations agreeing on all five questions asked (no message-content search, no sender filter, no
media-type filter, no reactions in any data structure, no local index in either). Share link:
`https://deepwiki.com/search/for-each-repo-answer-precisely_e8b06a63-5f7d-42f1-a08e-e89947758860?mode=deep`.
**Caveat recorded honestly:** DeepWiki reported its indexes pinned at `956f664f` (2025-04-29,
5 commits behind) for chaindead and `1af33161` (2025-04-20, 1 commit behind) for dryeab. It is
therefore corroboration of my own `main`-branch reads, not an independent check of `main`. The
primary-source reads are the authority for §1 and §2.

**jgalea/telegram-mcp** — the load-bearing gap findings are from downloaded source, not the
README: `src/telegram_mcp/server.py` (the `_tool()` schema helper and the verbatim
`read_messages` / `search_messages` / `search_regex` parameter dicts; `_spawn_daemon` /
`_ensure_daemon_ready` / `_call_daemon`), `src/telegram_mcp/cache.py` (the `LIKE` search
docstring and SQL; the `search_regex` `fetchall()`-then-Python-regex implementation),
`src/telegram_mcp/login.py` (separate login CLI, `~/.telegram-mcp` paths). **No FTS** verified by
grep for `fts5|fts4|USING fts|MATCH ` across all four downloaded files — zero hits.
**No reaction storage** verified by grep for `reaction` — four hits, all write-path. The SQLite
schema is quoted from the README (see Unverified note below). 5 stars from the repo HTML page;
last commit 2026-06-17 from `commits/main.atom`.

**chigwell/telegram-mcp** — the `list_messages` date/search code and its
`# IMPORTANT: Do not combine offset_date with search.` comment are quoted verbatim from
`telegram_mcp/tools/messages.py` (2 049 lines, downloaded). `search_messages`, `search_global`,
`get_message_context`, `get_message_reactions` signatures likewise. Metadata (Apache-2.0,
1 499 stars, pushed 2026-08-23) from a REST API response.

**Archivers** — `knadh/tg-archive` schema and absence of FTS from the downloaded `tgarchive/db.py`
(grep `fts|virtual table` → 0). Its 1 164 stars from the repo HTML page; last commit 2026-03-01
from `commits/master.atom`. `tnjd/telegram-export` archived status and the SQLite rationale from
the downloaded `README.rst`; last commit 2019-10-23 from `commits/master.atom`.

### Unverified — could not probe

- **`jgalea/telegram-mcp`'s SQLite `CREATE TABLE` statements** are quoted from its README, not
  from `cache.py` (the schema is presumably built in code I read only in part — I read its query
  methods, not its DDL). The *derived* claims are verified independently of the README: no FTS
  and no reaction column both come from grepping the source. But treat the exact column list as
  README-sourced.
- **`n24q02m/better-telegram-mcp` and `Muhammad18557/telegram-mcp`** — landscape row entries are
  from README/search-result prose only. I did not download their source. Their "search" and
  "reactions" cells should be read as *claimed*, not verified. Neither is a maintenance or
  capability threat (11 and 24 stars), so I did not spend the remaining quota on them. If either
  matters later, probe `raw.githubusercontent.com` directly.
- **`mcp-telegram/mcp-telegram`** — the 181-tool count, the tool-name inventory, the daemon
  architecture, and "stateless cursors; agent owns `{pts, qts, date}` state" are all from its
  README. TypeScript source not downloaded. The no-local-index claim rests on that README
  sentence, which is explicit but is still the project's own description.
- **Exact file permissions of the written session files** — `chaindead` creates the *directory*
  0700 (verified in source); the file mode is delegated to gotd's `FileSessionStorage` and I did
  not read gotd. Telethon's session file mode likewise unread. "Not encrypted" is verified for
  both (plain JSON / plain SQLite); "world-readable or not" is not.
- **Live behaviour of any server.** Nothing here was executed. All findings are static reads.
- **GitHub REST API metadata for `jgalea/telegram-mcp`** — could not probe; the unauthenticated
  quota (60/hr) was exhausted mid-survey. Substituted the repo HTML page and the commits Atom
  feed, which is why that row cites stars as "5 users starred" rather than an API field.
