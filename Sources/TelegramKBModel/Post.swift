import Foundation

/// One post in a channel — the unit a search result cites.
///
/// **An album is one post spanning several message ids.** The web preview renders a media group
/// as a single wrapper carrying one `data-post` id, and the ids it occupies never appear
/// separately (verified: `@ios_broadcast/581` spans 581–586). So ``messageID`` is the *first*
/// id and ``mediaCount`` records the span. Two consequences worth stating plainly:
///
/// - **A missing message id is not evidence of deletion.** It is usually an album.
/// - TDLib disagrees on the grain — it returns *N* messages sharing a `media_group_id`. Group
///   them before writing, not after (`TD-8`).
public struct Post: Codable, Hashable, Sendable, Identifiable {
    public struct ID: Codable, Hashable, Sendable {
        public var channelUsername: String
        /// First message id of the post. For an album, the lowest of its span.
        public var messageID: Int
        public init(channelUsername: String, messageID: Int) {
            self.channelUsername = channelUsername
            self.messageID = messageID
        }
    }

    public var id: ID
    public var date: Date
    public var kind: PostKind
    /// Which source supplied ``kind``. Never assume `kind` is meaningful when this is `.absent`.
    public var formatSource: FormatSource
    /// 1 for an ordinary post; >1 for an album, where it is the number of message ids consumed.
    public var mediaCount: Int

    /// Body text. Empty for media posts with no caption — 161 of 7,406 in the corpus, which are
    /// still worth indexing on date, author, reactions and link preview.
    public var text: String
    /// Channel signature author, where the channel signs posts.
    public var authorName: String?
    public var isEdited: Bool

    public var replyTo: Int?
    public var forward: ForwardOrigin?

    public var hashtags: [String]
    public var links: [LinkRef]
    public var reactions: [Reaction]
    public var poll: Poll?
    public var views: ViewCount?

    public init(id: ID, date: Date, kind: PostKind, formatSource: FormatSource,
                mediaCount: Int = 1, text: String = "", authorName: String? = nil,
                isEdited: Bool = false, replyTo: Int? = nil, forward: ForwardOrigin? = nil,
                hashtags: [String] = [], links: [LinkRef] = [], reactions: [Reaction] = [],
                poll: Poll? = nil, views: ViewCount? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.formatSource = formatSource
        self.mediaCount = mediaCount
        self.text = text
        self.authorName = authorName
        self.isEdited = isEdited
        self.replyTo = replyTo
        self.forward = forward
        self.hashtags = hashtags
        self.links = links
        self.reactions = reactions
        self.poll = poll
        self.views = views
    }

    /// `true` when this post is a media group occupying more than one message id.
    public var isAlbum: Bool { mediaCount > 1 }

    /// The message ids this post occupies — the span an album consumes.
    ///
    /// Use this, not `messageID`, when deciding whether an id is genuinely absent from a channel.
    public var messageIDSpan: ClosedRange<Int> {
        id.messageID...(id.messageID + max(0, mediaCount - 1))
    }

    /// Total reactions across all buckets. Dense enough to rank on: 164,747 across the corpus.
    public var totalReactions: Int { reactions.reduce(0) { $0 + $1.count } }

    /// The `t.me` permalink. Every search result carries one — of seven Telegram MCP servers
    /// surveyed, not one emits a citable link.
    public var permalink: String { "https://t.me/\(id.channelUsername)/\(id.messageID)" }
}

extension Post.ID {
    /// A post as a person or a tool names it: `@channel/id` — the literal search records emit —
    /// or the pasteable `channel/id`, `t.me/channel/id` and `https://t.me/channel/id`. The channel
    /// folds to lowercase, as the store keys it.
    ///
    /// One definition for both binaries, so `tgkb show` and `tgkb_get_post` accept exactly the
    /// same strings (`Design` § *One argument grammar for both binaries*).
    public init?(reference text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://t.me/", "http://t.me/", "t.me/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.hasPrefix("@") { s.removeFirst() }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        // `Channel.isUsername`, not merely non-empty: `@bad name/1` is a malformed reference, and
        // saying so tells the caller to fix the reference rather than that the post is missing.
        guard parts.count == 2, let id = Int(parts[1]), id > 0, Channel.isUsername(String(parts[0]))
        else { return nil }
        self.init(channelUsername: parts[0].lowercased(), messageID: id)
    }
}

/// A view count, which the web preview renders **abbreviated and lossy** ("1.4K", "1.67K").
///
/// The flag exists so a web-sourced approximation is never silently compared against an exact
/// TDLib count (`TD-7`).
public struct ViewCount: Codable, Hashable, Sendable {
    public var value: Int
    public var isApproximate: Bool
    public init(value: Int, isApproximate: Bool) {
        self.value = value
        self.isApproximate = isApproximate
    }
}
