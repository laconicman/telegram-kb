import Foundation
import TelegramKBModel

/// Crawls a public channel's history through `t.me/s/<channel>`.
///
/// No login, no `api_id`, no account exposure. Full history is reachable — `?before=` walks back
/// to message id 1 — so a complete public-channel backfill needs no TDLib at all.
public struct WebPreviewSource: Sendable {
    let fetcher: PageFetcher
    public init(fetcher: PageFetcher) { self.fetcher = fetcher }

    /// Where a channel's crawl has got to, so a re-run is incremental rather than a re-crawl.
    public struct Watermark: Codable, Sendable, Hashable {
        public var channelUsername: String
        /// Highest message id ingested. A later run stops once it reaches this.
        public var highestMessageID: Int
        /// Lowest id reached walking backwards. `1` (or a first page yielding nothing older)
        /// means history is exhausted and backfill need never run again.
        public var lowestMessageID: Int
        public var updatedAt: Date
        public var isBackfillComplete: Bool

        public init(channelUsername: String, highestMessageID: Int, lowestMessageID: Int,
                    updatedAt: Date, isBackfillComplete: Bool) {
            self.channelUsername = channelUsername
            self.highestMessageID = highestMessageID
            self.lowestMessageID = lowestMessageID
            self.updatedAt = updatedAt
            self.isBackfillComplete = isBackfillComplete
        }
    }

    public struct CrawlResult: Sendable {
        public var posts: [Post]
        public var watermark: Watermark
        public var pagesFetched: Int
    }

    /// Walks a channel's history, newest page first, following `?before=<lowest id on page>`.
    ///
    /// - Parameter since: stop once a page contains only posts at or below this id. Pass the
    ///   previous run's `highestMessageID` for an incremental sync, or `nil` for a full backfill.
    public func crawl(channel: String, since: Int? = nil, maxPages: Int = 500,
                      onPage: (@Sendable ([Post], Watermark) async throws -> Void)? = nil)
    async throws -> CrawlResult {
        var seen: [Int: Post] = [:]
        var cursor: Int?
        var pages = 0
        var exhausted = false

        while pages < maxPages {
            var components = URLComponents(string: "https://t.me/s/\(channel)")!
            if let cursor { components.queryItems = [URLQueryItem(name: "before", value: "\(cursor)")] }
            let result = try await fetcher.fetch(components.url!)
            pages += 1

            let posts = try WebPreviewParser.parse(html: result.body)
            guard !posts.isEmpty else { exhausted = true; break }

            let ids = posts.map(\.id.messageID)
            let lowest = ids.min()!
            for p in posts { seen[p.id.messageID] = p }

            if let onPage {
                try await onPage(posts, Watermark(
                    channelUsername: channel,
                    highestMessageID: seen.keys.max() ?? 0,
                    lowestMessageID: seen.keys.min() ?? 0,
                    updatedAt: Date(), isBackfillComplete: false))
            }

            // Incremental stop: this page is entirely at or below the previous run's high-water
            // mark, so everything older is already ingested.
            if let since, ids.allSatisfy({ $0 <= since }) { break }

            // Page by the ids actually returned, never by a fixed stride. Ids are
            // non-contiguous — 54% of the id space is absent, largely because an album occupies
            // several consecutive ids while rendering as one post — so a decrementing cursor
            // would silently skip posts.
            if let cursor, lowest >= cursor { exhausted = true; break }   // no progress
            if lowest <= 1 { exhausted = true; break }
            cursor = lowest
        }

        let all = seen.values.sorted { $0.id.messageID < $1.id.messageID }
        return CrawlResult(
            posts: all,
            watermark: Watermark(channelUsername: channel,
                                 highestMessageID: all.last?.id.messageID ?? since ?? 0,
                                 lowestMessageID: all.first?.id.messageID ?? 0,
                                 updatedAt: Date(),
                                 isBackfillComplete: exhausted && since == nil),
            pagesFetched: pages)
    }
}
