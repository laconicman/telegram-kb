import Foundation
import Testing
import TelegramKBIngest
import TelegramKBModel
import TelegramKBStore
@testable import TelegramKBSync

/// End-to-end sync: a real store, a stub fetcher, and the whole loop between them.
///
/// The per-page and per-walk decisions are unit-tested on `Store.CrawlState`. What only these
/// tests can see is the SEQUENCE — including the final state write, which is deliberately outside
/// the page transaction and so has no unit-level equivalent.
struct SyncTests {

    actor StubFetcher: PageFetcher {
        var routes: [String: FetchResult]
        private(set) var requested: [String] = []
        init(_ routes: [String: FetchResult]) { self.routes = routes }
        func fetch(_ url: URL) async throws -> FetchResult {
            requested.append(url.absoluteString)
            // An unknown page is the end of history, which is what Telegram returns past id 1.
            return routes[url.absoluteString]
                ?? FetchResult(body: "<html></html>", statusCode: 200, finalURL: url)
        }
        func urls() -> [String] { requested }
    }

    static func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func ok(_ body: String, _ url: String) -> FetchResult {
        FetchResult(body: body, statusCode: 200, finalURL: URL(string: url)!)
    }

    /// Both fixture pages: 262…297, then the page before 262. A third request finds nothing,
    /// which is what proves exhaustion.
    static func twoPages() throws -> StubFetcher {
        StubFetcher([
            "https://t.me/s/swiftui_dev": ok(try fixture("swiftui_dev"), "https://t.me/s/swiftui_dev"),
            "https://t.me/s/swiftui_dev?before=262":
                ok(try fixture("page-before-262"), "https://t.me/s/swiftui_dev?before=262"),
        ])
    }

    static func store() throws -> Store {
        try Store.openForWriting(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("tgkb-sync-\(UUID().uuidString).sqlite").path)
    }

    @Test("a first backfill walks to exhaustion and records completion")
    func firstBackfillPersistsCompletion() async throws {
        let store = try Self.store()
        let outcome = try await ChannelSync(store: store, fetcher: try Self.twoPages())
            .sync(channel: "swiftui_dev")

        #expect(outcome.since == nil, "a first run has no mark to resume from")
        #expect(outcome.postCount > 0)
        let state = try store.crawlState(forChannel: "swiftui_dev")
        #expect(state.backfillComplete, "an empty page proved the end")
        #expect(state.highest == 297)
        #expect(try store.highestMessageID(forChannel: "swiftui_dev") == 297)
    }

    @Test("the next run is incremental, and a channel that has not moved costs one page")
    func secondRunIsIncremental() async throws {
        let store = try Self.store()
        _ = try await ChannelSync(store: store, fetcher: try Self.twoPages()).sync(channel: "swiftui_dev")
        let before = try store.crawlState(forChannel: "swiftui_dev")

        let stub = try Self.twoPages()
        let outcome = try await ChannelSync(store: store, fetcher: stub).sync(channel: "swiftui_dev")
        #expect(outcome.since == 297, "it resumes from the recorded mark")
        #expect(outcome.pagesFetched == 1, "nothing new: one page proves it")
        #expect(try store.crawlState(forChannel: "swiftui_dev") == before,
                "an unchanged channel must not move the state at all")
    }

    /// TD-18's end-to-end case: more new pages than the cap. The capped walk is recorded as an
    /// unfinished backfill so the next run resumes BELOW it and crosses the gap.
    @Test("a capped incremental walk is left resumable, not marked up to date")
    func cappedIncrementalConverts() async throws {
        let store = try Self.store()
        try store.ensureChannel(username: "swiftui_dev", reachability: .webPreview)
        try store.recordCrawlState(channel: "swiftui_dev", lowest: 1, highest: 100,
                                   backfillComplete: true)

        let outcome = try await ChannelSync(store: store, fetcher: try Self.twoPages(), maxPages: 1)
            .sync(channel: "swiftui_dev", full: false)
        #expect(outcome.since == 100 && outcome.pagesFetched == 1)

        let state = try store.crawlState(forChannel: "swiftui_dev")
        #expect(!state.backfillComplete, "the walk never reached 100, so it is not up to date")
        #expect(state.lowest == 262 && state.highest == 297)
        #expect(state.resumeFrom(full: false) == 262, "the next run continues below what it has")
        #expect(state.since(full: false) == nil)
    }

    @Test("an HTTP failure mid-walk keeps the pages it wrote and claims nothing more")
    func httpFailureLeavesStateHonest() async throws {
        let store = try Self.store()
        let stub = StubFetcher([
            "https://t.me/s/swiftui_dev": Self.ok(try Self.fixture("swiftui_dev"), "https://t.me/s/swiftui_dev"),
            "https://t.me/s/swiftui_dev?before=262":
                FetchResult(body: "<html>rate limited</html>", statusCode: 429,
                            finalURL: URL(string: "https://t.me/s/swiftui_dev?before=262")!),
        ])
        await #expect(throws: WebPreviewSource.CrawlError.self) {
            try await ChannelSync(store: store, fetcher: stub).sync(channel: "swiftui_dev")
        }
        let state = try store.crawlState(forChannel: "swiftui_dev")
        #expect(!state.backfillComplete, "a failed walk must never look finished")
        #expect(state.lowest == 262, "the page that did commit is kept, and is where the next run resumes")
        #expect(try store.highestMessageID(forChannel: "swiftui_dev") == 297)
    }

    @Test("a channel whose preview is disabled is reported, and nothing is written for it")
    func previewDisabledWritesNothing() async throws {
        let store = try Self.store()
        let plain = #"<div class="tgme_page_extra">1 757 subscribers</div>"#
        let stub = StubFetcher([
            // `/s/` 302s to the plain page for all three inaccessible cases; only the plain page
            // tells them apart.
            "https://t.me/s/iosmmcresources": Self.ok(plain, "https://t.me/iosmmcresources"),
            "https://t.me/iosmmcresources": Self.ok(plain, "https://t.me/iosmmcresources"),
        ])
        let outcome = try await ChannelSync(store: store, fetcher: stub).sync(channel: "iosmmcresources")
        #expect(outcome.skipped == .previewDisabled)
        #expect(outcome.postCount == 0)
        #expect(try store.channelUsernames().isEmpty,
                "a channel we cannot crawl must not leave a row behind")
    }

    /// The fourth walk kind, end to end. `--full` overwrites what it re-reads and removes nothing:
    /// a citation must not vanish because its source did (Design § *Edits are not refreshed*).
    @Test("--full refreshes a stored post and keeps one the crawl no longer returns")
    func fullRefreshesWithoutRemoving() async throws {
        let store = try Self.store()
        _ = try await ChannelSync(store: store, fetcher: try Self.twoPages()).sync(channel: "swiftui_dev")

        // Corrupt one post that the crawl WILL return, and add one it never will.
        try store.upsert(posts: [Post(id: .init(channelUsername: "swiftui_dev", messageID: 262),
                                      date: .distantPast, kind: .text, formatSource: .web,
                                      mediaCount: 1, text: "stale text")])
        try store.upsert(posts: [Post(id: .init(channelUsername: "swiftui_dev", messageID: 99_999),
                                      date: .distantPast, kind: .text, formatSource: .web,
                                      mediaCount: 1, text: "deleted upstream")])

        let outcome = try await ChannelSync(store: store, fetcher: try Self.twoPages())
            .sync(channel: "swiftui_dev", full: true)
        #expect(outcome.since == nil, "--full ignores the mark and starts at the newest page")

        let refreshed = try #require(try store.post(.init(channelUsername: "swiftui_dev", messageID: 262)))
        #expect(refreshed.text != "stale text", "--full overwrites what it re-reads")
        #expect(try store.post(.init(channelUsername: "swiftui_dev", messageID: 99_999)) != nil,
                "a post the crawl no longer returns is KEPT — refresh is not reconciliation")
        #expect(try store.crawlState(forChannel: "swiftui_dev").backfillComplete)
    }

    @Test("a mixed-case channel argument reaches the store lowercased")
    func channelIsLowercased() async throws {
        let store = try Self.store()
        let outcome = try await ChannelSync(store: store, fetcher: try Self.twoPages())
            .sync(channel: "SwiftUI_Dev")
        #expect(outcome.channel == "swiftui_dev")
        #expect(try store.channelUsernames() == ["swiftui_dev"],
                "a second casing would be a second channel, and the posts would fail the foreign key")
    }
}
