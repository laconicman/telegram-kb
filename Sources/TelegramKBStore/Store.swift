import Foundation
import GRDB
import SQLite3          // sqlite3_file_control / SQLITE_FCNTL_PERSIST_WAL
import TelegramKBModel

/// The SQLite store. `tgkb` writes it; `tgkb-mcp` reads it, concurrently, from another process.
///
/// Cross-process reader/writer is verified working at the SQLite layer
/// (`research/sqlite-cross-process-probe.md`), but GRDB's own `DatabaseSharing.md` warns that
/// **`DatabaseObservation` cannot see another process's writes** — the MCP server must not be
/// built as if it could.
public struct Store: Sendable {
    let dbPool: DatabasePool

    // MARK: - Opening

    /// Opens for writing and runs migrations.
    public static func openForWriting(at path: String) throws -> Store {
        var config = Configuration()
        config.prepareDatabase { db in
            // Keeps -wal and -shm on disk after the writer closes.
            //
            // Without it a read-only open can fail with `attempt to write a readonly database`,
            // because a WAL reader must still CREATE the -shm file. The error names the
            // *database*, which sends whoever debugs it at the wrong file (`TD-6`). This and a
            // writable directory are both required — neither alone closes the hole.
            var on: CInt = 1
            _ = withUnsafeMutablePointer(to: &on) { ptr in
                sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL,
                                     UnsafeMutableRawPointer(ptr))
            }
        }
        let pool = try DatabasePool(path: path, configuration: config)
        try Schema.migrator.migrate(pool)
        return Store(dbPool: pool)
    }

    /// Opens read-only. **Never migrates** — a reader cannot, so it verifies instead.
    ///
    /// Deliberately not `immutable=1`: that would avoid the -shm problem by promising the file
    /// cannot change, which is false while a writer runs and would trade a loud failure for
    /// silently stale reads.
    public static func openForReading(at path: String) throws -> Store {
        var config = Configuration()
        config.readonly = true
        let pool = try DatabasePool(path: path, configuration: config)
        let ready = try pool.read { try Schema.migrator.hasCompletedMigrations($0) }
        guard ready else { throw StoreError.schemaNotMigrated }
        return Store(dbPool: pool)
    }

    public enum StoreError: Error, CustomStringConvertible {
        case schemaNotMigrated
        public var description: String {
            switch self {
            case .schemaNotMigrated:
                return "The database schema is older than this binary expects. Run `tgkb sync` "
                     + "(the writer) to migrate it; a read-only process cannot."
            }
        }
    }

    // MARK: - Writing

    public func upsert(channel: Channel) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO channel (username, rawChannelID, title, subscriberCount, reachability)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(username) DO UPDATE SET
                  rawChannelID = excluded.rawChannelID, title = excluded.title,
                  subscriberCount = excluded.subscriberCount, reachability = excluded.reachability
                """, arguments: [channel.username, channel.rawChannelID, channel.title,
                                 channel.subscriberCount, channel.reachability.rawValue])
        }
    }

    public func upsert(posts: [Post], policy: WritePolicy = .replace) throws {
        try dbPool.write { db in
            for post in posts { try Self.write(post, into: db, policy: policy) }
        }
    }

    static func write(_ post: Post, into db: Database, policy: WritePolicy = .replace) throws {
        if policy == .keepExisting {
            let exists = try Int.fetchOne(db, sql: """
                SELECT 1 FROM post WHERE channelUsername = ? AND messageID = ?
                """, arguments: [post.id.channelUsername, post.id.messageID]) != nil
            if exists { return }
        }
        let cu = post.id.channelUsername, mid = post.id.messageID
        try db.execute(sql: """
            INSERT INTO post (channelUsername, messageID, date, kind, formatSource, mediaCount,
                              text, authorName, isEdited, replyTo,
                              forwardChannel, forwardMessageID, forwardAuthor,
                              viewsValue, viewsIsApproximate)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(channelUsername, messageID) DO UPDATE SET
              date=excluded.date, kind=excluded.kind, formatSource=excluded.formatSource,
              mediaCount=excluded.mediaCount, text=excluded.text, authorName=excluded.authorName,
              isEdited=excluded.isEdited, replyTo=excluded.replyTo,
              forwardChannel=excluded.forwardChannel, forwardMessageID=excluded.forwardMessageID,
              forwardAuthor=excluded.forwardAuthor, viewsValue=excluded.viewsValue,
              viewsIsApproximate=excluded.viewsIsApproximate
            """, arguments: [cu, mid, post.date, post.kind.rawValue, post.formatSource.rawValue,
                             post.mediaCount, post.text, post.authorName, post.isEdited,
                             post.replyTo, post.forward?.channelUsername,
                             post.forward?.messageID, post.forward?.authorName,
                             post.views?.value, post.views?.isApproximate])

        for tbl in ["reaction", "hashtag", "link"] {
            try db.execute(sql: "DELETE FROM \(tbl) WHERE channelUsername = ? AND messageID = ?",
                           arguments: [cu, mid])
        }
        try db.execute(sql: "DELETE FROM poll WHERE channelUsername = ? AND messageID = ?",
                       arguments: [cu, mid])

        for r in post.reactions {
            try db.execute(sql: "INSERT INTO reaction (channelUsername, messageID, emoji, count, isPaid) VALUES (?,?,?,?,?)",
                           arguments: [cu, mid, r.emoji, r.count, r.isPaid])
        }
        for t in post.hashtags {
            try db.execute(sql: "INSERT INTO hashtag (channelUsername, messageID, tag) VALUES (?,?,?)",
                           arguments: [cu, mid, t])
        }
        for l in post.links {
            try db.execute(sql: """
                INSERT INTO link (channelUsername, messageID, urlRaw, urlCanonical,
                                  canonicalSpecVersion, previewSite, previewTitle,
                                  previewDescription, previewResolvedURL, previewObservedAt)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, arguments: [cu, mid, l.urlRaw, l.urlCanonical, l.canonicalSpecVersion,
                                 l.preview?.siteName, l.preview?.title, l.preview?.description,
                                 l.preview?.resolvedURL, l.preview?.observedAt])
        }
        if let p = post.poll {
            let optionsJSON = String(data: try JSONEncoder().encode(p.options), encoding: .utf8) ?? "[]"
            try db.execute(sql: "INSERT INTO poll (channelUsername, messageID, question, optionsJSON, totalVotes) VALUES (?,?,?,?,?)",
                           arguments: [cu, mid, p.question, optionsJSON, p.totalVotes])
        }

        try indexForSearch(post, into: db)
    }

    /// Populates both FTS tables.
    ///
    /// Indexed content is **derived** — folded, lemmatised, and widened with poll text, hashtags
    /// and link-preview metadata. The last of those matters: one corpus post matched Telegram's
    /// search only through its preview description, with nothing in its body.
    static func indexForSearch(_ post: Post, into db: Database) throws {
        let cu = post.id.channelUsername, mid = post.id.messageID
        let rowid: Int64
        if let existing = try Int64.fetchOne(db, sql: "SELECT rowid FROM ftsMap WHERE channelUsername = ? AND messageID = ?",
                                             arguments: [cu, mid]) {
            rowid = existing
            try db.execute(sql: "DELETE FROM postFTS WHERE rowid = ?", arguments: [rowid])
            try db.execute(sql: "DELETE FROM postTrigram WHERE rowid = ?", arguments: [rowid])
        } else {
            let next = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(rowid), 0) + 1 FROM ftsMap") ?? 1
            rowid = next
            try db.execute(sql: "INSERT INTO ftsMap (rowid, channelUsername, messageID) VALUES (?,?,?)",
                           arguments: [rowid, cu, mid])
        }

        var extras: [String] = post.hashtags.map { "#\($0)" }
        if let p = post.poll { extras.append(p.question); extras.append(contentsOf: p.options) }
        for l in post.links {
            if let t = l.preview?.title { extras.append(t) }
            if let d = l.preview?.description { extras.append(d) }
        }
        if let a = post.authorName { extras.append(a) }

        let word = TextNormalizer.indexContent(text: post.text, extras: extras)
        // Trigram serves substring, so it gets the folded surface text without lemmas —
        // lemmas would add noise to substring matching without helping it.
        let sub = TextNormalizer.foldYo(([post.text] + extras).joined(separator: "\n"))
        try db.execute(sql: "INSERT INTO postFTS (rowid, content) VALUES (?,?)", arguments: [rowid, word])
        try db.execute(sql: "INSERT INTO postTrigram (rowid, content) VALUES (?,?)", arguments: [rowid, sub])
    }

    public func upsert(resolutions: [URLResolution]) throws {
        try dbPool.write { db in
            for r in resolutions {
                try db.execute(sql: """
                    INSERT INTO urlResolution (urlCanonical, resolvedCanonical, httpStatus, hops,
                                               resolvedAt, canonicalSpecVersion)
                    VALUES (?,?,?,?,?,?)
                    ON CONFLICT(urlCanonical) DO UPDATE SET
                      resolvedCanonical=excluded.resolvedCanonical, httpStatus=excluded.httpStatus,
                      hops=excluded.hops, resolvedAt=excluded.resolvedAt,
                      canonicalSpecVersion=excluded.canonicalSpecVersion
                    """, arguments: [r.urlCanonical, r.resolvedCanonical, r.httpStatus,
                                     r.hops, r.resolvedAt, r.canonicalSpecVersion])
            }
        }
    }
}

// MARK: - S3.5 import

extension Store {
    /// Imports the standalone resolver's JSONL output (`Scripts/resolve_urls.py`).
    ///
    /// The resolver records the *final* URL; canonicalising it here keeps exactly one
    /// canonicaliser in the system, which is the same reason the script pipes through the Swift
    /// binary rather than reimplementing the spec in Python.
    public struct ImportReport: Sendable { public var imported: Int; public var skipped: Int }

    /// - Returns: how many rows were imported **and how many were unreadable**. A silent skip
    ///   turns a truncated or version-skewed file into a successful-looking import missing rows
    ///   nobody counted.
    @discardableResult
    public func importResolutions(fromJSONLAt path: String) throws -> ImportReport {
        struct Row: Decodable {
            let url_canonical: String
            let final_url: String
            let http_status: JSONValue?
            let hops: Int
            let resolved_at: String
        }
        enum JSONValue: Decodable {
            case int(Int), string(String)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let i = try? c.decode(Int.self) { self = .int(i) }
                else { self = .string((try? c.decode(String.self)) ?? "") }
            }
            var text: String { switch self { case .int(let i): "\(i)"; case .string(let s): s } }
        }

        let text = try String(contentsOfFile: path, encoding: .utf8)
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        var out: [URLResolution] = []
        var skipped = 0
        for line in text.split(separator: "\n") {
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { skipped += 1 }
                continue
            }
            let status = row.http_status?.text
            // A non-2xx outcome is recorded with resolvedCanonical nil: "we checked and it
            // failed" is different information from "we never checked", which is an absent row.
            let succeeded = status?.hasPrefix("2") ?? false
            out.append(URLResolution(
                urlCanonical: row.url_canonical,
                resolvedCanonical: succeeded ? URLCanonicaliser.canonicalise(row.final_url) : nil,
                httpStatus: status,
                hops: row.hops,
                resolvedAt: (try? iso.parse(row.resolved_at)) ?? Date()))
        }
        try upsert(resolutions: out)
        return ImportReport(imported: out.count, skipped: skipped)
    }
}

extension Store {
    /// Highest message id already stored for a channel, or `nil` if none.
    ///
    /// **This is the source of truth for incremental sync, not a checkpoint file.** A separate
    /// watermark file can drift from the database — delete the store but keep the file and sync
    /// "resumes" from a mark describing rows that no longer exist, silently skipping the
    /// backfill. That happened on the first full run. Deriving it from the store makes the
    /// drift impossible rather than merely unlikely.
    public func highestMessageID(forChannel username: String) throws -> Int? {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(messageID) FROM post WHERE channelUsername = ?",
                             arguments: [username])
        }
    }
}

extension Store {
    /// What a channel's crawl already covers. The single source of truth for incremental sync.
    public struct CrawlState: Sendable, Hashable {
        public var lowest: Int?
        public var highest: Int?
        public var backfillComplete: Bool
    }

    public func crawlState(forChannel username: String) throws -> CrawlState {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT lowestMessageID, highestMessageID, backfillComplete
                FROM channel WHERE username = ?
                """, arguments: [username]) else {
                return CrawlState(lowest: nil, highest: nil, backfillComplete: false)
            }
            return CrawlState(lowest: row["lowestMessageID"], highest: row["highestMessageID"],
                              backfillComplete: row["backfillComplete"] ?? false)
        }
    }

    /// Records crawl progress on the channel row, inside the same database as the posts — so the
    /// two cannot drift apart the way a side file did.
    public func recordCrawlState(channel username: String, lowest: Int?, highest: Int?,
                                 backfillComplete: Bool) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                UPDATE channel SET lowestMessageID = ?, highestMessageID = ?,
                       backfillComplete = ?, lastSyncedAt = ?
                WHERE username = ?
                """, arguments: [lowest, highest, backfillComplete, Date(), username])
        }
    }
}

extension Store {
    /// Ensures a channel row exists **without touching an existing one**.
    ///
    /// `upsert(channel:)` overwrites `rawChannelID` on conflict, so using it for the
    /// foreign-key prerequisite before a crawl would replace a known id with the `0` placeholder
    /// — and a crawl that then failed would leave the false identity stored, pointing TDLib
    /// reconciliation at a nonexistent chat. Insert-if-absent has no such failure mode.
    public func ensureChannel(username: String, reachability: Channel.Reachability) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO channel (username, rawChannelID, reachability) VALUES (?, 0, ?)
                ON CONFLICT(username) DO NOTHING
                """, arguments: [username, reachability.rawValue])
        }
    }

    /// Writes a page of posts and the crawl state it implies **in one transaction**.
    ///
    /// Separate writes let an interruption land between them, leaving the watermark describing
    /// posts that were never committed — extra recrawling at best, and a claim of "one
    /// transaction scope" that was not true.
    public func commitPage(_ posts: [Post], channel: String, lowest: Int?, highest: Int?,
                           backfillComplete: Bool, policy: WritePolicy = .replace) throws {
        try dbPool.write { db in
            for post in posts { try Self.write(post, into: db, policy: policy) }
            try db.execute(sql: """
                UPDATE channel SET lowestMessageID = ?, highestMessageID = ?,
                       backfillComplete = ?, lastSyncedAt = ? WHERE username = ?
                """, arguments: [lowest, highest, backfillComplete, Date(), channel])
        }
    }
}

extension Store {
    /// How to treat a post that is already stored.
    public enum WritePolicy: Sendable {
        /// Keep whatever was cached. An edited post is *not* refreshed.
        ///
        /// Chosen because a citation should keep saying what it said when it was indexed, and
        /// because an edit is usually a correction to a link rather than a change of meaning.
        /// The cost, stated plainly: a post captured mid-edit stays wrong until `--full`.
        case keepExisting
        /// Overwrite. What `--full` uses, so a deliberate re-crawl actually refreshes.
        case replace
    }

    /// Integrity of a channel's id coverage.
    ///
    /// **Message ids are a dense sequence; posts are not dense within it.** An album occupies
    /// several consecutive ids while rendering as one post, so most absences are explained by
    /// `mediaCount` rather than by anything missing. What remains after accounting for album
    /// spans is deletions, service messages — or a page we failed to fetch, which is the only
    /// one worth alarming about.
    public struct Integrity: Sendable {
        public var lowest: Int
        public var highest: Int
        public var posts: Int
        /// Ids accounted for by a post or by an album's span.
        public var covered: Int
        /// Ids in range explained by nothing. Expected to be non-zero — deletions are normal.
        public var unexplained: Int
        /// The longest run of consecutive unexplained ids. A long run is the signal that a
        /// *page* was missed, as opposed to scattered deletions.
        public var longestGap: Int
        public var longestGapStart: Int?
        public var backfillComplete: Bool
    }

    public func integrity(forChannel username: String) throws -> Integrity? {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT messageID, mediaCount FROM post WHERE channelUsername = ? ORDER BY messageID
                """, arguments: [username])
            guard let first = rows.first else { return nil }
            let state = try Row.fetchOne(db,
                sql: "SELECT backfillComplete FROM channel WHERE username = ?", arguments: [username])

            var covered = Set<Int>()
            for r in rows {
                let id: Int = r["messageID"], span: Int = r["mediaCount"] ?? 1
                for i in id..<(id + max(1, span)) { covered.insert(i) }
            }
            // The upper bound is the highest id COVERED, not the highest post's first id.
            // When the last post is an album its span runs past that id, so deriving `hi` from
            // the row would put more ids in `covered` than in the range — making `unexplained`
            // negative and coverage exceed 100%.
            let lo: Int = first["messageID"]
            let hi = covered.max() ?? lo
            var longest = 0, longestStart: Int?, run = 0, runStart = 0
            for i in lo...hi {
                if covered.contains(i) { run = 0; continue }
                if run == 0 { runStart = i }
                run += 1
                if run > longest { longest = run; longestStart = runStart }
            }
            return Integrity(lowest: lo, highest: hi, posts: rows.count,
                             covered: covered.count, unexplained: (hi - lo + 1) - covered.count,
                             longestGap: longest, longestGapStart: longestStart,
                             backfillComplete: state?["backfillComplete"] ?? false)
        }
    }
}

extension Store {
    public func channelUsernames() throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT username FROM channel ORDER BY username")
        }
    }
}

extension Store.CrawlState {
    /// Merges progress from a walk into the state that existed before it.
    ///
    /// **Merge, never replace.** A resumed walk starts at the saved low-water mark and visits only
    /// OLDER pages, so its own maximum sits below what an earlier run already stored; writing it
    /// back would make every later incremental sync re-walk history it already has. A walk that
    /// fetched nothing reports zeros, which would erase both bounds outright. Only `full`, which
    /// starts at the newest page, has seen enough to replace them.
    ///
    /// - Parameters:
    ///   - lowest, highest: the bounds the walk itself observed, or `nil` if it saw no posts.
    public func merged(lowest: Int?, highest: Int?, full: Bool) -> (lowest: Int?, highest: Int?) {
        if full { return (lowest, highest) }
        return (lowest: [self.lowest, lowest].compactMap { $0 }.min(),
                highest: [self.highest, highest].compactMap { $0 }.max())
    }

    /// The incremental mark: fetch only posts above it. `nil` means walk from the newest page
    /// without stopping early — a backfill, or `--full`.
    public func since(full: Bool) -> Int? {
        (full || !backfillComplete) ? nil : highest
    }

    /// Where an unfinished backfill resumes. Without it a channel with more pages than the cap
    /// re-walks its newest pages on every run and never reaches its own history.
    public func resumeFrom(full: Bool) -> Int? {
        (full || backfillComplete) ? nil : lowest
    }

    /// The state to commit alongside one page of a walk.
    ///
    /// **An incremental walk records nothing until it arrives.** It descends from the newest page
    /// toward `highest`, so after any page short of that, the posts between the page and the stored
    /// range are still unfetched. Advancing `highest` there — or clearing `backfillComplete`, which
    /// turns the next run into a resume from the historical low-water mark — makes an interruption
    /// skip those posts permanently. The page's posts are still written; re-walking them after an
    /// interruption costs requests, not data.
    public func afterPage(lowest: Int, highest: Int, full: Bool) -> Store.CrawlState {
        if since(full: full) != nil { return self }
        // A backfill or full walk is contiguous from wherever it started, so its bounds are safe
        // to record page by page. It is not complete until the walk says so.
        let bounds = merged(lowest: lowest, highest: highest, full: full)
        return Store.CrawlState(lowest: bounds.lowest, highest: bounds.highest,
                                backfillComplete: false)
    }

    /// The state to record once a walk returns without throwing.
    ///
    /// - Parameters:
    ///   - lowest, highest: bounds the walk observed, or `nil` if it saw no posts.
    ///   - reachedEnd: the walk PROVED exhaustion (an empty page, or id 1).
    ///   - reachedSince: the walk arrived at the incremental mark.
    public func afterWalk(lowest: Int?, highest: Int?, full: Bool,
                          reachedEnd: Bool, reachedSince: Bool) -> Store.CrawlState {
        let incremental = since(full: full) != nil
        // Stopped short — page cap, or a repeated page — so the gap above `highest` is still open.
        // Keep the old mark; the next run walks down to it again.
        if incremental && !(reachedSince || reachedEnd) { return self }
        let bounds = merged(lowest: lowest, highest: highest, full: full)
        // Completion is only ever gained by proven exhaustion, never lost: a capped `--full` over a
        // finished channel still has every older post stored from before.
        return Store.CrawlState(lowest: bounds.lowest, highest: bounds.highest,
                                backfillComplete: backfillComplete || reachedEnd)
    }
}
