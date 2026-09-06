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

    public func upsert(posts: [Post]) throws {
        try dbPool.write { db in
            for post in posts { try Self.write(post, into: db) }
        }
    }

    static func write(_ post: Post, into db: Database) throws {
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
