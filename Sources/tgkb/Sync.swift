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

        let checkpoints = CheckpointStore(at: URL(fileURLWithPath: store.databasePath)
            .deletingLastPathComponent().appendingPathComponent("watermarks.json"))
        let fetcher = URLSessionPageFetcher(delay: .seconds(delay))
        let source = WebPreviewSource(fetcher: fetcher)
        var marks = try checkpoints.load()

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
            try db.upsert(channel: Channel(username: channel, rawChannelID: 0,
                                           reachability: .webPreview))

            let since = full ? nil : marks[channel]?.highestMessageID
            // Write and checkpoint per PAGE, not per channel. Accumulating a whole channel and
            // saving once means an interrupted crawl loses everything — 4,388 posts for the
            // largest channel here — which would make the atomic checkpoint pointless.
            let result = try await source.crawl(channel: channel, since: since) { posts, mark in
                try db.upsert(posts: posts)
                // `update` load-modify-saves a single channel, so the closure captures nothing
                // mutable — which is what Swift 6 requires of a @Sendable closure, and is why
                // this method exists rather than mutating a captured dictionary.
                try checkpoints.update(mark)
            }
            if let raw = result.rawChannelID {
                try db.upsert(channel: Channel(username: channel, rawChannelID: raw,
                                               reachability: .webPreview))
            }
            try db.upsert(posts: result.posts)   // final pass, incl. the completion flag
            marks[channel] = result.watermark
            try checkpoints.save(marks)

            print("\(channel): \(result.posts.count) posts, \(result.pagesFetched) pages"
                + (since.map { ", since \($0)" } ?? ", full backfill"))
        }
    }
}
