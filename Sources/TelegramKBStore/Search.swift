import Foundation
import GRDB
import TelegramKBModel

extension Store {

    /// A search hit: which post, and how well it scored. Lower `rank` is better (`bm25`).
    public struct Hit: Sendable, Hashable {
        public var id: Post.ID
        public var rank: Double
    }

    /// Word search over the `unicode61` index, which holds folded surface text **and** lemmas.
    ///
    /// The query is normalised the same way the index was — folded, then lemmatised — so an
    /// inflected query matches an inflected post in either direction. Skipping either step makes
    /// recall *worse* than Telegram's own search on Russian, which is the whole of `TD-4`.
    public func searchWords(_ query: String, limit: Int = 50) throws -> [Hit] {
        let folded = TextNormalizer.normalizeQuery(query)
        let terms = TextNormalizer.lemmas(folded) ?? folded
        return try dbPool.read { db in
            // Failable, not throwing, and it discards FTS5 operator characters — the sanctioned
            // path for text arriving straight from an LLM tool call (`research/grdb-fts5.md`).
            guard let pattern = try? FTS5Pattern(matchingAllTokensIn: terms) else { return [] }
            return try Hit.fetchAll(db, sql: """
                SELECT m.channelUsername AS cu, m.messageID AS mid, bm25(postFTS) AS rank
                FROM postFTS JOIN ftsMap m ON m.rowid = postFTS.rowid
                WHERE postFTS MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [pattern, limit])
        }
    }

    /// Substring search over the `trigram` index — the thing Telegram's search cannot do at all
    /// (`imation` returns 0 there, 14 here).
    public func searchSubstring(_ query: String, limit: Int = 50) throws -> [Hit] {
        let folded = TextNormalizer.normalizeQuery(query)
        guard folded.count >= 3 else { return [] }   // trigram needs three characters
        return try dbPool.read { db in
            return try Hit.fetchAll(db, sql: """
                SELECT m.channelUsername AS cu, m.messageID AS mid, bm25(postTrigram) AS rank
                FROM postTrigram JOIN ftsMap m ON m.rowid = postTrigram.rowid
                WHERE postTrigram MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [FTS5Pattern(matchingPhrase: folded), limit])
        }
    }

    public func post(_ id: Post.ID) throws -> Post? {
        try dbPool.read { db in try Self.loadPost(id, from: db) }
    }

    /// The join key for a link: its resolution when known, else its canonical form.
    public func effectiveURL(forCanonical urlCanonical: String) throws -> String {
        try dbPool.read { db in
            let resolved = try String.fetchOne(db,
                sql: "SELECT resolvedCanonical FROM urlResolution WHERE urlCanonical = ?",
                arguments: [urlCanonical])
            return resolved ?? urlCanonical
        }
    }
}

extension Store.Hit: FetchableRecord {
    public init(row: Row) {
        self.init(id: Post.ID(channelUsername: row["cu"], messageID: row["mid"]),
                  rank: row["rank"] ?? 0)
    }
}

extension Store {
    static func loadPost(_ id: Post.ID, from db: Database) throws -> Post? {
        guard let row = try Row.fetchOne(db,
            sql: "SELECT * FROM post WHERE channelUsername = ? AND messageID = ?",
            arguments: [id.channelUsername, id.messageID]) else { return nil }

        let reactions = try Row.fetchAll(db,
            sql: "SELECT emoji, count, isPaid FROM reaction WHERE channelUsername = ? AND messageID = ?",
            arguments: [id.channelUsername, id.messageID]
        ).map { Reaction(emoji: $0["emoji"], count: $0["count"], isPaid: $0["isPaid"]) }

        let tags = try String.fetchAll(db,
            sql: "SELECT tag FROM hashtag WHERE channelUsername = ? AND messageID = ?",
            arguments: [id.channelUsername, id.messageID])

        let links = try Row.fetchAll(db,
            sql: "SELECT * FROM link WHERE channelUsername = ? AND messageID = ?",
            arguments: [id.channelUsername, id.messageID]
        ).map { r -> LinkRef in
            var l = LinkRef(urlRaw: r["urlRaw"])
            if let observed: Date = r["previewObservedAt"] {
                l.preview = LinkPreview(siteName: r["previewSite"], title: r["previewTitle"],
                                        description: r["previewDescription"],
                                        resolvedURL: r["previewResolvedURL"], observedAt: observed)
            }
            return l
        }

        var poll: Poll?
        if let pr = try Row.fetchOne(db,
            sql: "SELECT * FROM poll WHERE channelUsername = ? AND messageID = ?",
            arguments: [id.channelUsername, id.messageID]) {
            let opts = (try? JSONDecoder().decode([String].self,
                        from: Data((pr["optionsJSON"] as String).utf8))) ?? []
            poll = Poll(question: pr["question"], options: opts, totalVotes: pr["totalVotes"])
        }

        var forward: ForwardOrigin?
        if row["forwardChannel"] != nil || row["forwardAuthor"] != nil {
            forward = ForwardOrigin(channelUsername: row["forwardChannel"],
                                    messageID: row["forwardMessageID"],
                                    authorName: row["forwardAuthor"])
        }
        var views: ViewCount?
        if let v: Int = row["viewsValue"] {
            views = ViewCount(value: v, isApproximate: row["viewsIsApproximate"] ?? true)
        }

        return Post(id: id, date: row["date"],
                    kind: PostKind(rawValue: row["kind"]) ?? .unknown,
                    formatSource: FormatSource(rawValue: row["formatSource"]) ?? .absent,
                    mediaCount: row["mediaCount"], text: row["text"],
                    authorName: row["authorName"], isEdited: row["isEdited"],
                    replyTo: row["replyTo"], forward: forward,
                    hashtags: tags, links: links, reactions: reactions, poll: poll, views: views)
    }
}
