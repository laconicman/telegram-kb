import ArgumentParser
import Foundation
import TelegramKBIngest
import TelegramKBModel
import TelegramKBStore

/// Crawls channels and writes them to the store.
struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Crawl channels and update the local index.")

    @OptionGroup var store: StoreOptions

    @Argument(help: "Channel usernames, without the @.")
    var channels: [String] = []

    @Flag(name: .long, help: "Re-crawl from the beginning, ignoring saved watermarks.")
    var full = false

    @Option(name: .long, help: "Seconds between requests.")
    var delay: Double = 1.0

    @Option(name: .long, help: "Import resolver JSONL into url_resolution and exit.")
    var importResolutions: String?

    func run() async throws {
        try store.ensureDirectory()
        let db = try Store.openForWriting(at: store.databasePath)

        if let path = importResolutions {
            let n = try db.importResolutions(fromJSONLAt: path)
            print("imported \(n) resolutions")
            return
        }
        guard !channels.isEmpty else {
            throw ValidationError("Name at least one channel, or pass --import-resolutions.")
        }

        let fetcher = URLSessionPageFetcher(delay: .seconds(delay))
        let source = WebPreviewSource(fetcher: fetcher)

        for channel in channels {
            switch try await ChannelClassifier(fetcher: fetcher).classify(channel) {
            case .webPreview:
                break
            case .previewDisabled:
                // Its embeds still render a frame, but body text and media are withheld, so
                // there is nothing worth indexing until TDLib.
                FileHandle.standardError.write(Data(
                    "\(channel): web preview disabled by the owner — needs TDLib (Phase 2)\n".utf8))
                continue
            case .group:
                FileHandle.standardError.write(Data(
                    "\(channel): a group, not a broadcast channel — needs TDLib (Phase 2)\n".utf8))
                continue
            case .unresolvable:
                FileHandle.standardError.write(Data(
                    "\(channel): not publicly resolvable\n".utf8))
                continue
            }

            // The channel row must exist BEFORE any post: `post.channelUsername` is a foreign
            // key, and writing per page means posts now arrive during the crawl rather than
            // after it. `rawChannelID` is only known once a page has been parsed, so this row is
            // written twice — placeholder first, real id after. The upsert makes that free.
            // Insert-if-absent, NOT upsert: an upsert would overwrite a previously-learned
            // rawChannelID with the placeholder, and a crawl that then failed would leave the
            // false identity stored.
            try db.ensureChannel(username: channel, reachability: .webPreview)

            // One source of truth: the channel row, in the same database as the posts.
            //
            // A side watermark file drifts. Deleting the store while the file survived left a
            // channel with 17 posts and a mark of 181, and sync dutifully "resumed" — skipping
            // the backfill entirely. Deriving the mark from the store does not help either,
            // because the gap is *below* the mark. Only `backfillComplete`, written beside the
            // posts it describes, distinguishes "up to date" from "never finished".
            let state = try db.crawlState(forChannel: channel)
            let since = (full || !state.backfillComplete) ? nil : state.highest

            let result = try await source.crawl(channel: channel, since: since) { posts, mark in
                // One transaction per page: posts and the watermark that describes them commit
                // together, so an interruption cannot leave a mark for posts that were never
                // written. Progress is deliberately NOT marked complete here — only a finished
                // walk can claim that.
                // Edits are not refreshed on an incremental run: what was cached is what the
                // citation said when it was indexed. `--full` overwrites, so a deliberate
                // re-crawl still repairs anything captured wrong.
                try db.commitPage(posts, channel: channel, lowest: mark.lowestMessageID,
                                  highest: mark.highestMessageID, backfillComplete: false,
                                  policy: full ? .replace : .keepExisting)
            }
            if let raw = result.rawChannelID {
                try db.upsert(channel: Channel(username: channel, rawChannelID: raw,
                                               reachability: .webPreview))
            }
            try db.upsert(posts: result.posts, policy: full ? .replace : .keepExisting)
            try db.recordCrawlState(
                channel: channel,
                lowest: result.watermark.lowestMessageID,
                highest: result.watermark.highestMessageID,
                // An incremental run has not seen the whole history, so it must not claim to.
                backfillComplete: result.watermark.isBackfillComplete || state.backfillComplete)

            print("\(channel): \(result.posts.count) posts, \(result.pagesFetched) pages"
                + (since.map { ", since \($0)" } ?? ", full backfill"))
        }
    }
}
