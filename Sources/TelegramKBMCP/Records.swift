import Foundation
import TelegramKBModel
import TelegramKBStore

/// The records the tools emit into `structuredContent`.
///
/// Two rules from <doc:Design> § *MCP tool surface* shape everything here:
///
/// - **Compact records.** Search results carry `(channel, date, author, snippet, reactions,
///   link)` — never full bodies. Full text comes from a follow-up `get_post`; a result list
///   that dumps whole posts wastes the context window the tool exists to protect.
/// - **Every record carries a `t.me` permalink.** Citation is the whole point of retrieval
///   here. Of seven Telegram MCP servers surveyed, not one emitted a link its output could
///   be cited by.
///
/// Peer addressing is one round-trippable string: the `post` field emits exactly the
/// `@channel/id` literal that ``get_post`` accepts, so a model never has to compose an
/// id/hash/type triple.

/// A post as a search hit — the compact form.
struct PostSummary: Codable, Sendable, Equatable {
    /// `@channel/id` — the literal ``get_post`` takes.
    var post: String
    var channel: String
    /// ISO-8601, UTC-rendered — the post's own date, not the crawl's.
    var date: String
    var author: String?
    var kind: String
    /// First ~140 chars, newlines flattened. A media-only post's snippet falls back to its
    /// poll question, matching `tgkb query`'s rendering.
    var snippet: String
    /// Total reaction count across all emojis.
    var reactions: Int
    /// `https://t.me/channel/id` — citable.
    var link: String

    init(_ post: Post) {
        self.post = "@\(post.id.channelUsername)/\(post.id.messageID)"
        self.channel = post.id.channelUsername
        self.date = post.date.formatted(.iso8601)
        self.author = post.authorName
        self.kind = post.kind.rawValue
        self.snippet = Self.snippet(post.text.isEmpty ? (post.poll?.question ?? "") : post.text)
        self.reactions = post.totalReactions
        self.link = post.permalink
    }

    /// The same truncation `tgkb query` applies, so CLI and MCP render identically.
    static func snippet(_ text: String, limit: Int = 140) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}

struct SearchPostsOutput: Codable, Sendable, Equatable {
    var posts: [PostSummary]
    /// Every match, before truncation — `posts.count < total` means more exist.
    var total: Int
    /// Pass back as `cursor` to continue; absent when there is nothing after this page.
    var next_cursor: String?
    /// The corpus changed between pages — a post may have been skipped or repeated.
    var index_moved_since_cursor: Bool
}

/// A post that carried a URL — `find_links`' record.
struct LinkHitRecord: Codable, Sendable, Equatable {
    var post: String
    var channel: String
    var date: String
    /// The URL exactly as it appeared — never rewritten.
    var url_raw: String
    /// The join key `artanl` shares; `null` when the raw spelling is not canonicalisable.
    var url_canonical: String?
    /// Where the link actually leads — the recorded resolution, else the canonical form.
    var resolved_url: String?
    var snippet: String
    var link: String
}

struct FindLinksOutput: Codable, Sendable, Equatable {
    var links: [LinkHitRecord]
    var total: Int
}

/// The full post — `get_post`'s record. Everything the store knows, unabridged.
struct PostDetail: Codable, Sendable, Equatable {
    struct ReactionRecord: Codable, Sendable, Equatable {
        var emoji: String?
        var count: Int
        var is_paid: Bool
    }
    struct LinkRecord: Codable, Sendable, Equatable {
        var url_raw: String
        var url_canonical: String?
        /// Telegram's own preview of the link — a snapshot it took, not a live read.
        struct Preview: Codable, Sendable, Equatable {
            var site_name: String?
            var title: String?
            var description: String?
            var resolved_url: String?
            var observed_at: String
        }
        var preview: Preview?
    }
    struct PollRecord: Codable, Sendable, Equatable {
        var question: String
        var options: [String]
        var total_votes: Int?
    }
    struct ForwardRecord: Codable, Sendable, Equatable {
        var channel: String?
        /// `@channel/id` when both halves are known.
        var post: String?
        var author: String?
    }
    struct ViewsRecord: Codable, Sendable, Equatable {
        var value: Int
        /// The web preview renders "1.4K" — never compare as exact against a TDLib count.
        var is_approximate: Bool
    }

    var post: String
    var channel: String
    var message_id: Int
    var link: String
    var date: String
    var author: String?
    var kind: String
    var media_count: Int
    /// `web` | `export` | `tdlib` — what the source could express, so "not a document" is
    /// distinguishable from "this source cannot say".
    var format_source: String
    var text: String
    var is_edited: Bool
    var reply_to: Int?
    var forward: ForwardRecord?
    var hashtags: [String]
    var links: [LinkRecord]
    var reactions: [ReactionRecord]
    var poll: PollRecord?
    var views: ViewsRecord?

    init(_ p: Post) {
        post = "@\(p.id.channelUsername)/\(p.id.messageID)"
        channel = p.id.channelUsername
        message_id = p.id.messageID
        link = p.permalink
        date = p.date.formatted(.iso8601)
        author = p.authorName
        kind = p.kind.rawValue
        media_count = p.mediaCount
        format_source = p.formatSource.rawValue
        text = p.text
        is_edited = p.isEdited
        reply_to = p.replyTo
        forward = p.forward.map { f in
            ForwardRecord(
                channel: f.channelUsername,
                post: f.channelUsername.flatMap { ch in
                    f.messageID.map { "@\(ch)/\($0)" }
                },
                author: f.authorName)
        }
        hashtags = p.hashtags
        links = p.links.map { l in
            LinkRecord(url_raw: l.urlRaw, url_canonical: l.urlCanonical,
                       preview: l.preview.map {
                           .init(site_name: $0.siteName, title: $0.title,
                                 description: $0.description, resolved_url: $0.resolvedURL,
                                 observed_at: $0.observedAt.formatted(.iso8601))
                       })
        }
        reactions = p.reactions.map { .init(emoji: $0.emoji, count: $0.count, is_paid: $0.isPaid) }
        poll = p.poll.map { .init(question: $0.question, options: $0.options,
                                  total_votes: $0.totalVotes) }
        views = p.views.map { .init(value: $0.value, is_approximate: $0.isApproximate) }
    }
}
