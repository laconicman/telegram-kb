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
    /// - Parameter limit: the most hits to return, or `nil` for every match. A NEGATIVE limit is
    ///   clamped to zero rather than passed through: SQLite reads a negative `LIMIT` as unlimited,
    ///   so `-1` would quietly return the whole corpus to a caller asking for less than nothing.
    public func searchWords(_ query: String, limit: Int? = 50) throws -> [Hit] {
        try dbPool.read { db in try Self.wordHits(query, limit: limit.map { max(0, $0) }, in: db) }
    }

    /// Takes a `Database`, not the pool, so it cannot open a snapshot of its own — callers that
    /// combine indexes decide how many snapshots there are.
    /// The two patterns a query becomes, built once so a page and its `total` cannot disagree.
    ///
    /// Quoted runs are ordered phrases; everything else is an implicit AND of terms. Every piece
    /// is quoted into the expression, so text arriving from an LLM tool call cannot become an
    /// FTS5 operator, and `rawPattern` is validated by SQLite before it is used.
    static func patterns(for query: String) -> (word: FTS5Pattern?, substring: FTS5Pattern?) {
        let folded = TextNormalizer.normalizeQuery(query)
        let parsed = QueryParser.parse(folded)

        let word: FTS5Pattern?
        if parsed.phrases.isEmpty {
            // No phrase: the long-standing path, where the lemmatiser widens the whole query.
            // Failable, not throwing, and it discards FTS5 operator characters — the sanctioned
            // path for text arriving straight from an LLM tool call (`research/grdb-fts5.md`).
            let terms = TextNormalizer.lemmas(folded) ?? folded
            word = try? FTS5Pattern(matchingAllTokensIn: terms)
        } else {
            word = QueryParser.expression(parsed,
                                          phraseLemmas: parsed.phrases.map { TextNormalizer.lemmas($0) },
                                          tokenLemmas: parsed.tokens.map { TextNormalizer.lemmas($0) })
                .flatMap { try? FTS5Pattern(rawPattern: $0, allowedColumns: ["content", "lemmas"]) }
        }

        // Substring search is literal by nature, so the quote characters are noise: match what was
        // inside them, in the order they were typed. `«вёрстка»` and `вёрстка` are the same
        // substring request; `swift "чистая архитектура"` is not the same as the phrase first.
        let literal = parsed.pieces.joined(separator: " ")
        let substring = literal.count >= 3 ? FTS5Pattern(matchingPhrase: literal) : nil
        return (word, substring)
    }

    static func wordHits(_ query: String, limit: Int?, filter: SearchFilter = .init(),
                         in db: Database) throws -> [Hit] {
        guard let pattern = patterns(for: query).word else { return [] }
        let (join, condition, filterArguments) = filter.sql()
        return try Hit.fetchAll(db, sql: """
            SELECT m.channelUsername AS cu, m.messageID AS mid, bm25(postFTS) AS rank
            FROM postFTS JOIN ftsMap m ON m.rowid = postFTS.rowid \(join)
            WHERE postFTS MATCH ?\(condition)
            -- Ties broken by identity: bm25 ties are common, and an ORDER BY that leaves them
            -- arbitrary makes an offset point somewhere else on the next page.
            ORDER BY rank, m.channelUsername, m.messageID LIMIT ?
            """, arguments: StatementArguments([pattern] + filterArguments + [limit ?? -1]))
    }

    /// Substring search over the `trigram` index — the thing Telegram's search cannot do at all
    /// (`imation` returns 0 there, 14 here).
    /// - Parameter limit: as ``searchWords(_:limit:)`` — `nil` means every match, and a negative
    ///   value is clamped to zero rather than read by SQLite as unlimited.
    public func searchSubstring(_ query: String, limit: Int? = 50) throws -> [Hit] {
        try dbPool.read { db in try Self.substringHits(query, limit: limit.map { max(0, $0) }, in: db) }
    }

    static func substringHits(_ query: String, limit: Int?, filter: SearchFilter = .init(),
                              in db: Database) throws -> [Hit] {
        guard let pattern = patterns(for: query).substring else { return [] }  // trigram needs 3
        let (join, condition, filterArguments) = filter.sql()
        return try Hit.fetchAll(db, sql: """
            SELECT m.channelUsername AS cu, m.messageID AS mid, bm25(postTrigram) AS rank
            FROM postTrigram JOIN ftsMap m ON m.rowid = postTrigram.rowid \(join)
            WHERE postTrigram MATCH ?\(condition)
            ORDER BY rank, m.channelUsername, m.messageID LIMIT ?
            """, arguments: StatementArguments([pattern] + filterArguments + [limit ?? -1]))
    }

    /// Far above any page a person or a model reads, and small enough that no bound computed
    /// from it can overflow.
    public static let maxPageSize = 100_000

    public enum SearchMode: String, Sendable, CaseIterable {
        case words, substring, both
    }

    public struct SearchResults: Sendable {
        /// Ordered, at most `limit` long.
        public var hits: [Hit]
        /// Every match, before truncation. `hits.count < total` means more exist — never that
        /// the rest were discarded. With a filter, it counts only what the filter admits, so it
        /// can never promise results this page could not return.
        public var total: Int
        /// Pass back to continue after this page. `nil` when there is nothing after it — and
        /// also for `limit: 0`, which is a count-only request: nothing was consumed, so a cursor
        /// would be equivalent to none. Start paging with a positive limit.
        public var nextCursor: String?
        /// The corpus changed between the cursor's page and this one, so an offset into the
        /// result set no longer points where it did: a post may have been skipped or repeated
        /// across the boundary. Reported rather than hidden; the caller decides whether to
        /// restart the walk. Always `false` for a first page.
        public var indexMovedSinceCursor = false
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
    public func search(_ query: String, mode: SearchMode, filter: SearchFilter = .init(),
                       limit: Int, cursor: String? = nil) throws -> SearchResults {
        try dbPool.read { db in
            try Self.search(query, mode: mode, filter: filter, limit: limit, cursor: cursor, in: db)
        }
    }

    /// ``search(_:mode:filter:limit:cursor:)`` with the page's posts loaded in the same read.
    ///
    /// Hydrating from a second read hands the caller posts from a later snapshot than the hits,
    /// total and cursor came from — a sync committing in between makes one response describe
    /// two corpora.
    public func searchPosts(_ query: String, mode: SearchMode, filter: SearchFilter = .init(),
                            limit: Int, cursor: String? = nil) throws -> Hydrated<SearchResults> {
        try dbPool.read { db in
            let results = try Self.search(query, mode: mode, filter: filter, limit: limit,
                                          cursor: cursor, in: db)
            return Hydrated(results: results,
                            posts: try Self.loadPosts(results.hits.map(\.id), from: db))
        }
    }

    static func search(_ query: String, mode: SearchMode, filter: SearchFilter, limit: Int,
                       cursor: String?, in db: Database) throws -> SearchResults {
        // Clamped both ways. `Int.max` as a page size made the substring bound `end + words.count`
        // overflow and trap (PR #2, round 2); with the page and the offset both bounded, every sum
        // below stays far from the edge.
        let cap = min(max(limit, 0), maxPageSize)
        let fingerprint = Cursor.fingerprint(query: query, mode: mode, filter: filter)
        let (offset, end, cursorGeneration) = try Cursor.resume(cursor, fingerprint: fingerprint, cap: cap)

        // Read to the END of the page, not to its size: everything before `offset` still has
        // to be skipped, and the bound stays a page-sized multiple rather than the corpus.
        let words = mode == .substring ? [] : try wordHits(query, limit: end, filter: filter, in: db)
        var merged = words
        if mode != .words, words.count < end {
            // Fewer word hits came back than the page's end, so the word set is COMPLETE —
            // which is what makes "not in the word set" mean substring-only. At most
            // `words.count` of the substring candidates can be duplicates of it, so asking
            // for that many extra guarantees enough unique ones to fill the page.
            var seen = Set(words.map(\.id))
            for hit in try substringHits(query, limit: end + words.count, filter: filter, in: db)
            where seen.insert(hit.id).inserted {
                merged.append(hit)
                if merged.count == end { break }
            }
        }
        let page = Array(merged.dropFirst(offset).prefix(cap))
        // Counted in the SAME read as the page, so the two cannot describe different corpora.
        let total = try matchCount(query, mode: mode, filter: filter, in: db)
        let generation = try Cursor.generation(in: db)
        let consumed = offset + page.count
        return SearchResults(
            hits: page, total: total,
            nextCursor: consumed < total && !page.isEmpty
                ? Cursor.encode(offset: consumed, fingerprint: fingerprint, generation: generation)
                : nil,
            indexMovedSinceCursor: cursorGeneration.map { $0 != generation } ?? false)
    }

    /// Every match, counted in SQLite rather than in Swift. A truncated page reports what it
    /// left behind without the caller holding the rest.
    static func matchCount(_ query: String, mode: SearchMode, filter: SearchFilter = .init(),
                           in db: Database) throws -> Int {
        let (wordPattern, substringPattern) = patterns(for: query)
        let (join, condition, filterArguments) = filter.sql()

        func count(_ table: String, _ pattern: FTS5Pattern?) throws -> Int {
            guard let pattern else { return 0 }
            return try Int.fetchOne(db, sql: """
                SELECT count(*) FROM \(table) JOIN ftsMap m ON m.rowid = \(table).rowid \(join)
                WHERE \(table) MATCH ?\(condition)
                """, arguments: StatementArguments([pattern] + filterArguments)) ?? 0
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
                  SELECT postFTS.rowid FROM postFTS JOIN ftsMap m ON m.rowid = postFTS.rowid \(join)
                    WHERE postFTS MATCH ?\(condition)
                  INTERSECT
                  SELECT postTrigram.rowid FROM postTrigram JOIN ftsMap m ON m.rowid = postTrigram.rowid \(join)
                    WHERE postTrigram MATCH ?\(condition))
                """, arguments: StatementArguments([wordPattern] + filterArguments
                                                   + [substringPattern] + filterArguments)) ?? 0
            return try count("postFTS", wordPattern) + count("postTrigram", substringPattern) - both
        }
    }

    public func post(_ id: Post.ID) throws -> Post? {
        try dbPool.read { db in try Self.loadPost(id, from: db) }
    }

    /// A page and the posts behind its hits, read in **one** snapshot.
    ///
    /// `posts` follows the hit order. Within one read a hit's post row can only be missing when
    /// the index itself is stale, so a shorter `posts` is an index fault, not a race.
    public struct Hydrated<Results: Sendable>: Sendable {
        public var results: Results
        public var posts: [Post]
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

    /// A link-bearing post: which post carried the URL, and in which spelling.
    public struct LinkHit: Sendable, Hashable {
        public var id: Post.ID
        /// The URL exactly as it appeared in the post — never rewritten.
        public var urlRaw: String
        /// Its canonical form (`NULL` when the raw string was not canonicalisable).
        public var urlCanonical: String?
        /// `COALESCE(resolvedCanonical, urlCanonical)` — where the link actually leads.
        public var effectiveURL: String?
    }

    /// A `links(to:)` page: the hits, and every match — counted in the same read, so a truncated
    /// list can never present itself as complete. Pages with the same cursor as ``search``.
    public struct LinkResults: Sendable {
        public var hits: [LinkHit]
        public var total: Int
        /// Pass back to continue after this page; `nil` when nothing follows it.
        public var nextCursor: String?
        /// A link or resolution write landed between the cursor's page and this one, so the
        /// offset may have skipped or repeated a post. Always `false` for a first page.
        public var indexMovedSinceCursor = false
    }

    /// Posts whose links lead to the same destination as `url`.
    ///
    /// The match key is the link's **effective** URL — its canonical form, or what resolution
    /// recorded for it — compared against the effective URL of the *query*. Because resolution is
    /// keyed on the canonical string, that one predicate covers both directions the tool promises:
    /// a shortener query finds the destination's posts, and a destination query finds every
    /// spelling that resolved to it. A query that cannot be canonicalised at all falls back to a
    /// literal `urlRaw` match — the raw column exists so that spelling is still findable.
    ///
    /// The cursor is bound to the match key, not the spelling: a shortener and its destination
    /// name one result set and may continue each other's walk.
    public func links(to url: String, limit: Int = maxPageSize, cursor: String? = nil) throws
        -> LinkResults {
        try dbPool.read { db in try Self.links(to: url, limit: limit, cursor: cursor, in: db) }
    }

    /// ``links(to:limit:cursor:)`` with the linking posts loaded in the same read.
    public func linkedPosts(to url: String, limit: Int = maxPageSize, cursor: String? = nil) throws
        -> Hydrated<LinkResults> {
        try dbPool.read { db in
            let results = try Self.links(to: url, limit: limit, cursor: cursor, in: db)
            return Hydrated(results: results,
                            posts: try Self.loadPosts(results.hits.map(\.id), from: db))
        }
    }

    static func links(to url: String, limit: Int, cursor: String?, in db: Database) throws
        -> LinkResults {
        let predicate: String
        let argument: String
        if let canonical = URLCanonicaliser.canonicalise(url) {
            argument = try String.fetchOne(db,
                sql: "SELECT resolvedCanonical FROM urlResolution WHERE urlCanonical = ?",
                arguments: [canonical]) ?? canonical
            predicate = "COALESCE(r.resolvedCanonical, l.urlCanonical) = ?"
        } else {
            predicate = "l.urlRaw = ?"
            argument = url
        }
        let cap = min(max(limit, 0), maxPageSize)
        let fingerprint = Cursor.fingerprint(fields: ["links", predicate, argument])
        let (offset, _, cursorGeneration) = try Cursor.resume(cursor, fingerprint: fingerprint, cap: cap)

        let hits = try LinkHit.fetchAll(db, sql: """
            SELECT l.channelUsername AS cu, l.messageID AS mid,
                   l.urlRaw, l.urlCanonical,
                   COALESCE(r.resolvedCanonical, l.urlCanonical) AS eff
            FROM link l LEFT JOIN urlResolution r ON r.urlCanonical = l.urlCanonical
            WHERE \(predicate)
            ORDER BY l.channelUsername, l.messageID LIMIT ? OFFSET ?
            """, arguments: [argument, cap, offset])
        let total = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM link l
            LEFT JOIN urlResolution r ON r.urlCanonical = l.urlCanonical
            WHERE \(predicate)
            """, arguments: [argument]) ?? 0
        let generation = try Cursor.generation(in: db)
        let consumed = offset + hits.count
        return LinkResults(
            hits: hits, total: total,
            nextCursor: consumed < total && !hits.isEmpty
                ? Cursor.encode(offset: consumed, fingerprint: fingerprint, generation: generation)
                : nil,
            indexMovedSinceCursor: cursorGeneration.map { $0 != generation } ?? false)
    }
}

extension Store.Hit: FetchableRecord {
    public init(row: Row) {
        self.init(id: Post.ID(channelUsername: row["cu"], messageID: row["mid"]),
                  rank: row["rank"] ?? 0)
    }
}

extension Store.LinkHit: FetchableRecord {
    public init(row: Row) {
        self.init(id: Post.ID(channelUsername: row["cu"], messageID: row["mid"]),
                  urlRaw: row["urlRaw"], urlCanonical: row["urlCanonical"],
                  effectiveURL: row["eff"])
    }
}

extension Store {
    /// In `ids` order; an id without a row is skipped.
    static func loadPosts(_ ids: [Post.ID], from db: Database) throws -> [Post] {
        try ids.compactMap { try loadPost($0, from: db) }
    }

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
