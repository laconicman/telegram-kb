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
    }

    /// - Parameter full: re-walk from the newest page, overwriting stored copies. Never removes.
    public func sync(channel name: String, full: Bool = false) async throws -> Outcome {
        // Telegram usernames are case-insensitive ASCII; SQLite keys are not. A mismatch with the
        // parsed `data-post` fails the post → channel foreign key.
        let channel = name.lowercased()

        let reachability = try await classifier.classify(channel)
        guard reachability == .webPreview else {
            return Outcome(channel: channel, skipped: reachability)
        }

        // One writer per channel, enforced across processes (TD-21): a second sync — or an
        // import — of this channel fails fast instead of interleaving crawl-state reads and
        // writes. Held until the walk's last commit; a dead holder's lease is stolen.
        try store.acquireChannelLease(for: channel)
        defer { try? store.releaseChannelLease(for: channel) }

        // The channel row must exist BEFORE any post: `post.channelUsername` is a foreign key and
        // pages are written as they arrive. Insert-if-absent, never an upsert, so a previously
        // learned `rawChannelID` is not overwritten by the placeholder. A row imported as a group
        // is refused here: a group never becomes a channel, so this preview is another chat's.
        try store.ensureChannel(username: channel, reachability: .webPreview)

        let state = try store.crawlState(forChannel: channel)
        let since = state.since(full: full)

        let result = try await source.crawl(channel: channel, since: since,
                                            resumeFrom: state.resumeFrom(full: full),
                                            maxPages: maxPages) { posts, mark, pageChannelID in
            // One transaction per page: the posts and the state describing them commit together,
            // so an interruption cannot leave a mark for posts that were never written.
            let next = state.afterPage(lowest: mark.lowestMessageID,
                                       highest: mark.highestMessageID, full: full)
            // `rawChannelID` makes the page prove it belongs to the stored chat — a username
            // reassigned since the row was written fails the commit instead of mixing histories.
            try store.commitPage(posts, channel: channel, lowest: next.lowest,
                                 highest: next.highest, backfillComplete: next.backfillComplete,
                                 policy: full ? .replace : .keepExisting,
                                 rawChannelID: pageChannelID)
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
