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
    public func searchWords(_ query: String, limit: Int? = 50) throws -> [Hit] {
        try dbPool.read { db in try Self.wordHits(query, limit: limit, in: db) }
    }

    /// Takes a `Database`, not the pool, so it cannot open a snapshot of its own — callers that
    /// combine indexes decide how many snapshots there are.
    static func wordHits(_ query: String, limit: Int?, in db: Database) throws -> [Hit] {
        let folded = TextNormalizer.normalizeQuery(query)
        let terms = TextNormalizer.lemmas(folded) ?? folded
        // Failable, not throwing, and it discards FTS5 operator characters — the sanctioned
        // path for text arriving straight from an LLM tool call (`research/grdb-fts5.md`).
        guard let pattern = try? FTS5Pattern(matchingAllTokensIn: terms) else { return [] }
        return try Hit.fetchAll(db, sql: """
            SELECT m.channelUsername AS cu, m.messageID AS mid, bm25(postFTS) AS rank
            FROM postFTS JOIN ftsMap m ON m.rowid = postFTS.rowid
            WHERE postFTS MATCH ? ORDER BY rank LIMIT ?
            """, arguments: [pattern, limit ?? -1])   // SQLite: a negative LIMIT is no limit
    }

    /// Substring search over the `trigram` index — the thing Telegram's search cannot do at all
    /// (`imation` returns 0 there, 14 here).
    public func searchSubstring(_ query: String, limit: Int? = 50) throws -> [Hit] {
        try dbPool.read { db in try Self.substringHits(query, limit: limit, in: db) }
    }

    static func substringHits(_ query: String, limit: Int?, in db: Database) throws -> [Hit] {
        let folded = TextNormalizer.normalizeQuery(query)
        guard folded.count >= 3 else { return [] }   // trigram needs three characters
        return try Hit.fetchAll(db, sql: """
            SELECT m.channelUsername AS cu, m.messageID AS mid, bm25(postTrigram) AS rank
            FROM postTrigram JOIN ftsMap m ON m.rowid = postTrigram.rowid
            WHERE postTrigram MATCH ? ORDER BY rank LIMIT ?
            """, arguments: [FTS5Pattern(matchingPhrase: folded), limit ?? -1])
    }

    public enum SearchMode: String, Sendable, CaseIterable {
        case words, substring, both
    }

    public struct SearchResults: Sendable {
        /// Ordered, at most `limit` long.
        public var hits: [Hit]
        /// Every match, before truncation. `hits.count < total` means more exist — never that
        /// the rest were discarded.
        public var total: Int
    }

    /// One search across both indexes, with a single merge policy for every caller.
    ///
    /// **Policy: word hits by bm25, then substring-only hits by bm25.** Not rank fusion. On the
    /// synced corpus word hits are almost exactly a subset of substring hits for Latin text
    /// (`swift`: 2932 of 3740; `concurrency`: 236 of 239), so fusion doubles the score of
    /// everything both indexes find — which demotes the Russian lemma-only matches (`архитектура`:
    /// 144 found by words alone) and still buries `SwiftUI` under `swift`. The substring-only
    /// tail is not dropped when words fill `limit`: `total` says it exists. See Design.md.
    ///
    /// **One snapshot for both indexes.** Two `dbPool.read` calls are two snapshots, and a sync
    /// committing between them makes the two lists disagree about what exists — a post counted
    /// as substring-only because it had not yet reached the word read.
    ///
    /// **Reads are bounded by `limit`.** `total` comes from `COUNT` queries, so a small page
    /// stays a small page: asking for 20 of `swift` no longer materialises 6,672 rows.
    public func search(_ query: String, mode: SearchMode, limit: Int) throws -> SearchResults {
        let cap = max(limit, 0)
        return try dbPool.read { db in
            let words = mode == .substring ? [] : try Self.wordHits(query, limit: cap, in: db)
            var hits = words
            if mode != .words, hits.count < cap {
                // Fewer word hits came back than the limit asked for, so the word set is
                // COMPLETE — which is what makes "not in the word set" mean substring-only here.
                // Had the page filled, the substring tail would be below the cut anyway.
                var seen = Set(words.map(\.id))
                for hit in try Self.substringHits(query, limit: cap, in: db)
                where seen.insert(hit.id).inserted {
                    hits.append(hit)
                    if hits.count == cap { break }
                }
            }
            return SearchResults(hits: hits, total: try Self.matchCount(query, mode: mode, in: db))
        }
    }

    /// Every match, counted in SQLite rather than in Swift. A truncated page reports what it
    /// left behind without the caller holding the rest.
    static func matchCount(_ query: String, mode: SearchMode, in db: Database) throws -> Int {
        let folded = TextNormalizer.normalizeQuery(query)
        let terms = TextNormalizer.lemmas(folded) ?? folded
        let wordPattern = try? FTS5Pattern(matchingAllTokensIn: terms)
        let substringPattern = folded.count >= 3 ? FTS5Pattern(matchingPhrase: folded) : nil

        func count(_ table: String, _ pattern: FTS5Pattern?) throws -> Int {
            guard let pattern else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table) WHERE \(table) MATCH ?",
                                    arguments: [pattern]) ?? 0
        }
        switch mode {
        case .words: return try count("postFTS", wordPattern)
        case .substring: return try count("postTrigram", substringPattern)
        case .both:
            guard let wordPattern, let substringPattern else {
                return try count("postFTS", wordPattern) + count("postTrigram", substringPattern)
            }
            let both = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM (
                  SELECT rowid FROM postFTS WHERE postFTS MATCH ?
                  INTERSECT SELECT rowid FROM postTrigram WHERE postTrigram MATCH ?)
                """, arguments: [wordPattern, substringPattern]) ?? 0
            return try count("postFTS", wordPattern) + count("postTrigram", substringPattern) - both
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
