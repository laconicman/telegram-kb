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

    @Flag(name: .long, help: ArgumentHelp(
        "Re-crawl from the newest page, overwriting stored copies of every post it sees.",
        discussion: """
            Refreshes content; it does not reconcile. Posts since deleted on Telegram stay in \
            the index by design — a citation must not vanish because its source did.
            """))
    var full = false

    @Option(name: .long, help: "Seconds between requests.")
    var delay: Double = 1.0

    @Option(name: .long, help: "Import resolver JSONL into url_resolution and exit.")
    var importResolutions: String?

    /// Negative or non-finite values would reach `Duration.seconds` and the rate-limit
    /// arithmetic. Zero is valid — no delay is a legitimate, if impolite, request.
    func validate() throws {
        guard delay.isFinite, delay >= 0 else {
            throw ValidationError("--delay must be a finite number of seconds, zero or greater (got \(delay)).")
        }
    }

    func run() async throws {
        try store.ensureDirectory()
        let db = try Store.openForWriting(at: store.databasePath)

        if let path = importResolutions {
            let report = try db.importResolutions(fromJSONLAt: path)
            print("imported \(report.imported) resolutions")
            if report.skipped > 0 {
                // Loud on purpose: a skipped row is a resolution we will never have.
                let msg = "warning: \(report.skipped) unreadable row(s) skipped — the file "
                        + "may be truncated or from a different schema\n"
                FileHandle.standardError.write(Data(msg.utf8))
                // Non-zero, not just a warning. Automation reads exit status, not stderr prose,
                // and a zero exit on a partial import is a check reporting success because it
                // did not fully run.
                throw ExitCode(3)
            }
            return
        }
        guard !channels.isEmpty else {
            throw ValidationError("Name at least one channel, or pass --import-resolutions.")
        }

        let fetcher = URLSessionPageFetcher(delay: .seconds(delay))
        let source = WebPreviewSource(fetcher: fetcher)

        // Same normalisation as WebPreviewParser: Telegram usernames are case-insensitive ASCII,
        // and a mismatch with the parsed `data-post` fails the post→channel foreign key.
        for channel in channels.map({ $0.lowercased() }) {
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
            // What each page and the finished walk may record is decided by `CrawlState` in the
            // store, where it is unit-tested — three review rounds of watermark bugs all lived in
            // this loop, which no test could reach.
            let state = try db.crawlState(forChannel: channel)
            let since = state.since(full: full)

            let result = try await source.crawl(channel: channel, since: since,
                                                resumeFrom: state.resumeFrom(full: full)) { posts, mark in
                // One transaction per page: posts and the state that describes them commit
                // together, so an interruption cannot leave a mark for posts never written.
                // Edits are not refreshed on an incremental run: what was cached is what the
                // citation said when it was indexed. `--full` overwrites, so a deliberate
                // re-crawl still repairs anything captured wrong.
                let next = state.afterPage(lowest: mark.lowestMessageID,
                                           highest: mark.highestMessageID, full: full)
                try db.commitPage(posts, channel: channel, lowest: next.lowest,
                                  highest: next.highest, backfillComplete: next.backfillComplete,
                                  policy: full ? .replace : .keepExisting)
            }
            if let raw = result.rawChannelID {
                try db.upsert(channel: Channel(username: channel, rawChannelID: raw,
                                               reachability: .webPreview))
            }
            // No final rewrite of posts: every page was committed by the callback above, and
            // `crawl` does not retain them when one is given.
            let fetched = result.postCount > 0
            let final = state.afterWalk(
                lowest: fetched ? result.watermark.lowestMessageID : nil,
                highest: fetched ? result.watermark.highestMessageID : nil, full: full,
                reachedEnd: result.reachedEnd, reachedSince: result.reachedSince)
            try db.recordCrawlState(channel: channel, lowest: final.lowest,
                                   highest: final.highest, backfillComplete: final.backfillComplete)

            print("\(channel): \(result.postCount) posts, \(result.pagesFetched) pages"
                + (since.map { ", since \($0)" } ?? ", full backfill"))
        }
    }
}
