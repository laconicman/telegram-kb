import Foundation

/// A Telegram channel we ingest from.
public struct Channel: Codable, Hashable, Sendable {
    /// The `@username` without the `@` — `"iosgr"`. Also the `t.me/<username>` path component.
    public var username: String

    /// The **bare** channel id, as it appears in the web preview's `data-view.c` payload
    /// (`1492664793`), always positive here.
    ///
    /// Stored bare rather than as a TDLib `chat_id` because the bare form is what both sources
    /// can produce; `tdlibChatID` derives the other. See `Design` § *Two sources, one row*.
    public var rawChannelID: Int64

    public var title: String?
    public var subscriberCount: Int?

    /// Whether this channel is reachable through the `t.me/s/` web preview.
    public var reachability: Reachability

    public init(username: String, rawChannelID: Int64, title: String? = nil,
                subscriberCount: Int? = nil, reachability: Reachability = .webPreview) {
        self.username = username
        self.rawChannelID = rawChannelID
        self.title = title
        self.subscriberCount = subscriberCount
        self.reachability = reachability
    }

    /// The TDLib `chat_id`: `ZERO_CHANNEL_ID - channel_id` (`DialogId.h:27`, `DialogId.cpp:84`).
    ///
    /// Computed **arithmetically, never by string concatenation** — monoforum channel ids reach
    /// 3×10¹² and produce chat ids outside the familiar `-100…` text pattern.
    public var tdlibChatID: Int64 { Self.zeroChannelID - rawChannelID }

    static let zeroChannelID: Int64 = -1_000_000_000_000

    /// The four-way classification `tgkb doctor` produces for a configured channel.
    ///
    /// The distinction matters because `t.me/s/<name>` returns the same 302 for all three
    /// unreachable cases; only the plain page tells them apart.
    public enum Reachability: String, Codable, Hashable, Sendable {
        /// `/s/` returns 200. Ingestible now, no auth.
        case webPreview
        /// A real broadcast channel ("N subscribers") whose preview is switched off. TDLib only.
        case previewDisabled
        /// A group or supergroup ("N members"), which has no `/s/` preview at all. TDLib only.
        case group
        /// Not publicly resolvable: private, deleted, or never existed.
        case unresolvable
    }
}
