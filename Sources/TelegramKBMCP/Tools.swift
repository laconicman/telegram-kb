import Foundation
import MCP

/// The three tools `tgkb-mcp` exposes.
///
/// The SDK validates nothing against `inputSchema` — arguments arrive as `[String: Value]` and
/// are decoded by hand in ``ToolHandler``. The schemas are therefore documentation AND contract:
/// keep them honest, because a client composes calls against what they declare.
///
/// Annotations are set explicitly on every tool: the SDK defaults are `destructive: true` and
/// `openWorld: true`, and omitting them would have clients assume a read-only archive is both.
enum TGKBTools {

    /// Read-only, closed-world — the whole surface shares it.
    static let annotations = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false,
        idempotentHint: true, openWorldHint: false)

    /// A page a model can actually read — `Store.maxPageSize` is for programmatic callers.
    static let maxLimit = 100
    static let defaultLimit = 20

    /// `PostKind` is not `CaseIterable`; the enum list the schema declares and the decoder
    /// reports must be spelled out once, here, or the two will drift.
    static let postKinds = ["text", "photo", "album", "video", "videoNote", "audio", "voice",
                            "document", "poll", "sticker", "location", "giveaway", "unknown"]

    static let all: [Tool] = [searchPosts, findLinks, getPost]

    static let searchPosts = Tool(
        name: "tgkb_search_posts",
        title: "Search Telegram posts",
        description: """
            Search a local archive of Telegram channel and group posts. Matches post text, \
            link-preview titles and descriptions, poll questions and options, hashtags and author \
            names. Every word must appear — there are no AND/OR/NOT operators, so run one search \
            per alternative — and quoted words must appear in that order. Words match across case, \
            ё/е and, for Russian, inflection; nothing is translated, so search in the language the \
            posts are written in. Returns compact records — post, channel, date, author, kind, \
            snippet, reaction count and a citable t.me link — never full bodies: call \
            tgkb_get_post for a post's full text and its links. `total` counts every match; pass \
            next_cursor back as `cursor` for the next page. For the posts that shared one \
            particular URL, use tgkb_find_links.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "query": .object([
                    "type": "string",
                    "description": "Words that must all appear, e.g. `навигация SwiftUI`. Quote a run of words to require that order: `\"чистая архитектура\"`."
                ]),
                "channel": .object([
                    "type": "string",
                    "description": "Restrict to one channel or group: the `channel` value of a record, e.g. `somechannel`; a leading @ is accepted."
                ]),
                "kind": .object([
                    "type": "string",
                    "enum": .array(postKinds.map { .string($0) }),
                    "description": "Restrict to one kind of post, e.g. `poll` or `video`."
                ]),
                // No `format: date-time` — a validating client would refuse the YYYY-MM-DD
                // spelling the decoder accepts.
                "from": .object(["type": "string",
                                 "description": "Oldest post date, inclusive: ISO-8601 (`2024-03-01T09:30:00Z`), or YYYY-MM-DD for a whole UTC day."]),
                "to": .object(["type": "string",
                               "description": "Newest post date, inclusive: ISO-8601 (`2024-03-31T18:00:00Z`), or YYYY-MM-DD for a whole UTC day."]),
                "mode": .object(["type": "string", "enum": ["words", "substring", "both"],
                                 "default": "both",
                                 "description": "`words`: whole words, folded and lemmatised. `substring`: inside words, 3+ characters — `imation` finds Animation. `both`: word hits, then substring-only ones."]),
                // No `maximum`: the handler clamps a larger value, and a validating client would
                // refuse it before the clamp could run.
                "limit": .object(["type": "integer", "default": .int(defaultLimit), "minimum": 0,
                                  "description": "Page size, at most \(maxLimit); larger values are clamped."]),
                "cursor": .object(["type": "string",
                                   "description": "The previous page's next_cursor, verbatim."]),
            ]),
            "required": ["query"],
            "additionalProperties": false,
        ]),
        annotations: annotations,
        outputSchema: .object([
            "type": "object",
            "properties": .object([
                "posts": .object(["type": "array", "items": .object(["type": "object"])]),
                "total": .object(["type": "integer"]),
                "next_cursor": .object(["type": "string"]),
                "index_moved_since_cursor": .object(["type": "boolean"]),
            ]),
        ]))

    static let findLinks = Tool(
        name: "tgkb_find_links",
        title: "Find posts by linked URL",
        description: """
            The posts that shared one URL. Takes a whole link in any spelling and matches on \
            where it leads — its canonical form, or what it resolved to — so a shortener \
            (clck.ru, bit.ly) finds the destination's posts, and a destination finds every \
            spelling that resolved to it. A site or a word is not a link: `example.com` does not \
            find example.com's articles; to search by site or topic, use tgkb_search_posts, which \
            indexes link-preview titles. Each record: the post, its date, the URL as written \
            (url_raw), its canonical form (url_canonical, the join key), where it leads \
            (resolved_url), a snippet and the post's t.me link. `total` counts every match; pass \
            next_cursor back as `cursor` for the next page.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "url": .object(["type": "string",
                                "description": "A whole link, e.g. `https://example.com/blog/post-1` — raw, canonical, or a shortener."]),
                // No `maximum`: the handler clamps a larger value, and a validating client would
                // refuse it before the clamp could run.
                "limit": .object(["type": "integer", "default": .int(defaultLimit), "minimum": 0,
                                  "description": "Page size, at most \(maxLimit); larger values are clamped."]),
                "cursor": .object(["type": "string",
                                   "description": "The previous page's next_cursor, verbatim."]),
            ]),
            "required": ["url"],
            "additionalProperties": false,
        ]),
        annotations: annotations,
        outputSchema: .object([
            "type": "object",
            "properties": .object([
                "links": .object(["type": "array", "items": .object(["type": "object"])]),
                "total": .object(["type": "integer"]),
                "next_cursor": .object(["type": "string"]),
                "index_moved_since_cursor": .object(["type": "boolean"]),
            ]),
        ]))

    static let getPost = Tool(
        name: "tgkb_get_post",
        title: "Fetch one post",
        description: """
            The full record for one post: complete text, author, date, the links it carries with \
            Telegram's previews of them, reactions, poll, forward origin, views and hashtags. \
            Takes the `post` value of a tgkb_search_posts or tgkb_find_links record, or the \
            post's t.me link.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "post": .object([
                    "type": "string",
                    "description": "`@somechannel/123`, or `https://t.me/somechannel/123`."]),
            ]),
            "required": ["post"],
            "additionalProperties": false,
        ]),
        annotations: annotations,
        outputSchema: .object(["type": "object"]))
}
