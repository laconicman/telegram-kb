import Darwin           // kill/errno — lease holder liveness
import Foundation
import GRDB
import os               // OSAllocatedUnfairLock — LeaseTokens' synchronous map
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
    /// The lease tokens this `Store` has claimed — what lets a write tell the holder from a
    /// second `Store` in the same process, which a pid alone cannot do (PR #3, review round 4).
    let leaseTokens = LeaseTokens()

    /// A (channel → token) map for the leases one `Store` holds. A class, because the struct's
    /// methods mutate it inside `dbPool.write` closures — synchronous, which is also why this
    /// is a lock and not an actor: `assertChannelLease` runs inside a write transaction and
    /// cannot suspend (PR #3, review round 5).
    final class LeaseTokens: Sendable {
        private let tokens = OSAllocatedUnfairLock(initialState: [String: String]())
        func token(for channel: String) -> String? {
            tokens.withLock { $0[channel] }
        }
        func set(_ token: String, for channel: String) {
            tokens.withLock { $0[channel] = token }
        }
        /// Removes only the token `expected` names. A reacquisition that landed between a
        /// release's row delete and this call holds a different nonce — erasing it would
        /// orphan a lease its holder still owns (PR #3, review round 5).
        func remove(_ channel: String, onlyIf expected: String?) {
            tokens.withLock { if $0[channel] == expected { $0[channel] = nil } }
        }
    }

    // MARK: - Opening

    /// Opens for writing and runs migrations.
    public static func openForWriting(at path: String) throws -> Store {
        var config = Configuration()
        // SQLite allows ONE writer per database file, across processes. GRDB's default
        // (`.immediateError`) fails the moment the lock is held, so a second `tgkb sync` died
        // instantly if its commit landed inside another's — measured: 0.00s to failure without a
        // timeout, and a wait-then-succeed with one. Page commits last milliseconds, so waiting
        // is the honest behaviour. It bounds the wait; it does not remove SQLITE_BUSY, and it is
        // NOT a substitute for keeping one writer per channel (see Design).
        config.busyMode = .timeout(10)
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

    public enum StoreError: Error, CustomStringConvertible, Equatable {
        case schemaNotMigrated
        /// The channel is crawled from its web preview; a second source would mix.
        case channelCrawled(String)
        /// The claimed identity disagrees with what is stored; the message says how.
        case channelIDConflict(String)
        /// Another live process holds the channel's lease.
        case channelLeaseHeld(channel: String, pid: Int32)
        /// A write found this process no longer named in the channel's lease row — the lease
        /// was stolen (or never taken) and the run must stop, not interleave with the new holder.
        case channelLeaseLost(channel: String)
        public var description: String {
            switch self {
            case .schemaNotMigrated:
                return "The database schema is older than this binary expects. Run `tgkb sync` "
                     + "(the writer) to migrate it; a read-only process cannot."
            case .channelCrawled(let c):
                return "@\(c) is crawled from its web preview"
            case .channelIDConflict(let why):
                return why
            case .channelLeaseHeld(let c, let pid):
                return "@\(c) is already being written by another tgkb process (pid \(pid))"
            case .channelLeaseLost(let c):
                return "@\(c)'s lease was claimed by another writer mid-run — this run's writes stopped"
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

    /// Re-indexes every mapped post, and drops mappings that no longer point at one.
    ///
    /// Used by the `v4` migration, which recreates `postFTS` and so must refill it. A mapping
    /// whose post has gone is deleted rather than skipped: skipping leaves a row pointing at
    /// nothing and a post absent from the index, with nothing anywhere saying so.
    ///
    /// - Returns: how many posts were re-indexed, and how many stale mappings were removed.
    @discardableResult
    static func rebuildWordIndex(in db: Database) throws -> (indexed: Int, staleRemoved: Int) {
        let rows = try Row.fetchAll(db, sql: "SELECT rowid, channelUsername, messageID FROM ftsMap")
        var indexed = 0, stale = 0
        for row in rows {
            let id = Post.ID(channelUsername: row["channelUsername"], messageID: row["messageID"])
            guard let post = try loadPost(id, from: db) else {
                let rowid: Int64 = row["rowid"]
                // The mapping is not the only thing left behind. `v4` recreates `postFTS` but not
                // `postTrigram`, so the trigram row for a vanished post survives a rebuild — and
                // `matchCount` counts it while the page join through `ftsMap` cannot return it.
                // A total that disagrees with its own page is the failure `total` exists to
                // prevent, so all three rows go.
                try db.execute(sql: "DELETE FROM postFTS WHERE rowid = ?", arguments: [rowid])
                try db.execute(sql: "DELETE FROM postTrigram WHERE rowid = ?", arguments: [rowid])
                try db.execute(sql: "DELETE FROM ftsMap WHERE rowid = ?", arguments: [rowid])
                try bumpIndexGeneration(in: db)
                stale += 1
                continue
            }
            try indexForSearch(post, into: db)
            indexed += 1
        }
        return (indexed, stale)
    }

    /// Records that the search indexes changed. Every path that writes or deletes an index row
    /// calls this, so a cursor from before the change can tell.
    ///
    /// It counts WRITES, not revisions: a batch of twenty posts, or a migration's rebuild, moves it
    /// by twenty. Compare generations for equality only; the difference means nothing.
    static func bumpIndexGeneration(in db: Database) throws {
        try db.execute(sql: "UPDATE indexState SET generation = generation + 1 WHERE id = 1")
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

        let indexed = TextNormalizer.indexed(text: post.text, extras: extras)
        // Trigram serves substring, so it gets the folded surface text without lemmas —
        // lemmas would add noise to substring matching without helping it.
        let sub = TextNormalizer.foldYo(([post.text] + extras).joined(separator: "\n"))
        // Separate columns: a phrase cannot straddle the surface text and the lemmas, which it
        // could when a newline was the only thing between them (see Schema, v4).
        try db.execute(sql: "INSERT INTO postFTS (rowid, content, lemmas) VALUES (?,?,?)",
                       arguments: [rowid, indexed.surface, indexed.lemmas])
        try db.execute(sql: "INSERT INTO postTrigram (rowid, content) VALUES (?,?)", arguments: [rowid, sub])
        try bumpIndexGeneration(in: db)
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
                if let i = try? c.decode(Int.self) { self = .int(i); return }
                // Anything else must THROW, so the row counts as unreadable. Falling back to ""
                // turned a malformed status into a *failed observation*, and the import then
                // overwrote a valid stored resolution with it.
                self = .string(try c.decode(String.self))
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
            // An unparseable timestamp makes the row unreadable too. Substituting "now" would
            // import a malformed observation as the freshest one we have, and re-resolution
            // decides what to retry by age.
            guard let resolvedAt = try? iso.parse(row.resolved_at) else { skipped += 1; continue }
            let status = row.http_status?.text
            // A non-2xx outcome is recorded with resolvedCanonical nil: "we checked and it
            // failed" is different information from "we never checked", which is an absent row.
            let succeeded = status?.hasPrefix("2") ?? false
            out.append(URLResolution(
                urlCanonical: row.url_canonical,
                resolvedCanonical: succeeded ? URLCanonicaliser.canonicalise(row.final_url) : nil,
                httpStatus: status,
                hops: row.hops,
                resolvedAt: resolvedAt))
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
            try assertChannelLease(in: db, channel: username)
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
            try assertChannelLease(in: db, channel: username)
            try db.execute(sql: """
                INSERT INTO channel (username, rawChannelID, reachability) VALUES (?, 0, ?)
                ON CONFLICT(username) DO NOTHING
                """, arguments: [username, reachability.rawValue])
        }
    }

    /// Records what a crawl learns about a channel's identity, **and nothing else**.
    ///
    /// Not `upsert(channel:)`: a crawl knows only the raw id and that the preview works, so a
    /// full-row upsert writes `nil` over a title or subscriber count another source recorded.
    public func updateIdentity(channel username: String, rawChannelID: Int64,
                               reachability: Channel.Reachability) throws {
        try dbPool.write { db in
            try assertChannelLease(in: db, channel: username)
            try db.execute(sql: """
                UPDATE channel SET rawChannelID = ?, reachability = ? WHERE username = ?
                """, arguments: [rawChannelID, reachability.rawValue, username])
        }
    }

    /// What the store knows about who a channel is.
    public struct ChannelIdentity: Sendable, Equatable {
        /// `0` until a source has learned it.
        public var rawChannelID: Int64
        /// `nil` for a value this binary does not know — written by a newer `tgkb` — rather than a
        /// guess that would steer the caller wrong.
        public var reachability: Channel.Reachability?
    }

    /// `nil` when the store has no row for the channel.
    public func identity(forChannel username: String) throws -> ChannelIdentity? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT rawChannelID, reachability FROM channel WHERE username = ?
                """, arguments: [username]) else { return nil }
            return ChannelIdentity(rawChannelID: row["rawChannelID"],
                                   reachability: Channel.Reachability(rawValue: row["reachability"]))
        }
    }

    /// Every channel row carrying `rawChannelID`.
    ///
    /// Until `S7` makes the id the key, nothing in the schema stops two rows sharing one — so a
    /// writer that must not create a second has to ask here first.
    public func channels(withRawChannelID id: Int64) throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT username FROM channel WHERE rawChannelID = ? ORDER BY username",
                                arguments: [id])
        }
    }

    /// The message ids already stored for a channel: what a write under `keepExisting` will leave
    /// alone, so an import can say how much of it was new.
    public func storedMessageIDs(forChannel username: String) throws -> Set<Int> {
        try dbPool.read { db in
            Set(try Int.fetchAll(db, sql: "SELECT messageID FROM post WHERE channelUsername = ?",
                                 arguments: [username]))
        }
    }

    /// Writes a page of posts and the crawl state it implies **in one transaction**.
    ///
    /// Separate writes let an interruption land between them, leaving the watermark describing
    /// posts that were never committed — extra recrawling at best, and a claim of "one
    /// transaction scope" that was not true.
    ///
    /// `rawChannelID`, when the caller's page can name it, is checked against the stored row in
    /// this same transaction: a username reassigned to another chat must refuse rather than
    /// merge two histories under one key (PR #3, review round 4).
    public func commitPage(_ posts: [Post], channel: String, lowest: Int?, highest: Int?,
                           backfillComplete: Bool, policy: WritePolicy = .replace,
                           rawChannelID: Int64? = nil) throws {
        try dbPool.write { db in
            try assertChannelLease(in: db, channel: channel)
            if let rawChannelID {
                if let known = try Int64.fetchOne(db, sql: """
                    SELECT rawChannelID FROM channel WHERE username = ?
                    """, arguments: [channel]), known != 0, known != rawChannelID {
                    throw StoreError.channelIDConflict(
                        "@\(channel) is stored as chat \(known); the page carries chat "
                      + "\(rawChannelID) — the username was reassigned")
                }
                let others = try String.fetchAll(db, sql: """
                    SELECT username FROM channel WHERE rawChannelID = ? AND username != ?
                    """, arguments: [rawChannelID, channel])
                if !others.isEmpty {
                    throw StoreError.channelIDConflict(
                        "chat \(rawChannelID) is already stored as @\(others.joined(separator: ", @")) — renamed? "
                      + "Until S7 one chat can have only one row")
                }
            }
            for post in posts { try Self.write(post, into: db, policy: policy) }
            try db.execute(sql: """
                UPDATE channel SET lowestMessageID = ?, highestMessageID = ?,
                       backfillComplete = ?, lastSyncedAt = ? WHERE username = ?
                """, arguments: [lowest, highest, backfillComplete, Date(), channel])
        }
    }
}

extension Store {
    /// How long a lease heartbeat may go unanswered before another process may take the channel.
    /// Comfortably larger than `busyMode`'s 10 s, as TD-21 requires, and larger than one fetch's
    /// 30 s timeout — the longest gap between heartbeats a live holder can produce.
    static let channelLeaseTTL: TimeInterval = 120

    static var processID: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// Claims exclusive write access to a channel for this process — "one writer per channel"
    /// enforced across processes, where the busy timeout could only bound the symptom (TD-21).
    ///
    /// A lease already held is stolen when its heartbeat is older than `channelLeaseTTL` or its
    /// pid is dead — covering a crashed holder (stolen at once) and a pid reused by an unrelated
    /// process (stolen once the heartbeat lapses). The staleness check and the claim share one
    /// `dbPool.write`: GRDB begins write transactions as IMMEDIATE, so the write lock is held
    /// before the row is read. A read that later escalates would be the one `SQLITE_BUSY` a
    /// timeout cannot prevent.
    public func acquireChannelLease(for username: String) throws {
        try dbPool.write { db in
            let cutoff = Date().addingTimeInterval(-Self.channelLeaseTTL)
            if let lease = try Row.fetchOne(db, sql: """
                SELECT pid, heartbeat FROM channelLease WHERE channelUsername = ?
                """, arguments: [username]) {
                let pid: Int32 = lease["pid"]
                let fresh = (lease["heartbeat"] as Date) > cutoff
                // ESRCH means dead; EPERM means alive but another user's — not ours to steal from.
                let alive = kill(pid, 0) == 0 || errno == EPERM
                if fresh && alive {
                    throw StoreError.channelLeaseHeld(channel: username, pid: pid)
                }
                try db.execute(sql: "DELETE FROM channelLease WHERE channelUsername = ?",
                               arguments: [username])
            }
            let nonce = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO channelLease (channelUsername, pid, nonce, heartbeat) VALUES (?,?,?,?)
                """, arguments: [username, Self.processID, nonce, Date()])
            leaseTokens.set(nonce, for: username)
        }
    }

    /// Renews the lease's heartbeat **inside a channel-scoped write transaction** — and refuses
    /// the write when no row names this pid.
    ///
    /// A holder suspended past the TTL can resume to find its lease stolen; a renewal that ran
    /// apart from the write would update zero rows and say nothing, letting the displaced writer
    /// interleave its remaining writes with the stealer's (PR #3, review round 3). Asserting in
    /// the same transaction as the posts, identity, or crawl-state write is what stops that.
    /// `upsert` stays unleased — it is the seeding/fixture primitive, not the run path.
    ///
    /// The nonce does what the pid cannot: two `Store` values share a process, so only the
    /// token a lease was taken with tells the holder from a same-process interloper. A `nil`
    /// token — this `Store` never acquired — matches nothing and is refused like a stolen lease.
    func assertChannelLease(in db: Database, channel username: String) throws {
        try db.execute(sql: """
            UPDATE channelLease SET heartbeat = ?
            WHERE channelUsername = ? AND pid = ? AND nonce = ?
            """, arguments: [Date(), username, Self.processID, leaseTokens.token(for: username)])
        if try Int.fetchOne(db, sql: "SELECT changes()") == 0 {
            throw StoreError.channelLeaseLost(channel: username)
        }
    }

    /// Releases the lease **only if this `Store` still holds it** — a stolen lease is the
    /// stealer's, and deleting it would re-open the channel mid-run.
    public func releaseChannelLease(for username: String) throws {
        // Capture the nonce BEFORE the row delete: a same-Store reacquisition between the two
        // holds a different nonce, and removing its token would orphan its lease (round 5).
        let nonce = leaseTokens.token(for: username)
        try dbPool.write { db in
            try db.execute(sql: """
                DELETE FROM channelLease WHERE channelUsername = ? AND pid = ? AND nonce = ?
                """, arguments: [username, Self.processID, nonce])
        }
        leaseTokens.remove(username, onlyIf: nonce)
    }

    /// Claims `username` for the chat `rawChannelID`, **atomically**: the checks and the write
    /// share one transaction, so a concurrent claimant cannot pass the same checks against the
    /// same old state (PR #3, review round 1). The caller holds the channel's lease.
    ///
    /// `nil` id means the caller could not learn the chat's id (an unverified import): the row
    /// is ensured and its *reachability* corrected — imported posts make a `previewDisabled` or
    /// `unresolvable` row a `group`, and leaving the stale class would misreport it (PR #3,
    /// review round 5) — while its `rawChannelID`, known or not, is left alone.
    public func claimChannelIdentity(username: String, rawChannelID: Int64?,
                                     reachability: Channel.Reachability) throws {
        try dbPool.write { db in
            try assertChannelLease(in: db, channel: username)
            if let row = try Row.fetchOne(db, sql: """
                SELECT rawChannelID, reachability FROM channel WHERE username = ?
                """, arguments: [username]) {
                if row["reachability"] as String == Channel.Reachability.webPreview.rawValue {
                    throw StoreError.channelCrawled(username)
                }
                let known: Int64 = row["rawChannelID"]
                if let rawChannelID, known != 0, known != rawChannelID {
                    throw StoreError.channelIDConflict(
                        "@\(username) is stored as chat \(known); the claim is for chat \(rawChannelID)")
                }
            }
            if let rawChannelID {
                let others = try String.fetchAll(db, sql: """
                    SELECT username FROM channel WHERE rawChannelID = ? AND username != ?
                    ORDER BY username
                    """, arguments: [rawChannelID, username])
                if !others.isEmpty {
                    throw StoreError.channelIDConflict(
                        "chat \(rawChannelID) is already stored as @\(others.joined(separator: ", @")) — renamed? "
                      + "Until S7 one chat can have only one row")
                }
            }
            try db.execute(sql: """
                INSERT INTO channel (username, rawChannelID, reachability) VALUES (?, 0, ?)
                ON CONFLICT(username) DO UPDATE SET reachability = excluded.reachability
                """, arguments: [username, reachability.rawValue])
            if let rawChannelID {
                try db.execute(sql: """
                    UPDATE channel SET rawChannelID = ? WHERE username = ?
                    """, arguments: [rawChannelID, username])
            }
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
        /// How the channel is reached. A `.group` came from a chat export: it has no pages to
        /// miss, and its service messages — joins, pins — occupy ids no post will ever fill.
        public var reachability: Channel.Reachability?
    }

    public func integrity(forChannel username: String) throws -> Integrity? {
        /// One post's id span. Decoded by property name, so the column names are not repeated
        /// as string literals in a `Row` subscript.
        struct Span: Decodable, FetchableRecord {
            var messageID: Int
            var mediaCount: Int?
            var first: Int { messageID }
            var last: Int { messageID + max(1, mediaCount ?? 1) - 1 }
        }

        return try dbPool.read { db in
            let spans = try Span.fetchAll(db, sql: """
                SELECT messageID, mediaCount FROM post WHERE channelUsername = ? ORDER BY messageID
                """, arguments: [username])
            guard let lo = spans.first?.first else { return nil }

            // A single ordered pass, because the cost must follow the number of POSTS, not the
            // width of the id range. Materialising every covered id was fine for web ids in the
            // thousands and will not be for TDLib's, which are spaced by 2^20.
            var covered = 0, longest = 0, longestStart: Int?
            var highestCovered = lo - 1
            for span in spans {
                if span.first > highestCovered + 1 {
                    let gap = span.first - highestCovered - 1
                    if gap > longest { longest = gap; longestStart = highestCovered + 1 }
                }
                // `max(…, highestCovered + 1)` keeps overlapping spans — an album running into
                // the next post's id — from being counted twice, as the old set did not.
                covered += max(0, span.last - max(span.first, highestCovered + 1) + 1)
                highestCovered = max(highestCovered, span.last)
            }
            // The upper bound is the highest id COVERED, not the highest post's first id. When
            // the last post is an album its span runs past that id, which would make
            // `unexplained` negative and coverage exceed 100%.
            let hi = highestCovered
            let channel = try Row.fetchOne(db,
                sql: "SELECT backfillComplete, reachability FROM channel WHERE username = ?",
                arguments: [username])
            let complete: Bool = channel?["backfillComplete"] ?? false
            let reachability = (channel?["reachability"] as String?).flatMap(Channel.Reachability.init(rawValue:))

            return Integrity(lowest: lo, highest: hi, posts: spans.count,
                             covered: covered, unexplained: (hi - lo + 1) - covered,
                             longestGap: longest, longestGapStart: longestStart,
                             backfillComplete: complete, reachability: reachability)
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
        // `full` starts at the newest page and so may replace the bounds — but a walk that saw
        // NOTHING has seen nothing to replace them with. Writing its nils back erased the range
        // and sent every later sync into a fresh backfill.
        if full { return (lowest ?? self.lowest, highest ?? self.highest) }
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
        // to record page by page. Completion is left as it was: false for a backfill, which only
        // the finished walk may change; and for `--full` over a finished channel, still true —
        // an interrupted refresh removes nothing, so every older post is still stored, and
        // clearing the flag would make the next plain sync re-walk the whole history for nothing.
        let bounds = merged(lowest: lowest, highest: highest, full: full)
        return Store.CrawlState(lowest: bounds.lowest, highest: bounds.highest,
                                backfillComplete: backfillComplete)
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
        // Stopped short — page cap, or a repeated page — so the gap above the old `highest` is
        // still open. Keeping the old mark would re-walk the same newest pages forever once the
        // gap is wider than the cap (TD-18). But what this walk DID cover is contiguous from the
        // newest page down to `lowest`, which is exactly an unfinished backfill: record it as
        // one, and the next run resumes below `lowest`, through the gap, to proven exhaustion.
        // It re-walks already-stored history below the gap; that costs requests, never posts.
        if incremental && !(reachedSince || reachedEnd) {
            guard let lowest, let highest else { return self }
            return Store.CrawlState(lowest: lowest, highest: Swift.max(highest, self.highest ?? highest),
                                    backfillComplete: false)
        }
        let bounds = merged(lowest: lowest, highest: highest, full: full)
        // Completion is only ever gained by proven exhaustion, never lost: a capped `--full` over a
        // finished channel still has every older post stored from before.
        return Store.CrawlState(lowest: bounds.lowest, highest: bounds.highest,
                                backfillComplete: backfillComplete || reachedEnd)
    }
}
