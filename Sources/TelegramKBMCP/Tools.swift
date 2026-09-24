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
        name: "search_posts",
        title: "Search Telegram posts",
        description: """
            Full-text search over the indexed Telegram archive. Returns compact records — \
            channel, date, author, snippet, reaction count, and a t.me link — never full post \
            bodies; follow up with get_post for one post's full text. Pass next_cursor back as \
            `cursor` to continue a result list; `total` reports every match before truncation. \
            `mode`: "words" matches folded/lemmatised words, "substring" matches inside words \
            (min 3 chars), "both" (default) is word hits then substring-only hits.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "query": .object([
                    "type": "string",
                    "description": "Search terms; quote a run of words to require that order."
                ]),
                "channel": .object([
                    "type": "string",
                    "description": "Restrict to one channel — the @username literal records emit."
                ]),
                "kind": .object([
                    "type": "string",
                    "enum": .array(postKinds.map { .string($0) })
                ]),
                // No `format: date-time` — a validating client would refuse the YYYY-MM-DD
                // spelling the decoder accepts.
                "from": .object(["type": "string",
                                 "description": "Oldest post date, inclusive; ISO-8601 or YYYY-MM-DD."]),
                "to": .object(["type": "string",
                               "description": "Newest post date, inclusive; ISO-8601 or YYYY-MM-DD."]),
                "mode": .object(["type": "string", "enum": ["words", "substring", "both"],
                                 "default": "both"]),
                "limit": .object(["type": "integer", "default": .int(defaultLimit),
                                  "minimum": 0, "maximum": .int(maxLimit),
                                  "description": "Page size; values above the maximum are clamped."]),
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
        name: "find_links",
        title: "Find posts by linked URL",
        description: """
            Which posts shared a URL. Matches on the link's effective URL — its canonical form, \
            or what it resolved to — so a shortener (clck.ru, bit.ly) query finds the \
            destination's posts and a destination query finds every spelling that resolved to \
            it. Each record returns url_canonical (the join key) with the resolved target beside \
            it, plus the post's t.me link. Pass next_cursor back as `cursor` to continue a \
            result list; `total` reports every match before truncation.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "url": .object(["type": "string",
                                "description": "Any spelling — raw, canonical, or shortener."]),
                "limit": .object(["type": "integer", "default": .int(defaultLimit),
                                  "minimum": 0, "maximum": .int(maxLimit),
                                  "description": "Page size; values above the maximum are clamped."]),
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
        name: "get_post",
        title: "Fetch one post",
        description: """
            The full record for one post: complete text, reactions, links with previews, poll, \
            forward origin, views, hashtags. Accepts the `@channel/id` literal that search_posts \
            and find_links emit, or its https://t.me/channel/id form.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "post": .object([
                    "type": "string",
                    "description": "@channel/id or https://t.me/channel/id"]),
            ]),
            "required": ["post"],
            "additionalProperties": false,
        ]),
        annotations: annotations,
        outputSchema: .object(["type": "object"]))
}
