import Foundation
import GRDB
import TelegramKBModel

extension Store {

    /// Narrows a search to part of the corpus. Every field is optional and they AND together.
    ///
    /// These live in `post`, not in either FTS table, so a filtered search joins the two. That
    /// join is on the **page and the count alike** — a `total` that counted unfiltered matches
    /// would promise results the page can never return, which is the failure `total` exists to
    /// prevent.
    public struct SearchFilter: Equatable, Sendable {
        /// Channel username, without the `@`. Compared lowercased, as everything else here is.
        public var channel: String?
        public var kind: PostKind?
        /// Inclusive bounds on the post's own date, not on when it was crawled.
        public var from: Date?
        public var to: Date?

        public init(channel: String? = nil, kind: PostKind? = nil, from: Date? = nil, to: Date? = nil) {
            self.channel = channel.map { $0.lowercased() }
            self.kind = kind
            self.from = from
            self.to = to
        }

        public var isEmpty: Bool { channel == nil && kind == nil && from == nil && to == nil }

        /// `(join, where, arguments)` — empty strings when nothing is filtered, so an unfiltered
        /// search runs exactly the SQL it ran before this existed.
        func sql() -> (join: String, condition: String, arguments: [any DatabaseValueConvertible]) {
            guard !isEmpty else { return ("", "", []) }
            var conditions: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            if let channel { conditions.append("p.channelUsername = ?"); arguments.append(channel) }
            if let kind { conditions.append("p.kind = ?"); arguments.append(kind.rawValue) }
            if let from { conditions.append("p.date >= ?"); arguments.append(from) }
            if let to { conditions.append("p.date <= ?"); arguments.append(to) }
            let join = """
                JOIN post p ON p.channelUsername = m.channelUsername AND p.messageID = m.messageID
                """
            return (join, " AND " + conditions.joined(separator: " AND "), arguments)
        }
    }

    /// Where a page of results stopped, as an opaque string.
    ///
    /// **It encodes an offset, deliberately, and says so here rather than pretending otherwise.**
    /// Keyset pagination — "everything after this key" — needs a stable total order, and there is
    /// none across two independently ranked FTS indexes: `bm25` is computed per index and the two
    /// scales are not comparable (Design § *Combining the two indexes*). An offset into the merged
    /// sequence is honest and cheap; its cost is that results can shift if the index changes
    /// between pages, which for a corpus synced a few times a day is a fair trade.
    ///
    /// The fingerprint binds a cursor to the query and filter that produced it, so a cursor from
    /// one search cannot silently page through another.
    enum Cursor {
        static func encode(offset: Int, fingerprint: UInt64) -> String {
            Data("1:\(offset):\(fingerprint)".utf8).base64EncodedString()
        }

        static func decode(_ text: String) -> (offset: Int, fingerprint: UInt64)? {
            guard let data = Data(base64Encoded: text),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            let parts = decoded.split(separator: ":")
            guard parts.count == 3, parts[0] == "1",
                  let offset = Int(parts[1]), offset >= 0,
                  let fingerprint = UInt64(parts[2]) else { return nil }
            return (offset, fingerprint)
        }

        /// FNV-1a over what the page depends on. Not a security boundary — it catches a cursor
        /// used against a different query, which is a caller mistake, not an attack.
        static func fingerprint(query: String, mode: SearchMode, filter: SearchFilter) -> UInt64 {
            let material = [query, mode.rawValue, filter.channel ?? "", filter.kind?.rawValue ?? "",
                            filter.from.map { "\($0.timeIntervalSince1970)" } ?? "",
                            filter.to.map { "\($0.timeIntervalSince1970)" } ?? ""].joined(separator: "\u{1}")
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in material.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
            return hash
        }
    }

    public enum SearchError: Error, CustomStringConvertible, Equatable {
        /// The cursor was not produced by this query and filter — paging on with it would return
        /// a slice of a different result set while looking like a continuation.
        case cursorDoesNotMatchQuery
        case cursorMalformed

        public var description: String {
            switch self {
            case .cursorDoesNotMatchQuery:
                "This cursor belongs to a different query or filter. Start again without a cursor."
            case .cursorMalformed:
                "This cursor is not one of ours. Start again without a cursor."
            }
        }
    }
}
