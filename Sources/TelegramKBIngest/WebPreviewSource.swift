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
        /// Posts seen across the walk, counted even when pages are not retained.
        public var postCount: Int
        /// Bare channel id from `data-view`, which yields the TDLib `chat_id` for reconciliation.
        public var rawChannelID: Int64?
        /// The walk PROVED there is nothing older: an empty successful page, or id 1.
        public var reachedEnd: Bool
        /// The walk arrived at `since`. An incremental walk that stops for any other reason has
        /// left a gap between its last page and the stored range.
        public var reachedSince: Bool
        /// Blocks on the page belonging to some other channel, dropped rather than written.
        /// Counted, never silently discarded: none have ever been observed, so a non-zero value
        /// means the page layout changed and the parser's assumptions want re-checking.
        public var foreignBlocks: Int = 0
        /// Message blocks the parser could not read at all. These are worse than foreign ones:
        /// the walk still records the highest id it read, so a skipped block below that mark is
        /// never revisited. A non-zero count means posts are missing from the index.
        public var unreadableBlocks: Int = 0
    }

    public enum CrawlError: Error, CustomStringConvertible {
        case http(status: Int, url: String)
        /// The preview redirected away from `/s/` mid-walk — the owner disabled it, or the
        /// channel stopped being publicly previewable.
        case previewUnavailable(channel: String, finalURL: String)
        public var description: String {
            switch self {
            case .http(let status, let url): "HTTP \(status) for \(url)"
            case .previewUnavailable(let channel, let url):
                "@\(channel): the web preview redirected to \(url) — it is no longer previewable"
            }
        }
    }

    /// Walks a channel's history, newest page first, following `?before=<lowest id on page>`.
    ///
    /// - Parameters:
    ///   - since: stop once a page holds only posts at or below this id. The previous run's
    ///     high-water mark for an incremental sync; `nil` for a backfill.
    ///   - resumeFrom: begin backward pagination here instead of at the newest page. The saved
    ///     `lowestMessageID` of an unfinished backfill — without it a channel larger than
    ///     `maxPages` re-walks its newest pages forever and never reaches its history.
    ///   - onPage: called with each page as it arrives — its posts, the watermark they imply,
    ///     and the channel's bare id as learned so far (`data-view`, `nil` until a page yields
    ///     one, which on real markup is the first page with this channel's posts). The id arrives
    ///     BEFORE the page's posts commit, so the caller can refuse a channel whose stored
    ///     identity disagrees while nothing has yet been written (PR #3, review round 4).
    ///     **When provided, pages are not retained** — the caller has already persisted them,
    ///     and holding a whole channel in memory to hand back at the end defeats the point of
    ///     streaming.
    public func crawl(channel: String, since: Int? = nil, resumeFrom: Int? = nil,
                      maxPages: Int = 500,
                      onPage: (@Sendable ([Post], Watermark, Int64?) async throws -> Void)? = nil)
    async throws -> CrawlResult {
        var retained: [Int: Post] = [:]
        var cursor: Int? = resumeFrom
        var pages = 0, count = 0
        var lowestSeen: Int?, highestSeen: Int?
        // Two different outcomes, deliberately separate. `reachedEnd` is PROVEN exhaustion — an
        // empty successful page, or the walk arriving at id 1. Stopping for any other reason (no
        // progress, the page cap, the incremental mark) ends the loop without proving anything
        // about older history. Conflating the two let a single repeated page seal a partial
        // backfill as complete, and a completed backfill is never re-walked.
        var reachedEnd = false, reachedSince = false
        var foreignBlocks = 0, unreadableBlocks = 0
        var rawChannelID: Int64?

        while pages < maxPages {
            var components = URLComponents(string: "https://t.me/s/\(channel)")!
            if let cursor { components.queryItems = [URLQueryItem(name: "before", value: "\(cursor)")] }
            let url = components.url!
            let result = try await fetcher.fetch(url)
            pages += 1

            // A non-2xx response parses as an empty page, which is indistinguishable from real
            // history exhaustion — and marking a truncated crawl "complete" would stop every
            // later sync from ever retrieving the missing history. Fail loudly instead.
            guard (200..<300).contains(result.statusCode) else {
                throw CrawlError.http(status: result.statusCode, url: url.absoluteString)
            }
            // A preview that disappears mid-walk is the same trap wearing a 200. `t.me/s/<ch>`
            // 302s to the plain channel page, which answers 200 and parses as zero posts —
            // indistinguishable from reaching the end of history, and it would seal a truncated
            // backfill as complete. The path is the only thing that tells them apart, which is
            // why `ChannelClassifier` checks it too.
            guard result.finalURL.path.hasPrefix("/s/") else {
                throw CrawlError.previewUnavailable(channel: channel,
                                                    finalURL: result.finalURL.absoluteString)
            }

            let page = try WebPreviewParser.page(html: result.body)
            unreadableBlocks += page.skippedBlocks
            let parsed = page.posts
            // Keep only this channel's blocks. A foreign block carries another channel's
            // `data-post`, so writing it would fail the post → channel foreign key and take the
            // whole sync down with it — the page would be unreadable rather than partly useful.
            // Only a page with NO message blocks at all proves exhaustion. A page whose blocks
            // all belong to someone else proves nothing about this channel's history, so it stops
            // the walk without claiming an end — the round-9 filter would otherwise have opened a
            // second false-completion path beside the one it closed.
            guard !parsed.isEmpty else { reachedEnd = true; break }
            let posts = parsed.filter { $0.id.channelUsername == channel.lowercased() }
            foreignBlocks += parsed.count - posts.count
            guard !posts.isEmpty else { break }
            if rawChannelID == nil {
                rawChannelID = try WebPreviewParser.rawChannelID(html: result.body, channel: channel)
            }

            let ids = posts.map(\.id.messageID)
            let lowest = ids.min()!
            count += posts.count
            lowestSeen = min(lowestSeen ?? lowest, lowest)
            highestSeen = max(highestSeen ?? ids.max()!, ids.max()!)
            if onPage == nil { for p in posts { retained[p.id.messageID] = p } }

            if let onPage {
                try await onPage(posts, Watermark(
                    channelUsername: channel, highestMessageID: highestSeen ?? 0,
                    lowestMessageID: lowestSeen ?? 0, updatedAt: Date(), isBackfillComplete: false),
                                 rawChannelID)
            }

            if let since, ids.allSatisfy({ $0 <= since }) { reachedSince = true; break }

            // Page by the ids actually returned, never by a stride: ids are non-contiguous
            // (an album occupies several while rendering as one post), so a decrementing cursor
            // would silently skip posts.
            // No progress: stop, but prove nothing. The page repeated, so older posts were never
            // visited and the backfill stays incomplete for the next run to resume.
            if let cursor, lowest >= cursor { break }
            if lowest <= 1 { reachedEnd = true; break }
            cursor = lowest
        }

        let all = retained.values.sorted { $0.id.messageID < $1.id.messageID }
        return CrawlResult(
            posts: all,
            watermark: Watermark(channelUsername: channel,
                                 highestMessageID: highestSeen ?? since ?? 0,
                                 lowestMessageID: lowestSeen ?? 0,
                                 updatedAt: Date(),
                                 // Only a walk that actually reached the end may claim this, and
                                 // a page-capped walk has not.
                                 isBackfillComplete: reachedEnd && since == nil),
            pagesFetched: pages,
            postCount: count,
            rawChannelID: rawChannelID,
            reachedEnd: reachedEnd,
            reachedSince: reachedSince,
            foreignBlocks: foreignBlocks,
            unreadableBlocks: unreadableBlocks)
    }

}
