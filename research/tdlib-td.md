# TDLib research for `telegram-kb`

**Provenance.** All C++ and TL quotations below are from `tdlib/td` **`master`**, fetched
`2026-08-23` via `raw.githubusercontent.com`. The copyright header of every file fetched reads
`... 2014-2026`, so this is a 2026-era master. The exact commit SHA could not be resolved —
the GitHub REST API returned `API rate limit exceeded` for this host, and `raw.../master/...`
does not report a SHA. Treat "master @ 2026-08-23" as the version stamp. `td_api.tl` is 16109
lines.

Marker convention used throughout:
- **Verified** = a line quoted from `td_api.tl` or a named C++ file in `tdlib/td`, or an
  official `core.telegram.org` page.
- **Unverified** = anything else, including DeepWiki prose that does not name a file.

---

## Verdict / what this means for us

### 1. The two ID transforms (PRIORITY 1) — VERIFIED, both directions

Both transforms are exact, total, and lossless in the direction we need. A web-preview row and
a TDLib row **can** be reconciled into one primary key.

**Message ID — left shift by 20.**

```
tdlib_message_id  =  int64(web_post_number) << 20
web_post_number   =  int32(tdlib_message_id >> 20)
```

**Chat ID — subtract from -1000000000000.**

```
tdlib_chat_id  =  -1000000000000 - raw_channel_id
raw_channel_id =  -1000000000000 - tdlib_chat_id      // same expression, it is an involution
```

Worked example with the caller's data — `data-post="swiftui_dev/268"`, channel `1492664793`:

| field | web value | TDLib value |
|---|---|---|
| message | `268` | `268 << 20` = `281018368` |
| chat | `1492664793` | `-1000000000000 - 1492664793` = `-1001492664793` |

**Recommended storage key:** store the **TDLib form** (`chat_id`, `message_id`) as the SQLite
primary key and derive the web form on demand by `>> 20`. Rationale: the TDLib form is the only
one of the two that can also represent local/yet-unsent/scheduled messages (the low 20 bits are
a type+local-id field, see below), so it is the strictly wider space. Going web -> TDLib is
always safe; going TDLib -> web is only safe for server messages.

**Guard you must implement:** a TDLib message id is a *server* message id only when its low 20
bits are zero. `MessageId::is_valid()` (`MessageId.cpp:115`) shows `(id & FULL_TYPE_MASK) == 0`
is the server case, with `FULL_TYPE_MASK = (1 << 20) - 1`. So before emitting a web-preview URL
for a TDLib row, assert `message_id & 0xFFFFF == 0`. Rows failing that are local/unsent/
scheduled and have no `t.me/s/` counterpart.

### 2. Everything else, in one screen

- **Date filtering is asymmetric and it is structural.** `searchChatMessages` has **no**
  `min_date`/`max_date`; global `searchMessages` has both but cannot be narrowed to one chat.
  **So per-channel date ranges must be served by our SQLite index, never pushed down to
  TDLib.** `getChatMessageByDate` is a *seek to one message*, not a filter — use it to find an
  anchor, then page.
- **Reaction search does not exist** outside Premium Saved-Messages tags. Counts ride along
  free on `message.interaction_info`. **But `updateMessageReactions` is documented "for bots
  only"** — build reaction sync on `updateMessageInteractionInfo` instead.
- **Run as a user account, not a bot.** `getChatHistory` is gated by `CHECK_IS_USER()`, so a
  bot cannot backfill a channel at all; and the reaction updates a bot *would* get are the ones
  a user does not. The two constraints point the same way.
- **`getChatHistory` short reads are real** — cap 100, terminate the loop on an **empty**
  batch, never on `count < limit`. The "first call returns nothing" folklore is **only true for
  `only_local = true`**; with `only_local = false` TDLib retries internally (4 tries) and
  normally answers with real messages.
- **TDLib absorbs flood waits for you**, up to a 60-second cumulative default per query. What
  reaches us is `{"code":429,"message":"Too Many Requests: retry after N"}` — and there is **no
  structured `retry_after` field on `error`**, so we must parse that string.
- **Enable `use_message_database`** for the backfill (resumable, serves repeat pages from disk
  — the real flood-wait mitigation), but treat it as a transient staging cache. Do not build
  the product on `searchChatMessages`.
- **Threading: one receive loop, `td_send` from anywhere, `close` and await
  `authorizationStateClosed` — never an explicit destroy.** The `const char *` from
  `td_receive` is borrowed until the next call; copy it before yielding.
- **Don't call `getMessageLink`.** For a public channel the link is just
  `t.me/<username>/<message_id >> 20>`, which we can build ourselves from data we already have.


---

## PRIORITY 1 — the message-ID transform — **VERIFIED**

### 1a. Message ID: left shift by 20 bits

The shift constant, and the bit layout comment, from **`td/telegram/MessageId.h`**:

```cpp
// MessageId.h:24-33
class MessageId {
  int64 id = 0;

  static constexpr int32 SERVER_ID_SHIFT = 20;
  static constexpr int32 SHORT_TYPE_MASK = (1 << 2) - 1;
  static constexpr int32 TYPE_MASK = (1 << 3) - 1;
  static constexpr int32 FULL_TYPE_MASK = (1 << SERVER_ID_SHIFT) - 1;
  static constexpr int32 SCHEDULED_MASK = 4;
  static constexpr int32 TYPE_YET_UNSENT = 1;
  static constexpr int32 TYPE_LOCAL = 2;
```

```cpp
// MessageId.h:36-45
  // ordinary message ID layout
  // |-------31--------|---17---|1|--2-|
  // |server_message_id|local_id|0|type|

  // scheduled message ID layout
  // |-------30-------|----18---|1|--2-|
  // |send_date-2**30 |server_id|1|type|

  // sponsored message ID layout
  // |-------31--------|---17---|1|-2|
  // |11111111111111111|local_id|0|10|
```

**Forward (raw MTProto/web -> TDLib)** — the constructor, `MessageId.h:59-61`:

```cpp
  explicit MessageId(ServerMessageId server_message_id)
      : id(static_cast<int64>(server_message_id.get()) << SERVER_ID_SHIFT) {
  }
```

**Reverse (TDLib -> raw)** — **`td/telegram/MessageId.cpp:173-176`**:

```cpp
ServerMessageId MessageId::get_server_message_id_force() const {
  CHECK(!is_scheduled());
  return ServerMessageId(narrow_cast<int32>(id >> SERVER_ID_SHIFT));
}
```

Corroborating bound, `MessageId.h:73-75` — the maximum is `INT32_MAX << 20`, confirming the
server id occupies the top 31 bits of an int64:

```cpp
  static constexpr MessageId max() {
    return MessageId(static_cast<int64>(std::numeric_limits<int32>::max()) << SERVER_ID_SHIFT);
  }
```

The server/local discriminator, **`MessageId.cpp:115-123`**:

```cpp
bool MessageId::is_valid() const {
  if (id <= 0 || id > max().get()) {
    return false;
  }
  if ((id & FULL_TYPE_MASK) == 0) {
    return true;
  }
  int32 type = (id & TYPE_MASK);
  return type == TYPE_YET_UNSENT || type == TYPE_LOCAL;
}
```

> **Formula, unambiguous, both directions**
> `tdlib_message_id = int64(server_message_id) << 20`  (`MessageId.h:60`)
> `server_message_id = int32(tdlib_message_id >> 20)`  (`MessageId.cpp:175`)
> Valid as a *server* message iff `(tdlib_message_id & ((1<<20)-1)) == 0` (`MessageId.cpp:119`).
> `2^20 = 1048576`, so `x << 20 == x * 1048576` if you prefer arithmetic to bit ops.

**Note the shift is NOT scheduled-message-safe.** `get_server_message_id_force` opens with
`CHECK(!is_scheduled())`, and `is_scheduled()` is `(id & SCHEDULED_MASK) != 0` with
`SCHEDULED_MASK = 4` (`MessageId.h:104-106`). Scheduled messages pack a *send date* into the
high bits instead of a server id. Our `& 0xFFFFF == 0` guard already excludes them, since a
scheduled id has bit 2 set.

### 1b. Chat ID: the `-100…` prefix is `-1000000000000 - channel_id`

The constant, **`td/telegram/DialogId.h:26-27`**:

```cpp
class DialogId {
  static constexpr int64 ZERO_SECRET_CHAT_ID = -2000000000000ll;
  static constexpr int64 ZERO_CHANNEL_ID = -1000000000000ll;
```

**Forward (channel id -> TDLib chat id)**, **`td/telegram/DialogId.cpp:82-88`**:

```cpp
DialogId::DialogId(ChannelId channel_id) {
  if (channel_id.is_valid()) {
    id = ZERO_CHANNEL_ID - channel_id.get();
  } else {
    id = 0;
  }
}
```

and the same arithmetic where a raw MTProto `peerChannel` is converted,
**`DialogId.cpp:145-153`**:

```cpp
    case telegram_api::peerChannel::ID: {
      auto peer_channel = static_cast<const telegram_api::peerChannel *>(peer.get());
      ChannelId channel_id(peer_channel->channel_id_);
      if (!channel_id.is_valid()) {
        LOG(ERROR) << "Receive invalid " << channel_id;
        return 0;
      }

      return ZERO_CHANNEL_ID - channel_id.get();
    }
```

**Reverse (TDLib chat id -> channel id)**, **`DialogId.cpp:56-59`**:

```cpp
ChannelId DialogId::get_channel_id() const {
  CHECK(get_type() == DialogType::Channel);
  return ChannelId(ZERO_CHANNEL_ID - id);
}
```

> **Formula, unambiguous, both directions** — note it is an *involution*, the same expression
> serves both ways:
> `tdlib_chat_id = -1000000000000 - channel_id`  (`DialogId.cpp:84`)
> `channel_id    = -1000000000000 - tdlib_chat_id`  (`DialogId.cpp:58`)
>
> Do **not** implement this as string concatenation of `"-100"` + digits. That happens to work
> for the common 9–10-digit channel id but breaks outside it: the valid channel range is
> `0 < id < 1000000000000 - 2^31` (`ChannelId.h:24,40`), i.e. ids up to ~997.8 billion, which
> are 12 digits and do not textually produce a `-100…` string.

Range constants, **`td/telegram/ChannelId.h:23-40`**:

```cpp
  // the last (1 << 31) - 1 identifiers will be used for secret chat dialog identifiers
  static constexpr int64 MAX_CHANNEL_ID = 1000000000000ll - (1ll << 31);
  static constexpr int64 MIN_MONOFORUM_CHANNEL_ID = 1000000000000ll + (1ll << 31) + 1;
  static constexpr int64 MAX_MONOFORUM_CHANNEL_ID = 3000000000000ll;
  ...
  bool is_regular_channel() const {
    return 0 < id && id < MAX_CHANNEL_ID;
  }
```

Type dispatch (how a bare int64 is classified — worth mirroring if we ever ingest a chat id we
did not construct), **`DialogId.cpp:27-42`**:

```cpp
  if (id < 0) {
    if (-ChatId::MAX_CHAT_ID <= id) {
      return DialogType::Chat;
    }
    if (ZERO_CHANNEL_ID - ChannelId::MAX_CHANNEL_ID <= id && id != ZERO_CHANNEL_ID) {
      return DialogType::Channel;
    }
```

**Caller's example, resolved.** The brief cites a raw channel id of `-1492664793` (already
negative). The *bare* `ChannelId` is the positive `1492664793`; the `-1…` form is a legacy
Bot-API-style rendering. Our transform takes the positive bare id. If a source hands us a
negative value that is **not** below `-1000000000000`, negate it first, then apply the formula.

---

## PRIORITY 2 — date-filtering asymmetry — **CONFIRMED** (verified from `td_api.tl`)

**Verdict:** the asymmetry is real. Per-chat search has **no** date window; global search does.
Our per-channel date-ranged queries must be served from **our own SQLite index**, not pushed
down to TDLib. Use `getChatMessageByDate` only to find a *seek anchor*, then page with
`getChatHistory` / `searchChatMessages`.

### `searchChatMessages` — **lacks** `min_date` / `max_date` — CONFIRMED

`td_api.tl:11724`:

```
searchChatMessages chat_id:int53 topic_id:MessageTopic query:string sender_id:MessageSender from_message_id:int53 offset:int32 limit:int32 filter:SearchMessagesFilter = FoundChatMessages;
```

There is no date parameter of any kind. Its description (`td_api.tl:11712-11713`) also carries
two constraints that matter to us:

```
//@description Searches for messages with given words in the chat. Returns the results in reverse chronological order, i.e. in order of decreasing message_id. Cannot be used in secret chats with a non-empty query
//-(searchSecretMessages must be used instead), or without an enabled message database. For optimal performance, the number of returned messages is chosen by TDLib and can be smaller than the specified limit
//-A combination of query, sender_id, filter and topic_id search criteria is expected to be supported, only if it is required for Telegram official application implementation
```

Two consequences: (a) `searchChatMessages` **requires `use_message_database = true`** — see
Priority 4; (b) arbitrary *combinations* of criteria are explicitly not guaranteed, only the
combinations the official clients happen to use.

Paging parameters (`td_api.tl:11718-11721`):

```
//@from_message_id Identifier of the message starting from which history must be fetched; use 0 to get results from the last message
//@offset Specify 0 to get results from exactly the message from_message_id or a negative number to get the specified message and some newer messages
//@limit The maximum number of messages to be returned; must be positive and can't be greater than 100. If the offset is negative, then the limit must be greater than -offset.
//-For optimal performance, the number of returned messages is chosen by TDLib and can be smaller than the specified limit
```

### `searchMessages` (global) — **has** `min_date` / `max_date` — CONFIRMED

`td_api.tl:11737`, with the two doc lines immediately above it:

```
//@min_date If not 0, the minimum date of the messages to return
//@max_date If not 0, the maximum date of the messages to return
searchMessages chat_list:ChatList query:string offset:string limit:int32 filter:SearchMessagesFilter chat_type_filter:SearchMessagesChatTypeFilter min_date:int32 max_date:int32 = FoundMessages;
```

Note it takes a `chat_list:ChatList`, **not** a `chat_id` — so it cannot be narrowed to one
channel. Its description says it searches "in all chats except secret chats". Confirming the
asymmetry is *structural*, not an oversight: the two functions even return different types
(`FoundChatMessages` vs `FoundMessages`) and page differently (`from_message_id:int53` +
`offset:int32` vs an opaque `offset:string` cursor).

Also unsupported in global search (`td_api.tl:11733-11734`):

```
//@filter ... Filters searchMessagesFilterMention, searchMessagesFilterUnreadMention, searchMessagesFilterUnreadReaction,
//-searchMessagesFilterUnreadPollVote, searchMessagesFilterFailedToSend, and searchMessagesFilterPinned are unsupported in this function
```

### `getChatMessageByDate` — yes, this is the sanctioned date seek — CONFIRMED

`td_api.tl:11821-11824`, verbatim:

```
//@description Returns the last message sent in a chat no later than the specified date. Returns a 404 error if such message doesn't exist
//@chat_id Chat identifier
//@date Point in time (Unix timestamp) relative to which to search for messages
getChatMessageByDate chat_id:int53 date:int32 = Message;
```

It returns **one** `Message`, not a range — it is a *seek*, not a filter. The documented
"Returns a 404 error if such message doesn't exist" is the case where the date precedes the
first message in the chat; handle it as empty, not as failure.

**Recommended pattern for "give me channel X between dates A and B":**
1. `getChatMessageByDate(chat_id, B)` -> anchor message id `M`.
2. `getChatHistory(chat_id, from_message_id=M, offset=0, limit=100, …)` repeatedly, walking
   backwards, until `message.date < A`.
3. Or skip TDLib entirely and range-scan our own SQLite `date` column — cheaper once indexed.

### Two adjacent helpers worth knowing (both verified)

`td_api.tl:11834` — sparse positions, useful for building a date histogram or binary-searching
a large channel without downloading every message:

```
getChatSparseMessagePositions chat_id:int53 filter:SearchMessagesFilter from_message_id:int53 limit:int32 saved_messages_topic_id:int53 = MessagePositions;
```
```
//@limit The expected number of message positions to be returned; 50-2000. A smaller number of positions can be returned, if there are not enough appropriate messages
```

`td_api.tl:11842` — a per-day message calendar, i.e. a ready-made date index:

```
getChatMessageCalendar chat_id:int53 topic_id:MessageTopic filter:SearchMessagesFilter from_message_id:int53 = MessageCalendar;
```

with `messageCalendar total_count:int32 days:vector<messageCalendarDay> = MessageCalendar;`
(`td_api.tl:3167`). If we ever need a "which months have posts" affordance, this is it —
no crawl required.

---

## PRIORITY 3 — reactions — **CONFIRMED**, with one finding that changes our sync design

**Verdict, three parts:**
1. **CONFIRMED — there is no reaction-based *search* outside Saved Messages tags.** The only
   function in the entire schema taking a reaction as a *search* criterion is
   `searchSavedMessages`, and it is Premium-only and Saved-Messages-only. If we want
   "posts with >N 👍", we must index reaction counts ourselves and filter in SQLite.
2. Reaction **counts** are read per message off `message.interaction_info.reactions`, i.e.
   they ride along with the message — no extra round trip.
3. **NEW / important: `updateMessageReaction` and `updateMessageReactions` are documented
   "for bots only".** A user-account TDLib client will not receive them. The update we
   actually get is `updateMessageInteractionInfo`. Design against that one.

### No reaction search — the exhaustive grep

Grepping `td_api.tl` for `savedMessagesTag|searchSavedMessages|SavedMessagesTag` returns
exactly seven lines:

```
3531:savedMessagesTag tag:ReactionType label:string count:int32 = SavedMessagesTag;
3534:savedMessagesTags tags:vector<savedMessagesTag> = SavedMessagesTags;
8030:premiumFeatureSavedMessagesTags = PremiumFeature;
10891:updateSavedMessagesTags saved_messages_topic_id:int53 tags:savedMessagesTags = Update;
11757:searchSavedMessages saved_messages_topic_id:int53 tag:ReactionType query:string from_message_id:int53 offset:int32 limit:int32 = FoundChatMessages;
12665:getSavedMessagesTags saved_messages_topic_id:int53 = SavedMessagesTags;
12668:setSavedMessagesTagLabel tag:ReactionType label:string = Ok;
```

The gating is explicit in the description at `td_api.tl:11747`:

```
//@description Searches for messages tagged by the given reaction and with the given words in the Saved Messages chat; for Telegram Premium users only.
//-Returns the results in reverse chronological order, i.e. in order of decreasing message_id.
...
//@tag Tag to search for; pass null to return all suitable messages
searchSavedMessages saved_messages_topic_id:int53 tag:ReactionType query:string from_message_id:int53 offset:int32 limit:int32 = FoundChatMessages;
```

Note `premiumFeatureSavedMessagesTags = PremiumFeature;` (`td_api.tl:8030`) — Telegram itself
classifies this as a paid feature, so it will not become generally available.

Corroborating: `messageReactions` (below) has `are_tags:Bool`, described as
"True, if the reactions are tags and Telegram Premium users can filter messages by them" —
the *only* place the schema uses the word "filter" about reactions, and it is scoped to tags.

The nearest thing to a reaction filter in ordinary search is
`searchMessagesFilterUnreadReaction = SearchMessagesFilter;` (`td_api.tl:6227`), which is about
*the current user's own unread* reactions, not about reaction content or counts — and it is
explicitly unsupported in global `searchMessages` (`td_api.tl:11733`) and in
`getChatSparseMessagePositions` (`td_api.tl:11838`).

### Reading reaction counts — the constructors

`td_api.tl:2951-2957`:

```
//@description Contains information about a reaction to a message
//@type Type of the reaction
//@total_count Number of times the reaction was added
//@is_chosen True, if the reaction is chosen by the current user
//@used_sender_id Identifier of the message sender used by the current user to add the reaction; may be null if unknown or the reaction isn't chosen
//@recent_sender_ids Identifiers of at most 3 recent message senders, added the reaction; available in private, basic group and supergroup chats
messageReaction type:ReactionType total_count:int32 is_chosen:Bool used_sender_id:MessageSender recent_sender_ids:vector<MessageSender> = MessageReaction;
```

`td_api.tl:2959-2964`:

```
//@description Contains a list of reactions added to a message
//@reactions List of added reactions
//@are_tags True, if the reactions are tags and Telegram Premium users can filter messages by them
//@paid_reactors Information about top users that added the paid reaction
//@can_get_added_reactions True, if the list of added reactions is available using getMessageAddedReactions
messageReactions reactions:vector<messageReaction> are_tags:Bool paid_reactors:vector<paidReactor> can_get_added_reactions:Bool = MessageReactions;
```

The container that hangs off a message, `td_api.tl:2966-2971`:

```
//@description Contains information about interactions with a message
//@view_count Number of times the message was viewed
//@forward_count Number of times the message was forwarded
//@reply_info Information about direct or indirect replies to the message; may be null. ...
//@reactions The list of reactions or tags added to the message; may be null
messageInteractionInfo view_count:int32 forward_count:int32 reply_info:messageReplyInfo reactions:messageReactions = MessageInteractionInfo;
```

The reaction *type* is a sum type — `td_api.tl:2897,2900,2903`:

```
reactionTypeEmoji emoji:string = ReactionType;
reactionTypeCustomEmoji custom_emoji_id:int64 = ReactionType;
reactionTypePaid = ReactionType;
```

For our index this means the reaction key is **not** always a Unicode emoji string: normalise
to something like `emoji:👍` / `custom:<int64>` / `paid` before storing.

**Path to counts:** `message.interaction_info` (nullable) -> `.reactions` (nullable) ->
`.reactions[]` -> `.type` + `.total_count`. Both hops are nullable; a channel post with no
reactions yields null, not an empty vector. `view_count` and `forward_count` sit on the same
object and are free — worth indexing alongside, since the `t.me/s/` preview also exposes a
view count and they can cross-validate.

Per-user reaction detail, if we ever want it (`td_api.tl:12658`, gated on
`messageReactions.can_get_added_reactions`):

```
getMessageAddedReactions chat_id:int53 message_id:int53 reaction_type:ReactionType offset:string limit:int32 = AddedReactions;
addedReaction type:ReactionType sender_id:MessageSender is_outgoing:Bool date:int32 = AddedReaction;   // :7213
addedReactions total_count:int32 reactions:vector<addedReaction> next_offset:string = AddedReactions;  // :7216
```

### The bots-only trap — VERIFIED, and it changes our incremental sync

`td_api.tl:11093-11100`:

```
//@description User changed its reactions on a message with public reactions; for bots only
//@chat_id Chat identifier
//@message_id Message identifier
//@actor_id Identifier of the user or chat that changed reactions
//@date Point in time (Unix timestamp) when the reactions were changed
//@old_reaction_types Old list of chosen reactions
//@new_reaction_types New list of chosen reactions
updateMessageReaction chat_id:int53 message_id:int53 actor_id:MessageSender date:int32 old_reaction_types:vector<ReactionType> new_reaction_types:vector<ReactionType> = Update;
```

`td_api.tl:11102-11107`:

```
//@description Reactions added to a message with anonymous reactions have changed; for bots only
//@chat_id Chat identifier
//@message_id Message identifier
//@date Point in time (Unix timestamp) when the reactions were changed
//@reactions The list of reactions added to the message
updateMessageReactions chat_id:int53 message_id:int53 date:int32 reactions:vector<messageReaction> = Update;
```

Both say **"for bots only"** verbatim. So: **is `updateMessageReactions` a real update we must
handle for incremental sync? Only if we run as a bot.** For a user session, the update to
handle is:

`td_api.tl:10331-10332`:

```
//@description The information about interactions with a message has changed @chat_id Chat identifier @message_id Message identifier @interaction_info New information about interactions with the message; may be null
updateMessageInteractionInfo chat_id:int53 message_id:int53 interaction_info:messageInteractionInfo = Update;
```

This carries the whole `messageInteractionInfo` — view count, forward count, and the full
reaction list — keyed by `(chat_id, message_id)`. It is a **replace**, not a delta, so handling
it is a straight upsert of our counts columns. Handle both families defensively (cheap), but
build the reaction pipeline on `updateMessageInteractionInfo`.

Caveat worth flagging: TDLib only emits interaction-info updates for messages it is actively
tracking (open chat / recently fetched). Reaction counts on old archived posts will **drift**
and need periodic re-fetch. That is a design constraint, not a bug we can fix.

---

## PRIORITY 4 — history crawling mechanics — **VERIFIED**

### 4a. `getChatHistory` — parameters, the short-read gotcha, and the `only_local` truth

`td_api.tl:11681-11689`, verbatim:

```
//@description Returns messages in a chat. The messages are returned in reverse chronological order (i.e., in order of decreasing message_id).
//-For optimal performance, the number of returned messages is chosen by TDLib. This is an offline method if only_local is true
//@chat_id Chat identifier
//@from_message_id Identifier of the message starting from which history must be fetched; use 0 to get results from the last message
//@offset Specify 0 to get results from exactly the message from_message_id or a negative number from -99 to -1 to get additionally -offset newer messages
//@limit The maximum number of messages to be returned; must be positive and can't be greater than 100. If the offset is negative, then the limit must be greater than or equal to -offset.
//-For optimal performance, the number of returned messages is chosen by TDLib and can be smaller than the specified limit
//@only_local Pass true to get only messages that are available without sending network requests
getChatHistory chat_id:int53 from_message_id:int53 offset:int32 limit:int32 only_local:Bool = Messages;
```

**Meanings, stated plainly:**
- `from_message_id` — the **exclusive-ish anchor**, in TDLib id space. `0` means "start at the
  newest message". Results walk **backwards** (decreasing `message_id`, i.e. decreasing time).
- `offset` — a *rewind* into newer messages. `0` = start exactly at `from_message_id`.
  Negative (`-99..-1`) = also include `-offset` messages **newer** than the anchor. Positive is
  rejected.
- `limit` — cap, `1..100`. It is a **ceiling, not a promise.**

**The short-read gotcha is real and enforced in code.** `MessagesManager.cpp:17536-17552`
clamps and validates:

```cpp
  if (limit > MAX_GET_HISTORY) {
    limit = MAX_GET_HISTORY;
  }
  if (offset > 0) {
    promise.set_error(400, "Parameter offset must be non-positive");
    ...
  if (offset <= -MAX_GET_HISTORY) {
    promise.set_error(400, "Parameter offset must be greater than -100");
```

with `MessagesManager.h:1656`:

```cpp
  static constexpr int32 MAX_GET_HISTORY = 100;       // server-side limit
```

So **you must loop.** The termination condition is *an empty result*, never
`returned.count < limit`. Concretely: set `from_message_id` to the smallest `message_id` in
each batch and call again; stop when the batch is empty.

**Now the `only_local` / "returns nothing on first call" behaviour — pinned down exactly.**
It is a *retry* mechanism, and the folklore is half-right. `Requests.cpp:958-978`:

```cpp
  void do_run(Promise<Unit> &&promise) final {
    messages_ = td_->messages_manager_->get_dialog_history(dialog_id_, from_message_id_, offset_, limit_,
                                                           get_tries() - 1, only_local_, std::move(promise));
  }
  ...
      , only_local_(only_local) {
    if (!only_local_) {
      set_tries(4);
    }
  }
```

and the default in `RequestActor.h:139`:

```cpp
  int tries_left_ = 2;
```

The retry loop lives in `RequestActor::loop()` (`RequestActor.h:53-59`) — if the promise is not
ready, it decrements `tries_left_` and re-runs `do_run`, and only fails with
`500, "Requested data is inaccessible"` when tries are exhausted.

Inside, `MessagesManager::get_dialog_history` (`MessagesManager.cpp:17576-17587`):

```cpp
  auto message_ids = d->ordered_messages.get_history(d->last_message_id, from_message_id, offset, limit,
                                                     left_tries == 0 && !only_local);
  if (!message_ids.empty()) {
    ...
  } else if (limit > 0 && left_tries != 0 && !(d->is_empty && d->have_full_history && left_tries < 3)) {
    // there can be more messages in the database or on the server, need to load them
    send_closure_later(actor_id(this), &MessagesManager::load_messages, dialog_id, from_message_id, offset, limit,
                       left_tries, only_local, std::move(promise));
    return nullptr;
  }
```

> **Verdict on the folklore.** With `only_local = false`, TDLib gets **4 tries** and will go to
> the database and then the network itself before answering — so the "first call returns
> nothing" claim is **not** true for `only_local = false`; you generally get real messages.
> With `only_local = true` there is **no network request at all** ("This is an offline method
> if only_local is true") and only 2 tries, so an **empty result on a cold cache is the normal,
> expected outcome** and means "not cached", NOT "no more history".
>
> **What we must do:** never treat an empty `only_local = true` result as end-of-history.
> Either crawl with `only_local = false` throughout, or use `only_local = true` as a fast path
> and fall back to `only_local = false` on empty.

Also note `Requests.cpp:3617`: `CHECK_IS_USER();` — **`getChatHistory` is not available to bot
accounts.** A bot session cannot backfill a channel this way at all. Combined with the
bots-only reaction updates from Priority 3, this settles the account-type question: **run as a
user account.**

### 4b. `getMessageLink` — the `can_get_link` gate, and the public vs `c/` form

The TL, `td_api.tl:11916-11924`:

```
//@description Returns an HTTPS link to a message in a chat. Available only if messageProperties.can_get_link, or if messageProperties.can_get_media_timestamp_links and a media timestamp link is generated. This is an offline method
...
getMessageLink chat_id:int53 message_id:int53 media_timestamp:int32 checklist_task_id:int32 poll_option_id:string for_album:Bool in_message_thread:Bool = MessageLink;
```

The gate is a flag on `messageProperties` (`td_api.tl:6152`, `6169`):

```
//@can_get_link True, if a link can be generated for the message using getMessageLink
```
```
messageProperties ... can_get_link:Bool ... = MessageProperties;
```
fetched via `getMessageProperties chat_id:int53 message_id:int53 = MessageProperties;`
(`td_api.tl:11433`).

The return type carries the public/private answer, `td_api.tl:9564`:

```
//@description Contains an HTTPS link to a message in a supergroup or channel, or a forum topic @link The link @is_public True, if the link will work for non-members of the chat
messageLink link:string is_public:Bool = MessageLink;
```

**The exact link construction, from `MessagesManager::get_message_link`
(`MessagesManager.cpp:15675-15685`) — this is the definitive answer:**

```cpp
  auto dialog_username = td_->chat_manager_->get_channel_first_username(dialog_id.get_channel_id());
  bool is_public = !dialog_username.empty();
  if (is_public) {
    sb << dialog_username;
  } else {
    sb << "c/" << dialog_id.get_channel_id().get();
  }
  ...
  sb << '/' << message_id.get_server_message_id().get();
```

So:
- **Public channel (has a username):** `https://t.me/<username>/<server_message_id>`,
  `is_public = true`.
- **Private channel (no username):** `https://t.me/c/<bare_channel_id>/<server_message_id>`,
  `is_public = false`. Note it uses the **bare** channel id — *not* the `-100…` chat id — and
  the **server** message id, i.e. `message_id >> 20`.
- **Non-channel chats:** rejected outright, `MessagesManager.cpp:15582-15584`:
  ```cpp
  if (dialog_id.get_type() != DialogType::Channel) {
    if (media_timestamp == 0) {
      return Status::Error(400, "Message can't have link");
  ```

> **This is an independent confirmation of both Priority 1 formulas.** TDLib's own public-link
> builder emits exactly `<bare_channel_id>` and `<message_id >> 20>` — the same two numbers the
> `t.me/s/<channel>` web preview gives us as `data-post="<channel>/<n>"`. Our reconciliation key
> is the one TDLib itself uses to address messages publicly.

Caveat: `getMessageLink` is documented "This is an offline method", but the implementation
*also* fires a server query as a side effect for non-bots
(`MessagesManager.cpp:15621-15624`) — `ExportChannelMessageLinkQuery`. So it is offline for
*your* answer but not free of network traffic. For our crawler there is **no reason to call it
at all**: we can construct `https://t.me/<username>/<n>` ourselves from the username plus
`message_id >> 20`, which is what the web-preview source already gives us.

### 4c. `FLOOD_WAIT` — exact shape, and yes TDLib auto-retries

**TDLib absorbs flood waits internally, up to a per-query cumulative budget, and only then
surfaces an error to us — and the surfaced error is `429`, not `420`.**

`td/telegram/net/NetQueryDelayer.cpp:34-48`:

```cpp
  } else if (code == 420) {
    auto error_message = query->error().message();
    for (auto prefix : {Slice("FLOOD_WAIT_"), Slice("SLOWMODE_WAIT_"), Slice("2FA_CONFIRM_WAIT_"),
                        Slice("TAKEOUT_INIT_DELAY_"), Slice("FLOOD_PREMIUM_WAIT_")}) {
      if (begins_with(error_message, prefix)) {
        if (error_message.substr(prefix.size()).find('_') != CSlice::npos) {
          // an unsupported error
          query->set_error(Status::Error(400, error_message));
          G()->net_query_dispatcher().dispatch(std::move(query));
          return;
        }

        timeout = clamp(to_integer<int>(error_message.substr(prefix.size())), 1, 14 * 24 * 60 * 60);
```

So the **raw MTProto** shape is `code 420`, message `FLOOD_WAIT_<seconds>` — parsed, clamped to
`[1 s, 14 days]`, and turned into a delay. The query is then resent
(`NetQueryDelayer.cpp:88`: `query->resend();`).

The escape hatch, `NetQueryDelayer.cpp:100-106`:

```cpp
  if (query->total_timeout_ > query->total_timeout_limit_) {
    // TODO: support timeouts in DcAuth and GetConfig
    LOG(WARNING) << "Failed: " << query << " " << tag("timeout", timeout) << tag("total_timeout", query->total_timeout_)
                 << " because of " << error << " from " << query->source_;
    // NB: code must differ from tdapi FLOOD_WAIT code
    query->set_error(Status::Error(429, PSLICE() << "Too Many Requests: retry after " << timeout));
```

and the budget default, `td/telegram/net/NetQuery.h:313-315`:

```cpp
  int32 next_timeout_ = 1;          // for NetQueryDelayer
  int32 total_timeout_ = 0;         // for NetQueryDelayer/SequenceDispatcher
  int32 total_timeout_limit_ = 60;  // for NetQueryDelayer/SequenceDispatcher and to be set by caller
```

> **Exact error shape reaching our code.** The td_api error object is
> `error code:int32 message:string = Error;` (`td_api.tl:18`). A flood wait that exceeds the
> budget arrives as:
> ```json
> {"@type":"error","code":429,"message":"Too Many Requests: retry after 37"}
> ```
> The number after `retry after ` is the **last** individual timeout, not the cumulative one.
>
> **Does TDLib auto-retry?** **Yes**, transparently, while cumulative delay stays under
> `total_timeout_limit_` (**default 60 s**). Waits longer than that budget are handed to us.
> Practically: short flood waits are invisible (our request just takes longer); long ones
> arrive as `429`. **Our crawler must parse `retry after <N>` out of the message string and
> back off** — there is no structured `retry_after` field on `td_api.error`. Confirmed by
> grepping `retry_after` in `td_api.tl`: it exists on `messageSendingStateFailed`,
> `canPostStoryResult*`, `craftGiftResultTooEarly`, etc., but **not** on `error`.
>
> Note also `SLOWMODE_WAIT_`, `FLOOD_PREMIUM_WAIT_` and `TAKEOUT_INIT_DELAY_` go through the
> same path, so a `429` is not necessarily a plain rate limit.

Also worth knowing (`NetQueryDelayer.cpp:76-81`) — for other retryable errors there is
exponential backoff with `next_timeout_ *= 2` capped at 60 s.

### 4d. Database options — what each buys and costs

`td_api.tl` (`setTdlibParameters` block), verbatim:

```
//@use_file_database Pass true to keep information about downloaded and uploaded files between application restarts
//@use_chat_info_database Pass true to keep cache of users, basic groups, supergroups, channels and secret chats between restarts. Implies use_file_database
//@use_message_database Pass true to keep cache of chats and messages between restarts. Implies use_chat_info_database
```
```
setTdlibParameters use_test_dc:Bool database_directory:string files_directory:string database_encryption_key:bytes use_file_database:Bool use_chat_info_database:Bool use_message_database:Bool use_secret_chats:Bool api_id:int32 api_hash:string system_language_code:string device_model:string system_version:string application_version:string = Ok;
```

**The implication chain is documented and one-directional:**
`use_message_database` ⟹ `use_chat_info_database` ⟹ `use_file_database`. You cannot have
messages persisted without also persisting chat info and file info.

| Option | Enables | Cost |
|---|---|---|
| `use_file_database` | remembers file ids / local paths across restarts | smallest; grows with distinct files seen |
| `use_chat_info_database` | user/group/channel metadata cache | modest; bounded by number of chats+users |
| `use_message_database` | **message persistence — and it is a hard prerequisite for `searchChatMessages`** | largest; grows unbounded with history crawled |

**Verified prerequisite, not a guess** — `td_api.tl:11712`, `searchChatMessages` description:

```
//-(searchSecretMessages must be used instead), or without an enabled message database.
```

and `getChatSparseMessagePositions` (`td_api.tl:11835`):

```
//-Cannot be used in secret chats or with searchMessagesFilterFailedToSend filter without an enabled message database
```

and `searchMessagesFilterFailedToSend` (`td_api.tl:6232`):

```
//@description Returns only failed to send messages. This filter can be used only if the message database is used
```

> **Decision for `telegram-kb`.** We are building our *own* FTS5 index, so TDLib's message
> database is largely redundant storage — we would pay for the same content twice on disk.
> But turning it **off** forfeits `searchChatMessages` entirely, and forfeits the local-cache
> fast path for `getChatHistory only_local=true`.
>
> Recommendation: **enable `use_message_database`** during backfill (it makes the crawl
> resumable across restarts and lets TDLib serve repeat pages from disk instead of the
> network — which is the real flood-wait mitigation), and treat TDLib's DB as a *transient
> staging cache* that we are free to delete once our SQLite index is authoritative. Do **not**
> design the product to query `searchChatMessages` at runtime — our FTS5 index is strictly
> better (substring, ranking, cross-source rows) and, per Priority 2, TDLib cannot date-filter
> per chat anyway.

### 4e. Update semantics an incremental sync must handle

All verbatim from `td_api.tl`:

```
//@description A new message was received; can also be an outgoing message @message The new message
updateNewMessage message:message = Update;                                                            // :10298
```
```
//@description The message content has changed @chat_id Chat identifier @message_id Message identifier @new_content New message content
updateMessageContent chat_id:int53 message_id:int53 new_content:MessageContent = Update;              // :10319
```
```
//@description A message was edited. Changes in the message content will come in a separate updateMessageContent
//@chat_id Chat identifier
//@message_id Message identifier
//@edit_date Point in time (Unix timestamp) when the message was edited
//@reply_markup New message reply markup; may be null
updateMessageEdited chat_id:int53 message_id:int53 edit_date:int32 reply_markup:ReplyMarkup = Update;  // :10326
```
```
//@description Some messages were deleted
//@chat_id Chat identifier
//@message_ids Identifiers of the deleted messages
//@is_permanent True, if the messages are permanently deleted by a user (as opposed to just becoming inaccessible)
//@from_cache True, if the messages are deleted only from the cache and can possibly be retrieved again in the future
updateDeleteMessages chat_id:int53 message_ids:vector<int53> is_permanent:Bool from_cache:Bool = Update;  // :10587
```

**What this means for our sync loop, precisely:**

| Update | Our action | Trap |
|---|---|---|
| `updateNewMessage` | insert row, index text | fires for outgoing messages too |
| `updateMessageEdited` | **do not re-index from this.** It carries only `edit_date` and `reply_markup` — **no content.** Store `edit_date`; wait for the paired `updateMessageContent`. | the schema says so outright: "Changes in the message content will come in a separate updateMessageContent" |
| `updateMessageContent` | re-index FTS text for `(chat_id, message_id)` | carries **only** `new_content`, not a whole `message`. Our upsert must patch, not replace the row. |
| `updateDeleteMessages` | **branch on the two flags** | `from_cache = true` means TDLib evicted it locally and it "can possibly be retrieved again" — **this is not a deletion.** Ignore it, or we will silently lose indexed posts to cache pressure. Only `is_permanent = true` is a real delete; otherwise it merely became inaccessible. |
| `updateMessageInteractionInfo` (:10332) | upsert view/forward/reaction counts | see Priority 3 |

Two more you will want, both verified:

```
updateMessageSendSucceeded message:message old_message_id:int53 = Update;                             // :10310
updateMessageIsPinned chat_id:int53 message_id:int53 is_pinned:Bool = Update;                         // :10329
```

`updateMessageSendSucceeded` is where a temporary (yet-unsent, low-bits-nonzero) id is replaced
by a real server id — the one place our `& 0xFFFFF == 0` guard interacts with live updates. Not
relevant if we only ingest channels we do not post to.

### 4f. `SearchMessagesFilter` variants relevant to us

From `td_api.tl:6178-6236`, the ones that matter for documents, links, photos, video:

```
//@description Returns only document messages
searchMessagesFilterDocument = SearchMessagesFilter;          // :6191

//@description Returns only messages containing URLs
searchMessagesFilterUrl = SearchMessagesFilter;               // :6209

//@description Returns only photo messages
searchMessagesFilterPhoto = SearchMessagesFilter;             // :6194

//@description Returns only video messages
searchMessagesFilterVideo = SearchMessagesFilter;             // :6200

//@description Returns only photo and video messages
searchMessagesFilterPhotoAndVideo = SearchMessagesFilter;     // :6206
```

Full enumeration (20 variants), for completeness: `Empty`, `Animation`, `Audio`, `Document`,
`Photo`, `Poll`, `Video`, `VoiceNote`, `PhotoAndVideo`, `Url`, `ChatPhoto`, `VideoNote`,
`VoiceAndVideoNote`, `Mention`, `UnreadMention`, `UnreadReaction`, `UnreadPollVote`,
`FailedToSend`, `Pinned`.

`searchMessagesFilterUrl` is the interesting one for a knowledge base — "Returns only messages
containing URLs" is a **server-side** link filter, so it can enumerate every link-bearing post
in a channel without downloading the whole history. Note it is **not** a way to search *for* a
particular URL, only to restrict to messages that have one.

Restrictions to remember: `Mention`, `UnreadMention`, `UnreadReaction`, `UnreadPollVote`,
`FailedToSend`, `Pinned` are unsupported in global `searchMessages` (`td_api.tl:11733-11734`);
`Empty`, `Mention`, `UnreadMention`, `UnreadReaction`, `UnreadPollVote` are unsupported in
`getChatSparseMessagePositions` (`td_api.tl:11837-11838`); and the four "unread" filters
"can't be additionally filtered by a query or by the sending user" per their own descriptions.

---

## PRIORITY 5 — threading contract — **VERIFIED** (quoted from `td/telegram/td_json_client.h`)

**Verdict:** exactly **one** thread may call `td_receive`; **any** thread may call `td_send`;
and you never free a modern client explicitly — you `close` it and wait for
`authorizationStateClosed`. In Swift terms: one dedicated receive `Thread` (or a detached
`Task` on its own executor) feeding an `AsyncStream`, and `td_send` callable from anywhere.

### The documented contract, verbatim

`td_json_client.h:26-34` (the modern `client_id` interface):

```
 * A TDLib client instance can be created through td_create_client_id.
 * Requests can be sent using td_send and the received client identifier.
 * New updates and responses to requests can be received through td_receive from any thread after the first request
 * has been sent to the client instance. This function must not be called simultaneously from two different threads.
 * Also, note that all updates and responses to requests must be applied in the order they were received for consistency.
 * Some TDLib requests can be executed synchronously from any thread using td_execute.
 * TDLib client instances are destroyed automatically after they are closed.
 * All TDLib client instances must be closed before application termination to ensure data consistency.
```

Per-function, `td_json_client.h:57-84`:

```
/**
 * Returns an opaque identifier of a new TDLib instance.
 * The TDLib instance will not send updates until the first request is sent to it.
 */
TDJSON_EXPORT int td_create_client_id();

/**
 * Sends request to the TDLib client. May be called from any thread.
 */
TDJSON_EXPORT void td_send(int client_id, const char *request);

/**
 * Receives incoming updates and request responses. Must not be called simultaneously from two different threads.
 * The returned pointer can be used until the next call to td_receive or td_execute, after which it will be deallocated by TDLib.
 */
TDJSON_EXPORT const char *td_receive(double timeout);

/**
 * Synchronously executes a TDLib request.
 * A request can be executed synchronously, only if it is documented with "Can be called synchronously".
 */
TDJSON_EXPORT const char *td_execute(const char *request);
```

### Answering the three questions exactly

1. **How many threads may call `td_receive`?** Effectively **one at a time** — "Must not be
   called simultaneously from two different threads." The legacy interface adds the stronger
   recommendation (`td_json_client.h:119-121`): *"Given this information, it's advisable to
   call this function from a dedicated thread."* Note `td_receive` in the modern interface is
   **global, not per-client** — it takes no `client_id` and returns objects tagged with an
   `@client_id` field (`td_json_client.h:24-25`). So even with several clients there is still
   exactly one receive loop.

2. **Is `td_send` thread-safe?** **Yes** — "May be called from any thread", stated for both
   `td_send` and legacy `td_json_client_send`.

3. **How is a client destroyed cleanly?** For the modern interface: **you don't free it.**
   `td_json_client.h:32-34`: *"TDLib client instances are destroyed automatically after they
   are closed. All TDLib client instances must be closed before application termination to
   ensure data consistency."* The sequence is: send `close`, keep pumping `td_receive` until
   `updateAuthorizationState` carries `authorizationStateClosed`, then stop the loop.
   `td_api.tl` on `close`:
   ```
   //@description Closes the TDLib instance. All databases will be flushed to disk and properly closed. After the close completes, updateAuthorizationState with authorizationStateClosed will be sent. Can be called before initialization
   close = Ok;
   ```
   and the two terminal states (`td_api.tl:246-251`):
   ```
   //@description TDLib is closing, all subsequent queries will be answered with the error 500. Note that closing TDLib can take a while. All resources will be freed only after authorizationStateClosed has been received
   authorizationStateClosing = AuthorizationState;

   //@description TDLib client is in its final state. All databases are closed and all resources are released. No other updates will be received after this. All queries will be responded to
   //-with error code 500. To continue working, one must create a new instance of the TDLib client
   authorizationStateClosed = AuthorizationState;
   ```
   The legacy interface still has explicit `td_json_client_destroy(void *client)`, which the
   header marks as being removed in TDLib 2.0.0 (`td_json_client.h:107-108`). **Use the
   `client_id` interface.**

### Two footguns worth writing into our wrapper

- **The returned `const char *` is borrowed, not owned.** "The returned pointer can be used
  until the next call to `td_receive` or `td_execute`, after which it will be deallocated by
  TDLib." In Swift, copy it into a `String`/`Data` **before** the next loop iteration. Never
  hand the raw pointer across an `await` boundary.
- **A fresh client is silent until poked.** "The TDLib instance will not send updates until the
  first request is sent to it" (`td_json_client.h:59`). A receive loop started before the first
  `td_send` will just time out forever, which reads like a hang. Send `getOption`/
  `setTdlibParameters` first.
- **Ordering is part of the contract**, not an optimisation: "all updates and responses to
  requests must be applied in the order they were received for consistency." So the receive
  loop must not fan out into concurrent handlers that can commit out of order. A serial
  consumer (single actor) on our side is required, not merely convenient.

---

## Aside — does TDLib corroborate "word / word-prefix only" search?

The caller settled this empirically against the `t.me/s/` preview; this is a passing note, not
a re-derivation. **TDLib's schema language is consistent with it**, in two places:

`td_api.tl:11712` describes per-chat search as matching *words*, not substrings:

```
//@description Searches for messages with given words in the chat.
```

and the one place TDLib exposes its own matching primitive names the semantics outright —
`td_api.tl:15942`:

```
//@description Searches specified query by word prefixes in the provided strings. Returns 0-based positions of strings that matched. Can be called synchronously
searchStringsByPrefix strings:vector<string> query:string limit:int32 return_none_for_empty_query:Bool = FoundPositions;
```

That is TDLib's *local* string matcher (used for chat/contact filtering), so it is only
suggestive about the server's message index — but it is the same "word prefix" model, and
nothing in the schema hints at substring or fuzzy matching anywhere. **Consistent with the
caller's finding; adds no independent evidence about the server.**

**What this means for us:** the FTS5 index is not a convenience, it is the product. Anything
we want beyond word-prefix — substring, fuzzy, ranked, cross-channel, date-ranged per channel
(Priority 2), reaction-thresholded (Priority 3) — exists only in our SQLite layer. Neither
ingestion source can serve those queries.

---

## Consolidated verdict table

| Question | Answer | Confidence |
|---|---|---|
| Message id transform | `<< 20` / `>> 20` | **Verified**, `MessageId.h:60`, `MessageId.cpp:175` |
| Channel chat id transform | `-1000000000000 - channel_id`, involution | **Verified**, `DialogId.cpp:84`, `:58` |
| `searchChatMessages` lacks date filter | **Confirmed** | **Verified**, `td_api.tl:11724` |
| `searchMessages` has `min_date`/`max_date` | **Confirmed** | **Verified**, `td_api.tl:11737` |
| `getChatMessageByDate` is the sanctioned per-chat date seek | **Confirmed**, returns one message | **Verified**, `td_api.tl:11821-11824` |
| No reaction search outside Saved Messages tags | **Confirmed**, Premium-gated | **Verified**, `td_api.tl:11747-11757`, `:8030` |
| `updateMessageReactions` needed for our sync | **No — it is bots-only.** Use `updateMessageInteractionInfo` | **Verified**, `td_api.tl:11102`, `:10332` |
| `getChatHistory` short reads / must loop | **Confirmed**, cap 100, terminate on empty | **Verified**, `MessagesManager.h:1656` |
| "First call returns nothing" | **Only for `only_local=true`.** `only_local=false` gets 4 internal tries | **Verified**, `Requests.cpp:977`, `RequestActor.h:139` |
| `getChatHistory` usable by bots | **No** — `CHECK_IS_USER()` | **Verified**, `Requests.cpp:3617` |
| `getMessageLink` private form | `t.me/c/<bare_channel_id>/<server_msg_id>`, `is_public=false` | **Verified**, `MessagesManager.cpp:15675-15685` |
| TDLib auto-retries FLOOD_WAIT | **Yes**, under a 60 s cumulative default budget | **Verified**, `NetQueryDelayer.cpp:34-106`, `NetQuery.h:315` |
| Flood error shape at the API | `{"code":429,"message":"Too Many Requests: retry after N"}` | **Verified**, `NetQueryDelayer.cpp:105`, `td_api.tl:18` |
| `use_message_database` required for `searchChatMessages` | **Confirmed** | **Verified**, `td_api.tl:11712` |
| One receive thread, `td_send` from any thread | **Confirmed** | **Verified**, `td_json_client.h:29`, `:64-71` |
| Clean shutdown = `close` then await `authorizationStateClosed` | **Confirmed**, no explicit destroy | **Verified**, `td_json_client.h:32-34`, `td_api.tl:251` |

---

## Unverified / open

These are the things I could not close with a quoted primary source. Each says why.

1. **Exact TDLib commit SHA.** *Unverified — could not probe.* The GitHub REST API returned
   `API rate limit exceeded for 185.185.51.207` on an unauthenticated request, and
   `raw.githubusercontent.com/.../master/...` does not report the SHA it served. Every file
   fetched carries a `2014-2026` copyright header, so this is master as of **2026-08-23**.
   *Fix before relying on line numbers:* clone and record `git rev-parse HEAD`, or re-run with
   `GITHUB_TOKEN` set. Line numbers in this document will drift; the quoted text will not.

2. **Migrated supergroups and monoforums — RESOLVED, moved to Verified.** I flagged this as
   open, then closed it from source. There are exactly **two** code paths in all of
   `DialogId.cpp` that produce a `DialogType::Channel` identifier, and both use the same
   expression: the `ChannelId` constructor (`DialogId.cpp:84`, `id = ZERO_CHANNEL_ID -
   channel_id.get();`) and `get_peer_id` for `peerChannel` (`DialogId.cpp:153`, `return
   ZERO_CHANNEL_ID - channel_id.get();`). `DialogId.h:41-46` shows the complete constructor
   set, and there is no channel-specific escape hatch beyond the raw `explicit constexpr
   DialogId(int64)`. **Therefore the formula is unconditional for any chat TDLib classifies as
   `DialogType::Channel`** — a basic group that migrated to a supergroup simply acquires a new
   `ChannelId` and goes through the same constructor. No special case exists to break the round
   trip.

3. **Monoforum channels — the reason the formula must be arithmetic.** `ChannelId.h:25-26`
   defines `MIN_MONOFORUM_CHANNEL_ID = 1000000000000 + (1 << 31) + 1` and
   `MAX_MONOFORUM_CHANNEL_ID = 3000000000000`, and `DialogId.cpp:37-39` maps that range to
   `DialogType::Channel` as well:
   ```cpp
       if (ZERO_CHANNEL_ID - ChannelId::MAX_MONOFORUM_CHANNEL_ID <= id) {
         return DialogType::Channel;
       }
   ```
   Those chat ids fall **below** `-2000000000000`, i.e. entirely outside the familiar `-100…`
   textual pattern, while still satisfying `ZERO_CHANNEL_ID - channel_id`. **This is the
   concrete case that a string-concatenation implementation of the `-100` prefix would get
   wrong.** What a monoforum is in product terms, and whether one can appear behind a
   `t.me/s/` preview, is *unverified and out of scope* — but our arithmetic handles it either
   way.

4. **Reaction-count staleness window.** I asserted that TDLib only emits
   `updateMessageInteractionInfo` for actively-tracked messages, so counts on old posts drift.
   That is an inference from how the update is worded plus general TDLib behaviour — **I did
   not find a source line stating the tracking policy.** *Unverified.* Practical consequence
   is unchanged (we need a periodic re-fetch for counts), but do not quote me on the mechanism.

5. **Whether `t.me/s/<channel>` exposes reaction counts at all.** Out of scope for this pass —
   this document covers TDLib. Needs a separate probe of the preview HTML. If it does not, then
   reactions are a **TDLib-only column** and the two-source merge is asymmetric: web rows would
   carry text + view count, TDLib rows would additionally carry reactions. Worth settling
   before the schema is frozen.

6. **Actual disk cost of `use_message_database`.** The schema documents *what* it enables, not
   *how much* it costs. *Unverified — no source gives a figure.* Measure on a real channel
   before deciding whether to keep TDLib's DB after backfill.

7. **`FLOOD_PREMIUM_WAIT_` / `SLOWMODE_WAIT_` incidence.** `NetQueryDelayer.cpp:36-37` shows
   these share the `429` surface with plain `FLOOD_WAIT_`, so a `429` is ambiguous at the
   td_api boundary. Whether a read-only channel crawler can ever trigger the non-`FLOOD_WAIT_`
   variants is *unverified*. Log the full message string so we can tell them apart in practice.

8. **Per-account rate limits for channel history crawling.** No numbers exist in the source —
   they are server-side and undocumented. *Unverified — cannot be probed from source.* The only
   sound approach is adaptive: honour `retry after N`, and back off further on repeats.

---

## Cross-check against the official docs (`core.telegram.org/tdlib/docs`)

Two independent confirmations, fetched 2026-08-23, agreeing with the schema in every particular.

**`searchChatMessages`** —
`https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1search_chat_messages.html`
lists exactly eight fields: `chat_id_`, `topic_id_`, `query_`, `sender_id_`,
`from_message_id_`, `offset_`, `limit_`, `filter_`. **No `min_date_` or `max_date_`.** The
rendered class description matches `td_api.tl:11712-11714` word for word, including the
message-database prerequisite. Priority 2 is confirmed by two independent sources.

**`td_json_client.h`** — `https://core.telegram.org/tdlib/docs/td__json__client_8h.html`
renders the same three sentences quoted in Priority 5: `td_receive` "Must not be called
simultaneously from two different threads"; `td_send` "May be called from any thread";
"TDLib client instances are destroyed automatically after they are closed." Priority 5
confirmed by two independent sources.

---

## Second opinion — DeepWiki (deep mode) on `tdlib/td`

Share link:
`https://deepwiki.com/search/three-specific-corroboration-q_0f3d9de3-b1d7-47fd-ab9d-66dd76497ab3?mode=deep`
query_id: `three-specific-corroboration-q_0f3d9de3-b1d7-47fd-ab9d-66dd76497ab3`

**Staleness warning, relayed as received:** *"tdlib/td wiki-index pinned at e0943d06
(2026-05-18 — 97 days old, 511 commits behind HEAD). Deep mode partially reads beyond the
index."* Everything below is therefore corroboration only — the primary quotations earlier in
this document, taken from master on 2026-08-23, remain authoritative where they differ.

**Agreement on all three questions asked.** DeepWiki independently cited
`MessageId.h:26-29`/`58-60`, `MessageId.cpp:172-175`, `DialogId.h:25-26`,
`DialogId.cpp:82-88`/`56-59`, `Requests.cpp:935-966`, `RequestActor.h:31-64`,
`NetQueryDelayer.cpp:21-46`/`99-107`, and `NetQuery.h:312-315` — the same lines quoted above,
reached independently. It confirmed:
- `chat_id = -1000000000000 - channel_id` "matching your formula exactly";
- the `<< 20` shift, and that it "holds uniformly for every dialog type … there is nothing
  channel-specific in the encoding";
- that the `getChatHistory` retry happens **inside a single logical request**, so *"the
  commonly cited 'must call twice' behavior is not accurate for a single request/response
  pair"*, and that the folklore most likely originates in the `only_local = true` path;
- the flood-wait budget and the exact `429 / "Too Many Requests: retry after <timeout>"`
  surface, adding that a *malformed* flood-wait variant (extra `_` after the number) is
  converted straight to a `400` **without** retrying — which matches
  `NetQueryDelayer.cpp:38-44` quoted above.

**One genuinely new caveat it surfaced, which I then verified myself:**

> **Migrated basic-group → supergroup chats do not have continuous message numbering.**
> The formulas hold, but the *lineage* does not: old messages live in the old `ChatId` dialog
> (`chat_id = -chat_id`) and new ones in the new `ChannelId` dialog. The link between them is
> carried as separate bookkeeping fields.

Verified at the API surface — `td_api.tl:2772-2774`:

```
//@upgraded_from_basic_group_id Identifier of the basic group from which supergroup was upgraded; 0 if none
//@upgraded_from_max_message_id Identifier of the last message in the basic group from which supergroup was upgraded; 0 if none
supergroupFullInfo ... upgraded_from_basic_group_id:int53 upgraded_from_max_message_id:int53 = SupergroupFullInfo;
```

(DeepWiki used the internal C++ names `migrated_from_*`; the public td_api names are
`upgraded_from_*`. Same thing.)

**Impact on us: low, but worth a line in the schema.** We ingest public broadcast channels,
which are `DialogType::Channel` from birth and never migrated. But if we ever index a
*discussion supergroup* that was upgraded from a basic group, its pre-upgrade history is a
different `chat_id` entirely, and message numbers before `upgraded_from_max_message_id` are not
comparable to those after. Do **not** assume `(chat_id, message_id)` ordering is a single
monotonic timeline for supergroups. Two more DeepWiki notes in the same vein:
- Monoforum dialogs tag messages with a `SavedMessagesTopicId` that is **not** encoded in the
  message id — topic disambiguation must come from other API surfaces, not from decoding ids.
- The shift formula applies only to `is_server()` ids; local/yet-unsent/scheduled/sponsored ids
  use different bit layouts and "would give nonsense if you blindly shift them". This is the
  `& 0xFFFFF == 0` guard already specified in Priority 1.

**One thing DeepWiki could not resolve, and I did.** It reported it *"could not fully verify …
the exact internal branching inside `MessagesManager::get_dialog_history` / `load_messages_impl`"*
because its index held only the declarations. That body is quoted in Priority 4a above, read
directly from `MessagesManager.cpp:17530-17593` on master. Its speculation that some of the 4
tries are consumed by PTS/channel-difference reconciliation is plausible but **unverified** —
the body shows the retry is driven by `message_ids.empty()` plus a `load_messages` round trip,
which is consistent with, but not proof of, that explanation.

