import Foundation
import GRDB
import Testing
import TelegramKBIngest
import TelegramKBModel
@testable import TelegramKBStore
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
        // A finished writer: holds the lease for its writes, then releases it for the sync.
        try store.acquireChannelLease(for: "swiftui_dev")
        try store.ensureChannel(username: "swiftui_dev", reachability: .webPreview)
        try store.recordCrawlState(channel: "swiftui_dev", lowest: 1, highest: 100,
                                   backfillComplete: true)
        try store.releaseChannelLease(for: "swiftui_dev")

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

/// Round-9: a page carrying another channel's block used to abort the whole sync — the foreign
/// post failed the `post → channel` foreign key, so one stray block made the page unreadable.
extension SyncTests {
    @Test("a foreign block on the page is dropped and counted, not written and not fatal")
    func foreignBlockDoesNotAbortTheSync() async throws {
        let store = try Self.store()
        let foreign = #"""
        <div class="tgme_widget_message" data-post="someone_else/7" data-view="eyJjIjotOTk5fQ">
          <div class="tgme_widget_message_text js-message_text">not ours</div>
          <a class="tgme_widget_message_date"><time datetime="2026-01-01T00:00:00+00:00"></time></a>
        </div>
        """#
        let page = try Self.fixture("swiftui_dev").replacingOccurrences(of: "<body", with: "<body>\(foreign)<div hidden")
        let stub = StubFetcher(["https://t.me/s/swiftui_dev": Self.ok(page, "https://t.me/s/swiftui_dev")])

        let outcome = try await ChannelSync(store: store, fetcher: stub).sync(channel: "swiftui_dev")
        #expect(outcome.foreignBlocks == 1, "dropped, and counted rather than swallowed")
        #expect(outcome.postCount > 0, "this channel's posts on the same page still land")
        #expect(try store.post(.init(channelUsername: "someone_else", messageID: 7)) == nil)
        #expect(try store.channelUsernames() == ["swiftui_dev"])
    }
}

extension SyncTests {
    /// The count has to reach the operator: these posts are missing from the index, below a mark
    /// later runs start above.
    @Test("a sync reports blocks it could not read")
    func syncReportsUnreadableBlocks() async throws {
        let store = try Self.store()
        let broken = #"<div class="tgme_widget_message" data-post="rubbish"><div class="tgme_widget_message_text js-message_text">x</div></div>"#
        let page = try Self.fixture("swiftui_dev").replacingOccurrences(of: "<body", with: "<body>\(broken)<div hidden")
        let stub = StubFetcher(["https://t.me/s/swiftui_dev": Self.ok(page, "https://t.me/s/swiftui_dev")])
        let outcome = try await ChannelSync(store: store, fetcher: stub).sync(channel: "swiftui_dev")
        #expect(outcome.unreadableBlocks == 1)
        #expect(outcome.postCount == 20)
    }
}

extension SyncTests {
    /// TD-22: the session-end reclaim lives in `ChannelSync` precisely so a test can see it —
    /// `tgkb`'s `run` cannot be imported. If the call is removed this goes green nowhere.
    @Test("a finished sync hands the WAL's space back")
    func syncLeavesWALTruncated() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgkb-sync-\(UUID().uuidString).sqlite").path
        let store = try Store.openForWriting(at: path)
        let outcome = try await ChannelSync(store: store, fetcher: try Self.twoPages())
            .sync(channel: "swiftui_dev")

        #expect(!outcome.walCleanupFailed)
        let wal = (try? FileManager.default
            .attributesOfItem(atPath: path + "-wal")[.size] as? Int) ?? 0
        #expect(wal == 0, "the file stays (PERSIST_WAL); its contents are given back")
    }

    /// TD-22's error path: a walk that fails after committing a page still reclaims, and if THAT
    /// fails with a real error the walk's error still leads — the cleanup's rides along instead
    /// of vanishing into `try?`. The first page commits; the fetcher then closes the pool and
    /// rate-limits the second, so the walk fails mid-session with nothing left to clean up on.
    /// Both cleanups the walk owes fail — the lease release, then the reclaim — and the second is
    /// appended to the first rather than wrapping it, so `session` is still the walk's error.
    @Test("a failed walk whose cleanups also fail reports them, the walk's error first")
    func failedWalkReportsFailedCleanup() async throws {
        let store = try Self.store()
        let fetcher = ClosingFetcher(store: store,
                                     first: Self.ok(try Self.fixture("swiftui_dev"), "https://t.me/s/swiftui_dev"))

        let error = await #expect(throws: Store.CleanupAlsoFailed.self) {
            try await ChannelSync(store: store, fetcher: fetcher).sync(channel: "swiftui_dev")
        }
        #expect(error?.session is WebPreviewSource.CrawlError, "the walk's own error is the one to act on")
        #expect(error?.failures.map { $0.cleanup } == [.leaseRelease(channel: "swiftui_dev"), .walReclaim],
                "each failed cleanup is named, in the order it ran")
        #expect(error?.failures.allSatisfy { $0.error is DatabaseError } == true)
    }

    /// Makes every lease release fail with a real error, and nothing else: an acquire with no row
    /// to steal only inserts, so the release's `DELETE` is the one statement that meets it.
    static func refuseLeaseRelease(in store: Store) throws {
        try store.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuseLeaseRelease BEFORE DELETE ON channelLease
                BEGIN SELECT RAISE(ABORT, 'lease release refused'); END
                """)
        }
    }

    /// 🔴 `walk` released its lease with `defer { try? … }`: a release that failed left the row
    /// behind and said nothing. A sync whose commits landed now reports it on its outcome.
    @Test("a sync whose lease release fails completes, and says so")
    func syncReportsFailedRelease() async throws {
        let store = try Self.store()
        try Self.refuseLeaseRelease(in: store)
        let outcome = try await ChannelSync(store: store, fetcher: try Self.twoPages())
            .sync(channel: "swiftui_dev")
        #expect(outcome.postCount > 0 && !outcome.walCleanupFailed)
        #expect(outcome.leaseReleaseFailed, "the release error is reported, not swallowed")
    }

    /// A skipped channel is not a write session — classification only reads t.me — so it runs no
    /// reclaim, and has no cleanup failure for `tgkb sync` to lose behind its skip report (PR #6,
    /// review round 4). The pool is closed first: a reclaim, had it run, would have failed.
    @Test("a skipped channel runs no reclaim, so no cleanup failure can hide behind the skip")
    func skippedChannelRunsNoReclaim() async throws {
        let store = try Self.store()
        let plain = #"<div class="tgme_page_extra">1 757 subscribers</div>"#
        let stub = StubFetcher([
            "https://t.me/s/iosmmcresources": Self.ok(plain, "https://t.me/iosmmcresources"),
            "https://t.me/iosmmcresources": Self.ok(plain, "https://t.me/iosmmcresources"),
        ])
        try store.dbPool.close()

        let outcome = try await ChannelSync(store: store, fetcher: stub).sync(channel: "iosmmcresources")
        #expect(outcome.skipped == .previewDisabled)
        #expect(!outcome.walCleanupFailed, "no session ran, so there was nothing to reclaim")
    }
}

extension SyncTests {
    /// TD-22 for the third writer: `--import-resolutions` is a write session too, and its reclaim
    /// was the one wiring no test could reach while it lived in the executable (PR #6, round 4).
    @Test("a resolutions import hands the WAL's space back")
    func resolutionImportLeavesWALTruncated() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgkb-res-\(UUID().uuidString).sqlite").path
        let store = try Store.openForWriting(at: path)
        let jsonl = (1...40).map { i in
            #"{"url_canonical":"https://example.com/\#(i)","final_url":"https://example.org/\#(i)","http_status":200,"hops":1,"resolved_at":"2026-09-06T01:00:00.000000+00:00"}"#
        }.joined(separator: "\n")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("res-\(UUID().uuidString).jsonl").path
        try jsonl.write(toFile: file, atomically: true, encoding: .utf8)

        let outcome = try await ResolutionImport.run(store: store, jsonl: file)
        #expect(outcome.imported == 40 && outcome.skipped == 0 && !outcome.walCleanupFailed)
        let wal = (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? Int) ?? 0
        #expect(wal == 0, "the file stays (PERSIST_WAL); its contents are given back")
    }
}

/// Serves the first page, then closes the store's pool and rate-limits every later request: a
/// walk that fails after committing a page, with no pool left for the reclaim after it.
struct ClosingFetcher: PageFetcher {
    let store: Store
    let first: FetchResult
    func fetch(_ url: URL) async throws -> FetchResult {
        if url.absoluteString == "https://t.me/s/swiftui_dev" { return first }
        try store.dbPool.close()
        return FetchResult(body: "<html>rate limited</html>", statusCode: 429, finalURL: url)
    }
}

extension SyncTests {
    @Test("a sync refuses a channel whose lease another writer holds")
    func concurrentSyncRefused() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgkb-sync-\(UUID().uuidString).sqlite").path
        let holder = try Store.openForWriting(at: path)
        try holder.acquireChannelLease(for: "swiftui_dev")
        defer { try? holder.releaseChannelLease(for: "swiftui_dev") }

        let store = try Store.openForWriting(at: path)
        await #expect(throws: Store.StoreError.channelLeaseHeld(
                        channel: "swiftui_dev", pid: ProcessInfo.processInfo.processIdentifier)) {
            try await ChannelSync(store: store, fetcher: try Self.twoPages())
                .sync(channel: "swiftui_dev")
        }
        #expect(try store.identity(forChannel: "swiftui_dev") == nil)
    }

    /// 🔴 Round-4 review: the raw-channel check ran at the END of a sync, so a username
    /// Telegram reassigned to another chat wrote the new owner's posts into the old channel's
    /// row first. The page's `data-view` carries the id, so the check now runs inside the page
    /// transaction — before a single post lands.
    @Test("a username reassigned to another chat refuses to mix its posts into the old row")
    func reassignedUsernameRefused() async throws {
        let store = try Self.store()
        // swiftui_dev was crawled once as channel 101 — a row the kind check lets through.
        try store.upsert(channel: Channel(username: "swiftui_dev", rawChannelID: 101,
                                        reachability: .webPreview))
        // Telegram then gave the name to channel 1_492_664_793 — the fixture's `data-view`.
        await #expect(throws: Store.StoreError.channelIDConflict(
                        "@swiftui_dev is stored as chat 101; the page carries chat 1492664793"
                      + " — the username was reassigned")) {
            try await ChannelSync(store: store, fetcher: try Self.twoPages())
                .sync(channel: "swiftui_dev")
        }
        #expect(try store.highestMessageID(forChannel: "swiftui_dev") == nil,
                "the foreign channel's posts must not land under the old channel's name")
        #expect(try store.identity(forChannel: "swiftui_dev")?.rawChannelID == 101)
    }

    /// 🔴 The id check above sees nothing when the group was imported with `--no-verify`: its
    /// stored id is 0, which matches any page. The row's kind is the evidence that remains — a
    /// group never becomes a broadcast channel — so `ensureChannel` refuses on it, under the
    /// lease, before the first page.
    @Test("a group imported unverified refuses a web crawl under its reassigned name")
    func unverifiedGroupRefused() async throws {
        let store = try Self.store()
        try store.upsert(channel: Channel(username: "swiftui_dev", rawChannelID: 0,
                                        reachability: .group))
        await #expect(throws: Store.StoreError.channelImported("swiftui_dev")) {
            try await ChannelSync(store: store, fetcher: try Self.twoPages())
                .sync(channel: "swiftui_dev")
        }
        #expect(try store.highestMessageID(forChannel: "swiftui_dev") == nil,
                "the foreign channel's posts must not land under the group's name")
        let identity = try store.identity(forChannel: "swiftui_dev")
        #expect(identity?.rawChannelID == 0 && identity?.reachability == .group,
                "the row keeps saying what the import said")
    }
}
