import Foundation
import TelegramKBIngest
import TelegramKBModel
import TelegramKBStore

/// One channel's sync: classify, crawl, write each page, then record what the walk proved.
///
/// **This lives in a library because it was the last untested correctness logic in the project.**
/// It sat in `tgkb`'s `Sync` command, which no test can import, and six review rounds found bugs
/// in it — every one of them about what may be recorded, and when. The decisions themselves are
/// pure functions on `Store.CrawlState`; this is the loop that sequences them, and it is now
/// drivable from tests with a stub fetcher.
public struct ChannelSync: Sendable {
    let store: Store
    let source: WebPreviewSource
    let classifier: ChannelClassifier
    let maxPages: Int

    public init(store: Store, fetcher: PageFetcher, maxPages: Int = 500) {
        self.store = store
        self.source = WebPreviewSource(fetcher: fetcher)
        self.classifier = ChannelClassifier(fetcher: fetcher)
        self.maxPages = maxPages
    }

    /// What one channel's sync did, so the caller can report it without the library printing.
    public struct Outcome: Sendable, Equatable {
        public var channel: String
        /// `nil` when the channel was crawled; otherwise why it was not.
        public var skipped: Channel.Reachability?
        public var postCount = 0
        public var pagesFetched = 0
        /// The incremental mark this run started from, or `nil` for a backfill or `--full`.
        public var since: Int?
        /// Blocks dropped because they belonged to another channel. Always zero so far; a
        /// non-zero value is worth reporting rather than swallowing.
        public var foreignBlocks = 0
        /// Blocks the parser could not read. Non-zero means posts are missing from the index
        /// below the recorded mark, where no later incremental run will look for them.
        public var unreadableBlocks = 0
        /// The end-of-session WAL reclaim failed with a real error (`TD-22` — BUSY, a reader
        /// mid-snapshot, is absorbed inside `Store.truncateWAL` and does not set this). The
        /// sync itself is complete; the residue is reclaimed by a later write instead.
        public var walCleanupFailed = false
    }

    /// - Parameter full: re-walk from the newest page, overwriting stored copies. Never removes.
    public func sync(channel name: String, full: Bool = false) async throws -> Outcome {
        var outcome: Outcome
        do {
            outcome = try await walk(channel: name, full: full)
        } catch {
            // A failed walk still committed pages, so the reclaim is still attempted. The
            // walk's own error is the one the caller must see, so this result is dropped.
            try? store.truncateWAL()
            throw error
        }
        do {
            try store.truncateWAL()
        } catch {
            outcome.walCleanupFailed = true
        }
        return outcome
    }

    /// Classify, crawl, write each page, record what the walk proved. `sync` wraps this in
    /// the session-end WAL reclaim, which is why the flag lives on `Outcome`.
    private func walk(channel name: String, full: Bool) async throws -> Outcome {
        // Telegram usernames are case-insensitive ASCII; SQLite keys are not. A mismatch with the
        // parsed `data-post` fails the post → channel foreign key.
        let channel = name.lowercased()

        let reachability = try await classifier.classify(channel)
        guard reachability == .webPreview else {
            return Outcome(channel: channel, skipped: reachability)
        }

        // The channel row must exist BEFORE any post: `post.channelUsername` is a foreign key and
        // pages are written as they arrive. Insert-if-absent, never an upsert, so a previously
        // learned `rawChannelID` is not overwritten by the placeholder.
        try store.ensureChannel(username: channel, reachability: .webPreview)

        let state = try store.crawlState(forChannel: channel)
        let since = state.since(full: full)

        let result = try await source.crawl(channel: channel, since: since,
                                            resumeFrom: state.resumeFrom(full: full),
                                            maxPages: maxPages) { posts, mark in
            // One transaction per page: the posts and the state describing them commit together,
            // so an interruption cannot leave a mark for posts that were never written.
            let next = state.afterPage(lowest: mark.lowestMessageID,
                                       highest: mark.highestMessageID, full: full)
            try store.commitPage(posts, channel: channel, lowest: next.lowest,
                                 highest: next.highest, backfillComplete: next.backfillComplete,
                                 policy: full ? .replace : .keepExisting)
        }

        if let raw = result.rawChannelID {
            try store.updateIdentity(channel: channel, rawChannelID: raw, reachability: .webPreview)
        }

        // The one write outside a page transaction, and the only one that can be: completion is
        // knowable only once the walk stops, and the page that turns out to be last looks like
        // every other while it is being written. A crash here costs a re-crawl, never a false
        // completion — `backfillComplete` only ever moves on proven exhaustion.
        let fetched = result.postCount > 0
        let final = state.afterWalk(lowest: fetched ? result.watermark.lowestMessageID : nil,
                                    highest: fetched ? result.watermark.highestMessageID : nil,
                                    full: full, reachedEnd: result.reachedEnd,
                                    reachedSince: result.reachedSince)
        try store.recordCrawlState(channel: channel, lowest: final.lowest, highest: final.highest,
                                   backfillComplete: final.backfillComplete)

        return Outcome(channel: channel, skipped: nil, postCount: result.postCount,
                       pagesFetched: result.pagesFetched, since: since,
                       foreignBlocks: result.foreignBlocks,
                       unreadableBlocks: result.unreadableBlocks)
    }
}
