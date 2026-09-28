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

    /// ASCII letters, digits and underscores — the only characters a `t.me/<name>` path segment
    /// can carry. Anything else (`/`, `?`, a space) either crashes `URL(string:)` or lands the
    /// request on a different page than the name suggests, while the posts are still stored
    /// under the name as given (PR #3, review round 2).
    public static func isUsername(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// A string that cannot be a `t.me` path segment — see ``isUsername(_:)``.
    public struct InvalidUsername: Error, Equatable, CustomStringConvertible {
        public var name: String
        public init(name: String) { self.name = name }
        public var description: String {
            "\(name) is not a Telegram username — only letters, digits and _ are allowed"
        }
    }

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
