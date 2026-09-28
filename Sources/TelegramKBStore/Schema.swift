import Foundation
import GRDB
import TelegramKBModel

/// The database schema, as an ordered set of migrations.
///
/// Carries the six commitments made to `artanl` before this store existed — their migration cost
/// was zero then and is not now (see `Design` § *Schema commitments*).
public enum Schema {

    public static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1-core") { db in
            try db.create(table: "channel") { t in
                t.primaryKey("username", .text)
                t.column("rawChannelID", .integer).notNull()
                t.column("title", .text)
                t.column("subscriberCount", .integer)
                t.column("reachability", .text).notNull()
            }

            try db.create(table: "post") { t in
                t.column("channelUsername", .text).notNull()
                    .references("channel", onDelete: .cascade)
                t.column("messageID", .integer).notNull()
                t.primaryKey(["channelUsername", "messageID"])
                t.column("date", .datetime).notNull()
                t.column("kind", .text).notNull()
                // Never assume `kind` is meaningful when this is "absent".
                t.column("formatSource", .text).notNull()
                // >1 means an album: this post occupies messageID ..< messageID+mediaCount.
                t.column("mediaCount", .integer).notNull().defaults(to: 1)
                t.column("text", .text).notNull()          // verbatim; normalisation is index-only
                t.column("authorName", .text)
                t.column("isEdited", .boolean).notNull().defaults(to: false)
                t.column("replyTo", .integer)
                t.column("forwardChannel", .text)
                t.column("forwardMessageID", .integer)
                t.column("forwardAuthor", .text)
                t.column("viewsValue", .integer)
                // Web view counts are abbreviated ("1.4K") and must never be compared as exact
                // against a TDLib count (`TD-7`).
                t.column("viewsIsApproximate", .boolean)
            }
            // Date filtering is unavailable server-side per chat, so it is ours to serve fast.
            try db.create(index: "post_on_date", on: "post", columns: ["date"])
            try db.create(index: "post_on_kind", on: "post", columns: ["kind"])

            try db.create(table: "reaction") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("channelUsername", .text).notNull()
                t.column("messageID", .integer).notNull()
                t.column("emoji", .text)                   // NULL for paid/star reactions
                t.column("count", .integer).notNull()
                t.column("isPaid", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "reaction_on_post", on: "reaction",
                          columns: ["channelUsername", "messageID"])

            try db.create(table: "poll") { t in
                t.column("channelUsername", .text).notNull()
                t.column("messageID", .integer).notNull()
                t.primaryKey(["channelUsername", "messageID"])
                t.column("question", .text).notNull()      // indexed: often the best topic statement
                t.column("optionsJSON", .text).notNull()
                t.column("totalVotes", .integer)
            }

            try db.create(table: "hashtag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("channelUsername", .text).notNull()
                t.column("messageID", .integer).notNull()
                t.column("tag", .text).notNull()
            }
            try db.create(index: "hashtag_on_tag", on: "hashtag", columns: ["tag"])

            try db.create(table: "link") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("channelUsername", .text).notNull()
                t.column("messageID", .integer).notNull()
                t.column("urlRaw", .text).notNull()        // never rewritten
                t.column("urlCanonical", .text)            // NULL = not canonicalisable
                // A column, not a constant, so a spec bump is a query rather than a script.
                t.column("canonicalSpecVersion", .integer).notNull()
                t.column("previewSite", .text)
                t.column("previewTitle", .text)
                t.column("previewDescription", .text)
                t.column("previewResolvedURL", .text)
                // Preview metadata is a snapshot Telegram took, not a live read.
                t.column("previewObservedAt", .datetime)
            }
            try db.create(index: "link_on_canonical", on: "link", columns: ["urlCanonical"])
            try db.create(index: "link_on_post", on: "link",
                          columns: ["channelUsername", "messageID"])

            // Resolution is a timestamped OBSERVATION, never a mutation of urlCanonical.
            // The join key is effectiveURL() = COALESCE(resolvedCanonical, urlCanonical).
            try db.create(table: "urlResolution") { t in
                t.primaryKey("urlCanonical", .text)
                t.column("resolvedCanonical", .text)       // NULL = resolution failed, recorded
                t.column("httpStatus", .text)
                t.column("hops", .integer).notNull().defaults(to: 0)
                t.column("resolvedAt", .datetime).notNull()
                t.column("canonicalSpecVersion", .integer).notNull()
            }
            try db.create(index: "urlResolution_on_resolved", on: "urlResolution",
                          columns: ["resolvedCanonical"])
        }

        m.registerMigration("v2-fts") { db in
            // Dual index. `unicode61` ranks word search over folded text + lemmas; `trigram`
            // serves substring, which Telegram's own search cannot do at all. Both are plain
            // FTS5 tables populated explicitly — the content is *derived* (folded, lemmatised),
            // not a copy of a column, so external-content sync does not apply.
            try db.create(virtualTable: "postFTS", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("content")
            }
            try db.create(virtualTable: "postTrigram", using: FTS5()) { t in
                // GRDB ships no `.trigram` helper and needs none — the descriptor takes the
                // tokenizer name directly. Trigram requires SQLite 3.34+; macOS system SQLite
                // is 3.51 and GRDB links it, so no custom build (`research/grdb-fts5.md`).
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("content")
            }
            // Maps an FTS rowid back to a post.
            try db.create(table: "ftsMap") { t in
                t.primaryKey("rowid", .integer)
                t.column("channelUsername", .text).notNull()
                t.column("messageID", .integer).notNull()
            }
            try db.create(index: "ftsMap_on_post", on: "ftsMap",
                          columns: ["channelUsername", "messageID"], unique: true)
        }

        m.registerMigration("v3-watermarks-in-channel") { db in
            // Crawl state lives on the channel row, not in a side file.
            //
            // A separate watermark file drifts from the database, and did: deleting the store
            // while the file survived made sync "resume" from a mark describing rows that no
            // longer existed, leaving a channel with 17 posts and a high-water mark of 181 —
            // and no amount of deriving the mark from the store fixes that, because the store's
            // MAX is also 181. The gap is *below* the mark. One source of truth removes the
            // failure class instead of narrowing it.
            try db.alter(table: "channel") { t in
                t.add(column: "lowestMessageID", .integer)
                t.add(column: "highestMessageID", .integer)
                t.add(column: "backfillComplete", .boolean).notNull().defaults(to: false)
                t.add(column: "lastSyncedAt", .datetime)
            }
        }

        m.registerMigration("v4-lemmas-in-their-own-column") { db in
            // A phrase must not be able to straddle the surface text and the lemmas.
            //
            // Both were stored in ONE column separated by a newline, and FTS5 tokenises a
            // newline away: for "кошка сидела на окне" + lemmas "кошка сидеть на окно", the
            // phrase "окне кошка" matched — the last word of the text next to the first lemma.
            // Verified directly before the change. Columns cannot be straddled, so the lemmas
            // move into one of their own, and every indexed post is rebuilt through the same
            // code that writes new ones.
            try db.execute(sql: "DROP TABLE IF EXISTS postFTS")
            try db.create(virtualTable: "postFTS", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("content")
                t.column("lemmas")
            }
            // The rebuild writes through the live indexing code, and that code now records the
            // index generation — a table `v5` introduced. So a populated store upgrading from v3
            // reached this line before `indexState` existed and failed with "no such table",
            // leaving the store unopenable (PR #2, review round 2; reproduced on a real v3 store
            // before the fix). A migration that calls live code must first create everything that
            // code touches; `v5` below tolerates finding it already here.
            try Schema.createIndexState(in: db)
            try Store.rebuildWordIndex(in: db)
        }

        m.registerMigration("v5-index-generation") { db in
            // One counter, bumped by every write to either search index. A cursor records it, so
            // a page served after ANY index change can say the ground moved. The first version
            // derived it from the newest sync time and the number of indexed posts, which a post
            // replaced in place changes neither of — review round 1 of PR #2.
            try Schema.createIndexState(in: db)
        }

        m.registerMigration("v6-channel-lease") { db in
            // One writer per channel, as a row rather than a convention (TD-21). Sync and import
            // both claim this lease before writing and hold it to the end of the run; a claimant
            // steals it only from a dead or silent holder.
            //
            // No foreign key: the lease is taken BEFORE the channel row it protects may exist.
            // The nonce lets a lease tell two holders in one process apart — a pid cannot.
            try db.create(table: "channelLease") { t in
                t.primaryKey("channelUsername", .text)
                t.column("pid", .integer).notNull()
                t.column("nonce", .text).notNull()
                t.column("heartbeat", .datetime).notNull()
            }
        }

        return m
    }
}

extension Schema {
    /// The index-generation counter, created idempotently: both `v4` (whose rebuild writes through
    /// code that bumps it) and `v5` (which introduced it) must be able to call this, in either
    /// order of history — a store upgrading from v3 runs both, one from v4 runs only v5.
    static func createIndexState(in db: Database) throws {
        try db.create(table: "indexState", ifNotExists: true) { t in
            t.primaryKey("id", .integer).check { $0 == 1 }
            t.column("generation", .integer).notNull().defaults(to: 0)
        }
        try db.execute(sql: "INSERT OR IGNORE INTO indexState (id, generation) VALUES (1, 0)")
    }
}
