import Foundation
import Testing
import TelegramKBModel
@testable import TelegramKBIngest

/// Serves committed fixtures instead of the network, so the crawler's tests are hermetic.
/// Records every URL requested, which is how pagination is asserted.
actor StubFetcher: PageFetcher {
    var routes: [String: FetchResult]
    private(set) var requested: [String] = []
    init(routes: [String: FetchResult]) { self.routes = routes }

    func fetch(_ url: URL) async throws -> FetchResult {
        requested.append(url.absoluteString)
        if let hit = routes[url.absoluteString] { return hit }
        // Unknown page = end of history, which is what Telegram returns past message 1.
        return FetchResult(body: "<html></html>", statusCode: 200, finalURL: url)
    }
    func urls() -> [String] { requested }
}

struct CrawlerTests {

    static func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func ok(_ body: String, _ urlString: String) -> FetchResult {
        FetchResult(body: body, statusCode: 200, finalURL: URL(string: urlString)!)
    }

    static func twoPageStub() throws -> StubFetcher {
        StubFetcher(routes: [
            "https://t.me/s/swiftui_dev":
                ok(try fixture("swiftui_dev"), "https://t.me/s/swiftui_dev"),
            "https://t.me/s/swiftui_dev?before=262":
                ok(try fixture("page-before-262"), "https://t.me/s/swiftui_dev?before=262"),
        ])
    }

    // MARK: - Pagination

    @Test("pages by the ids actually returned, not by a stride")
    func paginationFollowsReturnedIDs() async throws {
        let stub = try Self.twoPageStub()
        let result = try await WebPreviewSource(fetcher: stub).crawl(channel: "swiftui_dev")

        // Page 1 holds 262...297, so the cursor must be 262 — the minimum actually returned.
        // Ids are non-contiguous (54% of the id space is absent, largely albums), so any
        // decrementing stride would silently skip posts.
        #expect(await stub.urls() == [
            "https://t.me/s/swiftui_dev",
            "https://t.me/s/swiftui_dev?before=262",
            "https://t.me/s/swiftui_dev?before=237",
        ])
        #expect(result.posts.count == 34, "20 on page 1 + 14 on page 2")
        #expect(result.pagesFetched == 3, "the third page is empty and ends the walk")
    }

    @Test("stops when a page yields no progress, rather than looping")
    func noProgressStops() async throws {
        // A page whose lowest id is not below the cursor means the walk is stuck.
        let same = Self.ok(try Self.fixture("swiftui_dev"), "https://t.me/s/x")
        let stub = StubFetcher(routes: [
            "https://t.me/s/x": same,
            "https://t.me/s/x?before=262": same,   // same page again
        ])
        let result = try await WebPreviewSource(fetcher: stub).crawl(channel: "x", maxPages: 50)
        #expect(result.pagesFetched == 2, "must not keep re-requesting the same page")
        #expect(result.posts.count == 20)
    }

    @Test("a full backfill is marked complete; an incremental run is not")
    func backfillCompletion() async throws {
        let full = try await WebPreviewSource(fetcher: try Self.twoPageStub())
            .crawl(channel: "swiftui_dev")
        #expect(full.watermark.isBackfillComplete)
        #expect(full.watermark.highestMessageID == 297)
        #expect(full.watermark.lowestMessageID == 237)

        let incremental = try await WebPreviewSource(fetcher: try Self.twoPageStub())
            .crawl(channel: "swiftui_dev", since: 250)
        #expect(!incremental.watermark.isBackfillComplete,
                "an incremental run has not seen the whole history and must not claim it has")
    }

    // MARK: - Incremental sync

    @Test("an incremental run stops at the previous watermark")
    func incrementalStopsAtWatermark() async throws {
        let stub = try Self.twoPageStub()
        // Everything on page 2 is <= 260, so the walk must stop after it.
        let result = try await WebPreviewSource(fetcher: stub).crawl(channel: "swiftui_dev", since: 260)
        #expect(result.pagesFetched == 2, "must not walk into history it already has")
        #expect(await stub.urls().count == 2)
    }

    @Test("a re-run against an unchanged channel fetches one page and stops")
    func reRunIsCheap() async throws {
        let stub = try Self.twoPageStub()
        let result = try await WebPreviewSource(fetcher: stub).crawl(channel: "swiftui_dev", since: 297)
        #expect(result.pagesFetched == 1, "nothing new: one page proves it and the walk ends")
    }

    // MARK: - Classifier

    @Test("the four-way classifier separates three identical-looking 302s")
    func classification() async throws {
        #expect(ChannelClassifier.classifyPlainPage(try Self.fixture("plain-subscribers")) == .previewDisabled,
                "a real broadcast channel whose /s/ 302s has its preview switched off")
        #expect(ChannelClassifier.classifyPlainPage(try Self.fixture("plain-members")) == .group,
                "'N members' is a group, which has no /s/ preview at all")
        #expect(ChannelClassifier.classifyPlainPage(try Self.fixture("plain-contactonly")) == .unresolvable)
    }

    @Test("a 200 that redirected away from /s/ is not a preview")
    func redirectedIsNotPreviewable() async throws {
        let stub = StubFetcher(routes: [
            // Following the 302 yields a 200, so the status alone would say "previewable".
            "https://t.me/s/x": FetchResult(body: "", statusCode: 200,
                                            finalURL: URL(string: "https://t.me/x")!),
            "https://t.me/x": Self.ok(try Self.fixture("plain-members"), "https://t.me/x"),
        ])
        #expect(try await ChannelClassifier(fetcher: stub).classify("x") == .group)
    }

    // MARK: - Checkpointing

    @Test("checkpoints round-trip and are written atomically")
    func checkpointRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckpt-\(UUID().uuidString)")
        let store = CheckpointStore(at: dir.appendingPathComponent("watermarks.json"))
        #expect(try store.load().isEmpty, "a missing checkpoint is empty, not an error")

        let mark = WebPreviewSource.Watermark(channelUsername: "iosgr", highestMessageID: 4744,
                                              lowestMessageID: 1, updatedAt: Date(),
                                              isBackfillComplete: true)
        try store.update(mark)
        #expect(try store.load()["iosgr"]?.highestMessageID == 4744)

        try store.update(.init(channelUsername: "iosdev", highestMessageID: 1659,
                               lowestMessageID: 1, updatedAt: Date(), isBackfillComplete: false))
        #expect(try store.load().count == 2, "updating one channel must not drop the others")

        // Checks CLEANUP, not atomicity. Atomicity is a property of FileManager.replaceItemAt
        // and cannot be asserted without killing a process mid-write; verified by construction
        // (temp file in the destination's own directory, so the replace is a rename). The test
        // that carries real weight is `truncatedCheckpoint` below.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "the replace must leave no debris: \(leftovers)")
    }

    @Test("a truncated checkpoint is rejected rather than read as valid")
    func truncatedCheckpoint() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckpt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("watermarks.json")
        // What an append-and-flush writer leaves behind when killed mid-write.
        try #"{"iosgr":{"channelUsername":"iosgr","highestMes"#.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try CheckpointStore(at: file).load() }
    }
}

/// Hits the live network, so it is gated. Run with:
/// `TGKB_LIVE=1 swift test --filter LiveCrawl`
///
/// This is S4's actual done-criterion: a full backfill must reproduce the corpus already crawled
/// by the independent Python implementation, and a second run must fetch almost nothing.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TGKB_LIVE"] == "1"))
struct LiveCrawlTests {

    @Test("a full backfill reproduces the independently-crawled corpus")
    func fullBackfillMatchesCorpus() async throws {
        let source = WebPreviewSource(fetcher: URLSessionPageFetcher(delay: .seconds(1)))
        let result = try await source.crawl(channel: "swiftui_dev")

        // The Python crawler found 136 posts spanning ids 1...297 for this channel.
        #expect(result.posts.count == 136, "got \(result.posts.count)")
        #expect(result.watermark.lowestMessageID == 1)
        #expect(result.watermark.highestMessageID == 297)
        #expect(result.watermark.isBackfillComplete)
        #expect(result.posts.allSatisfy { $0.id.channelUsername == "swiftui_dev" })
        // 20/20 on the sampled page carried reactions; across the whole history it was 76/136.
        #expect(result.posts.filter { !$0.reactions.isEmpty }.count >= 70)
    }

    @Test("a second run against an unchanged channel fetches one page")
    func incrementalIsCheap() async throws {
        let source = WebPreviewSource(fetcher: URLSessionPageFetcher(delay: .seconds(1)))
        let result = try await source.crawl(channel: "swiftui_dev", since: 297)
        #expect(result.pagesFetched == 1)
    }
}
