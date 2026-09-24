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
        let same = Self.ok(try Self.fixture("swiftui_dev"), "https://t.me/s/swiftui_dev")
        let stub = StubFetcher(routes: [
            "https://t.me/s/swiftui_dev": same,
            "https://t.me/s/swiftui_dev?before=262": same,   // same page again
        ])
        let result = try await WebPreviewSource(fetcher: stub).crawl(channel: "swiftui_dev", maxPages: 50)
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

    /// 🟨 A name with a URL delimiter would fetch a different page than the name suggests —
    /// refused before any request leaves (PR #3, review round 2).
    @Test("a username that cannot be a t.me path segment never reaches the network")
    func invalidUsernameIsRefused() async throws {
        let stub = StubFetcher(routes: [:])
        await #expect(throws: Channel.InvalidUsername(name: "bad name")) {
            try await ChannelClassifier(fetcher: stub).classify("bad name")
        }
        #expect(await stub.urls().isEmpty, "refused before the first fetch")
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

/// Round-2 review findings. Each asserts the failure the reviewer described, not merely the fix.
extension CrawlerTests {

    /// 🔴 A 429 or 5xx parses as an empty page, which is indistinguishable from real exhaustion —
    /// and marking a truncated crawl complete stops every later sync from recovering the history.
    @Test("an HTTP error during pagination fails loudly instead of looking like exhaustion")
    func httpErrorIsNotExhaustion() async throws {
        let stub = StubFetcher(routes: [
            "https://t.me/s/swiftui_dev": Self.ok(try Self.fixture("swiftui_dev"), "https://t.me/s/swiftui_dev"),
            // Page two is rate-limited and empty — exactly the shape of a finished history.
            "https://t.me/s/swiftui_dev?before=262": FetchResult(body: "", statusCode: 429,
                                                       finalURL: URL(string: "https://t.me/s/swiftui_dev")!),
        ])
        await #expect(throws: WebPreviewSource.CrawlError.self) {
            _ = try await WebPreviewSource(fetcher: stub).crawl(channel: "swiftui_dev")
        }
    }

    /// 🔴 A page-capped walk has not reached the end, so it must not claim completion — otherwise
    /// the next sync trusts the mark and the remaining history is never fetched.
    @Test("hitting the page cap does not mark the backfill complete")
    func pageCapIsNotCompletion() async throws {
        // Every page yields posts and always makes progress, so only the cap stops the walk.
        var routes: [String: FetchResult] = [:]
        let page = try Self.fixture("swiftui_dev")
        routes["https://t.me/s/swiftui_dev"] = Self.ok(page, "https://t.me/s/swiftui_dev")
        routes["https://t.me/s/swiftui_dev?before=262"] = Self.ok(try Self.fixture("page-before-262"),
                                                        "https://t.me/s/swiftui_dev?before=262")
        let result = try await WebPreviewSource(fetcher: StubFetcher(routes: routes))
            .crawl(channel: "swiftui_dev", maxPages: 2)
        #expect(result.pagesFetched == 2)
        #expect(!result.watermark.isBackfillComplete,
                "a capped walk has not seen the whole history and must not say it has")
    }

    /// 🔴 Without a resume cursor a channel larger than the cap re-walks its newest pages forever.
    @Test("an unfinished backfill resumes from the saved cursor")
    func resumeFromCursor() async throws {
        let stub = StubFetcher(routes: [
            "https://t.me/s/swiftui_dev?before=262": Self.ok(try Self.fixture("page-before-262"),
                                                   "https://t.me/s/swiftui_dev?before=262"),
        ])
        let result = try await WebPreviewSource(fetcher: stub)
            .crawl(channel: "swiftui_dev", resumeFrom: 262)
        // It must start at the cursor, not at the newest page.
        #expect(await stub.urls().first == "https://t.me/s/swiftui_dev?before=262")
        #expect(result.postCount == 14)
    }

    /// 🔍 Retaining every post defeats the point of committing per page.
    /// An actor rather than a captured `var`: the callback is `@Sendable`, so Swift 6 rejects
    /// mutating captured state from it — the same rule that shaped `CheckpointStore.update`.
    actor Counter {
        private(set) var total = 0
        func add(_ n: Int) { total += n }
    }

    @Test("pages are not retained when a callback consumes them")
    func streamingDoesNotRetain() async throws {
        let counter = Counter()
        let result = try await WebPreviewSource(fetcher: try Self.twoPageStub())
            .crawl(channel: "swiftui_dev") { posts, _ in await counter.add(posts.count) }
        #expect(await counter.total == 34, "every post still reaches the caller")
        #expect(result.postCount == 34, "and is counted")
        #expect(result.posts.isEmpty, "but none is held for a final rewrite")
    }
}

/// Round-3 review findings on the crawler.
extension CrawlerTests {

    /// 🔴 A repeated page ends the loop but proves nothing about older history. The earlier
    /// `noProgressStops` test asserted only that the walk STOPPED — so it passed while this bug
    /// existed. Stopping was never the claim at risk; completion was.
    @Test("a repeated page stops the walk but does not mark the backfill complete")
    func repeatedPageIsNotCompletion() async throws {
        let same = Self.ok(try Self.fixture("swiftui_dev"), "https://t.me/s/swiftui_dev")
        let stub = StubFetcher(routes: [
            "https://t.me/s/swiftui_dev": same,
            "https://t.me/s/swiftui_dev?before=262": same,   // Telegram hands back the same page
        ])
        let result = try await WebPreviewSource(fetcher: stub).crawl(channel: "swiftui_dev", maxPages: 50)
        #expect(result.pagesFetched == 2, "still stops rather than looping")
        #expect(!result.watermark.isBackfillComplete,
                "posts below 262 were never visited, so the backfill must stay open to resume")
    }

    /// Proven exhaustion is still recognised — the fix must not make completion unreachable.
    @Test("an empty successful page still marks the backfill complete")
    func emptyPageIsCompletion() async throws {
        let result = try await WebPreviewSource(fetcher: try Self.twoPageStub())
            .crawl(channel: "swiftui_dev")
        #expect(result.watermark.isBackfillComplete, "reaching an empty page proves the end")
    }
}

extension WebPreviewParserTests {
    /// 🟡 Telegram resolves usernames case-insensitively; SQLite compares keys exactly. A mixed-
    /// case channel identifier must reach the store in the same form the CLI stores it under.
    @Test("channel usernames are lowercased at the parser boundary")
    func channelIsLowercased() throws {
        let html = try Self.html("swiftui_dev")
            .replacingOccurrences(of: "data-post=\"swiftui_dev/", with: "data-post=\"SwiftUI_Dev/")
        let posts = try WebPreviewParser.parse(html: html)
        #expect(!posts.isEmpty)
        #expect(posts.allSatisfy { $0.id.channelUsername == "swiftui_dev" },
                "a mixed-case data-post must not produce a key that fails the channel foreign key")
    }
}

/// Round-4 review findings on ingestion.
extension CrawlerTests {

    /// 🟡 A 429 or 5xx page holds no classification markers, so it read as "not publicly
    /// resolvable" and `sync` skipped a live channel with exit status 0.
    @Test("an HTTP failure while classifying is an error, not an unresolvable channel",
          arguments: [429, 502, 503])
    func classifierThrowsOnHTTPError(status: Int) async throws {
        let failing = { (u: String) in
            FetchResult(body: "<html>error</html>", statusCode: status, finalURL: URL(string: u)!)
        }
        // On the preview request itself.
        let direct = StubFetcher(routes: ["https://t.me/s/iosgr": failing("https://t.me/s/iosgr")])
        await #expect(throws: WebPreviewSource.CrawlError.self) {
            try await ChannelClassifier(fetcher: direct).classify("iosgr")
        }
        // On the plain page, after `/s/` redirected away.
        let redirected = StubFetcher(routes: [
            "https://t.me/s/iosgr": Self.ok("", "https://t.me/iosgr"),
            "https://t.me/iosgr": failing("https://t.me/iosgr"),
        ])
        await #expect(throws: WebPreviewSource.CrawlError.self) {
            try await ChannelClassifier(fetcher: redirected).classify("iosgr")
        }
    }

    /// The signal `afterWalk` needs to tell "arrived at the mark" from "stopped short".
    @Test("a walk reports whether it reached the incremental mark")
    func reachedSinceIsReported() async throws {
        let arrived = try await WebPreviewSource(fetcher: try Self.twoPageStub())
            .crawl(channel: "swiftui_dev", since: 297)
        #expect(arrived.reachedSince && !arrived.reachedEnd)
        let capped = try await WebPreviewSource(fetcher: try Self.twoPageStub())
            .crawl(channel: "swiftui_dev", since: 100, maxPages: 1)
        #expect(!capped.reachedSince, "one page of a longer walk has not reached 100")
    }
}

/// Round-10 review findings on the crawler.
extension CrawlerTests {

    /// 🔴 A preview that vanishes mid-walk redirects to the plain page, which answers 200 and
    /// parses as zero posts — the same false completion as an error page, wearing a success code.
    @Test("a redirect away from /s/ is an error, not the end of history")
    func redirectMidWalkIsNotExhaustion() async throws {
        let stub = StubFetcher(routes: [
            "https://t.me/s/swiftui_dev": Self.ok(try Self.fixture("swiftui_dev"), "https://t.me/s/swiftui_dev"),
            // The owner disables the preview between pages: 302 → plain page → 200.
            "https://t.me/s/swiftui_dev?before=262":
                Self.ok(try Self.fixture("plain-subscribers"), "https://t.me/swiftui_dev"),
        ])
        await #expect(throws: WebPreviewSource.CrawlError.self) {
            try await WebPreviewSource(fetcher: stub).crawl(channel: "swiftui_dev")
        }
    }

    /// The filter added in round 9 opened a second false-completion path: a page full of someone
    /// else's blocks is not an empty page.
    @Test("a page whose blocks all belong to another channel does not prove the end")
    func allForeignPageIsNotExhaustion() async throws {
        let foreign = #"""
        <div class="tgme_widget_message" data-post="someone_else/7" data-view="eyJjIjotOTk5fQ">
          <div class="tgme_widget_message_text js-message_text">not ours</div>
          <a class="tgme_widget_message_date"><time datetime="2026-01-01T00:00:00+00:00"></time></a>
        </div>
        """#
        let stub = StubFetcher(routes: [
            "https://t.me/s/swiftui_dev": Self.ok(try Self.fixture("swiftui_dev"), "https://t.me/s/swiftui_dev"),
            "https://t.me/s/swiftui_dev?before=262": Self.ok(foreign, "https://t.me/s/swiftui_dev?before=262"),
        ])
        let result = try await WebPreviewSource(fetcher: stub).crawl(channel: "swiftui_dev")
        #expect(result.foreignBlocks == 1)
        #expect(!result.watermark.isBackfillComplete,
                "history below 262 was never visited, so the backfill must stay open")
    }
}
