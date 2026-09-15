import Foundation
import Testing
import TelegramKBModel
@testable import TelegramKBStore

struct StoreTests {

    static func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tgkb-\(UUID().uuidString).sqlite").path
    }

    static func post(_ mid: Int, _ text: String, kind: PostKind = .text,
                     mediaCount: Int = 1, hashtags: [String] = [],
                     links: [LinkRef] = [], reactions: [Reaction] = [],
                     poll: Poll? = nil) -> Post {
        Post(id: .init(channelUsername: "iosgr", messageID: mid),
             date: Date(timeIntervalSince1970: 1_700_000_000 + Double(mid)),
             kind: kind, formatSource: .web, mediaCount: mediaCount, text: text,
             hashtags: hashtags, links: links, reactions: reactions, poll: poll)
    }

    static func seeded() throws -> (Store, String) {
        let path = tempPath()
        let store = try Store.openForWriting(at: path)
        try store.upsert(channel: Channel(username: "iosgr", rawChannelID: 1_492_664_793))
        return (store, path)
    }

    @Test("migrations run on an empty file")
    func migrationsRun() throws {
        let (store, path) = try Self.seeded()
        _ = store
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("a post round-trips through the store with every relation")
    func postRoundTrip() throws {
        let (store, _) = try Self.seeded()
        let original = Self.post(
            100, "Навигация в SwiftUI", hashtags: ["howto", "swiftpm"],
            links: [LinkRef(urlRaw: "http://www.Habr.com/ru/post/1/?utm_source=tg",
                            preview: LinkPreview(siteName: "Habr", title: "Вёрстка",
                                                 description: "про вёрстку",
                                                 observedAt: Date(timeIntervalSince1970: 1_700_000_000)))],
            reactions: [Reaction(emoji: "👍", count: 13), Reaction(emoji: nil, count: 8, isPaid: true)],
            poll: Poll(question: "Какой архитектурой пользуетесь?", options: ["MVVM", "TCA"], totalVotes: 42))
        try store.upsert(posts: [original])

        let loaded = try #require(try store.post(original.id))
        #expect(loaded.text == original.text)
        #expect(loaded.hashtags.sorted() == original.hashtags.sorted())
        #expect(loaded.reactions.count == 2)
        #expect(loaded.totalReactions == 21)
        #expect(loaded.poll?.question == original.poll?.question)
        #expect(loaded.poll?.options == ["MVVM", "TCA"])
        #expect(loaded.links.first?.urlRaw == "http://www.Habr.com/ru/post/1/?utm_source=tg",
                "urlRaw must survive storage verbatim")
        #expect(loaded.links.first?.urlCanonical == "https://habr.com/ru/post/1")
    }

    /// TD-4's regression test. A naive prefix index scores WORSE than Telegram here.
    @Test("навигация matches a post containing навигации, via the lemma path")
    func russianInflection() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [
            Self.post(1, "Вопросы навигации всегда находятся сбоку от обсуждения"),
            Self.post(2, "Совсем про другое — сетевой слой и моки"),
        ])
        let hits = try store.searchWords("навигация")
        #expect(hits.contains { $0.id.messageID == 1 },
                "inflected form must match; this is exactly where FTS5 prefix matching fails")
        #expect(!hits.contains { $0.id.messageID == 2 })

        // ...and the reverse direction, which needs the query lemmatised too.
        #expect(try store.searchWords("навигацию").contains { $0.id.messageID == 1 })
    }

    /// TD-10. `unicode61 remove_diacritics 2` does not fold ё, so we must.
    @Test("вёрстка and верстка are the same word")
    func yoFolding() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [Self.post(10, "Хорошая вёрстка экрана")])
        #expect(try store.searchWords("верстка").contains { $0.id.messageID == 10 },
                "query without ё must find text with ё")
        #expect(try store.searchWords("вёрстка").contains { $0.id.messageID == 10 })
    }

    @Test("substring search finds what word search cannot")
    func substring() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [Self.post(20, "Свежая animation в SwiftUI")])
        #expect(try store.searchWords("imation").isEmpty, "word search cannot do substrings")
        #expect(try store.searchSubstring("imation").contains { $0.id.messageID == 20 },
                "trigram must — Telegram's own search returns 0 for this")
    }

    /// One corpus post matched Telegram's search ONLY through its preview description.
    @Test("link-preview text is searchable even when the body says nothing")
    func previewIsIndexed() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [Self.post(30, "Тут ребята поделились опытом",
            links: [LinkRef(urlRaw: "https://habr.com/ru/x",
                            preview: LinkPreview(title: "Compositional Layout",
                                                 description: "рассказать про вёрстку в приложении",
                                                 observedAt: Date()))])])
        #expect(try store.searchWords("верстку").contains { $0.id.messageID == 30 },
                "body has no such word; only the preview description does")
    }

    @Test("poll question is indexable text")
    func pollIndexed() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [Self.post(40, "", kind: .poll,
            poll: Poll(question: "Какой архитектурой пользуетесь?", options: ["MVVM", "TCA"]))])
        #expect(try store.searchWords("архитектурой").contains { $0.id.messageID == 40 })
        #expect(try store.searchWords("TCA").contains { $0.id.messageID == 40 })
    }

    @Test("an album stores as one post spanning many message ids")
    func albumGrain() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [Self.post(581, "подборка", kind: .album, mediaCount: 6)])
        let loaded = try #require(try store.post(.init(channelUsername: "iosgr", messageID: 581)))
        #expect(loaded.mediaCount == 6)
        #expect(loaded.messageIDSpan == 581...586)
        #expect(try store.post(.init(channelUsername: "iosgr", messageID: 582)) == nil,
                "582 is inside the album's span, not a post of its own")
    }

    @Test("effectiveURL falls back to canonical, and prefers a recorded resolution")
    func effectiveURLFromStore() throws {
        let (store, _) = try Self.seeded()
        let short = "https://clck.ru/33ABCD"
        #expect(try store.effectiveURL(forCanonical: short) == short, "no resolution recorded yet")

        try store.upsert(resolutions: [URLResolution(
            urlCanonical: short, resolvedCanonical: "https://habr.com/ru/post/1",
            httpStatus: "200", hops: 2, resolvedAt: Date())])
        #expect(try store.effectiveURL(forCanonical: short) == "https://habr.com/ru/post/1")

        let dead = "https://bit.ly/3ARSuTJ"
        try store.upsert(resolutions: [URLResolution(
            urlCanonical: dead, resolvedCanonical: nil, httpStatus: "404", hops: 0, resolvedAt: Date())])
        #expect(try store.effectiveURL(forCanonical: dead) == dead,
                "a FAILED resolution still keys on canonical — a dead link stays joinable to itself")
    }

    @Test("a reader opens read-only while a writer holds the database")
    func crossProcessRead() throws {
        let (writer, path) = try Self.seeded()
        try writer.upsert(posts: [Self.post(50, "навигация")])
        let reader = try Store.openForReading(at: path)
        #expect(try reader.searchWords("навигация").contains { $0.id.messageID == 50 })
        try writer.upsert(posts: [Self.post(51, "ещё про навигацию")])
        #expect(try reader.searchWords("навигация").count >= 2,
                "the reader sees the writer's commits; it just cannot observe them")
    }

    @Test("a read-only open of an unmigrated database fails loudly")
    func readerRefusesUnmigrated() throws {
        let path = Self.tempPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        #expect(throws: Store.StoreError.self) { _ = try Store.openForReading(at: path) }
    }
}

extension StoreTests {
    @Test("resolver JSONL imports, and a failed resolution stays joinable to itself")
    func importResolutions() throws {
        let (store, _) = try Self.seeded()
        let jsonl = """
        {"url_canonical":"https://habr.com/company/avito/blog/358892","final_url":"https://habr.com/ru/companies/avito/articles/358892","http_status":200,"hops":3,"resolved_at":"2026-09-06T01:00:00.000000+00:00"}
        {"url_canonical":"https://bit.ly/3ARSuTJ","final_url":"https://bit.ly/3ARSuTJ","http_status":404,"hops":0,"resolved_at":"2026-09-06T01:00:00.000000+00:00"}
        {"url_canonical":"https://medium.com/x","final_url":"https://medium.com/x","http_status":"URLError","hops":0,"resolved_at":"2026-09-06T01:00:00.000000+00:00"}
        """
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("res-\(UUID().uuidString).jsonl").path
        try jsonl.write(toFile: path, atomically: true, encoding: .utf8)
        // Return type changed from Int to ImportReport when skipped rows became reportable.
        #expect(try store.importResolutions(fromJSONLAt: path).imported == 3)

        // Same-host path rewrite: NOT cross-host, and it still changes the key. This is the
        // case that makes resolution a seam feature rather than a dedupe one.
        #expect(try store.effectiveURL(forCanonical: "https://habr.com/company/avito/blog/358892")
                == "https://habr.com/ru/companies/avito/articles/358892")

        // A recorded failure keys on itself — a dead link must not lose its identity.
        #expect(try store.effectiveURL(forCanonical: "https://bit.ly/3ARSuTJ") == "https://bit.ly/3ARSuTJ")
        // A transport error is a string, not an HTTP code, and must decode too.
        #expect(try store.effectiveURL(forCanonical: "https://medium.com/x") == "https://medium.com/x")
    }
}

extension StoreTests {
    /// The channel row must exist before any of its posts.
    ///
    /// Not pedantry: `tgkb sync` writes per page so an interrupted crawl loses only a page, and
    /// that change moved post writes to *before* the channel upsert — which failed with
    /// `FOREIGN KEY constraint failed` on the first real run. This pins the constraint so the
    /// ordering cannot silently regress.
    @Test("posts for an unknown channel are rejected, not silently orphaned")
    func postsRequireTheirChannel() throws {
        let path = Self.tempPath()
        let store = try Store.openForWriting(at: path)   // note: no channel inserted
        #expect(throws: (any Error).self) {
            try store.upsert(posts: [Self.post(1, "orphan")])
        }
        try store.upsert(channel: Channel(username: "iosgr", rawChannelID: 1))
        try store.upsert(posts: [Self.post(1, "now fine")])
        #expect(try store.post(.init(channelUsername: "iosgr", messageID: 1)) != nil)
    }
}

extension StoreTests {
    /// Ids are a dense sequence; posts are not dense within it, because an album covers several.
    @Test("integrity accounts for album spans rather than calling them gaps")
    func integrityAccountsForAlbums() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [
            Self.post(1, "one"),
            Self.post(2, "album", kind: .album, mediaCount: 6),   // covers 2...7
            Self.post(10, "later"),                                // 8, 9 genuinely absent
        ])
        let i = try #require(try store.integrity(forChannel: "iosgr"))
        #expect(i.posts == 3)
        #expect(i.lowest == 1 && i.highest == 10)
        // 1, 2-7, 10 = 8 ids covered by only three posts.
        #expect(i.covered == 8, "an album's span must count as covered, not as a gap")
        #expect(i.unexplained == 2, "only 8 and 9 are unexplained")
        #expect(i.longestGap == 2 && i.longestGapStart == 8)
    }

    @Test("keepExisting leaves a cached post alone; replace refreshes it")
    func writePolicy() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [Self.post(1, "original")])
        try store.upsert(posts: [Self.post(1, "edited")], policy: .keepExisting)
        #expect(try store.post(.init(channelUsername: "iosgr", messageID: 1))?.text == "original",
                "an edit must not overwrite what a citation already said")
        try store.upsert(posts: [Self.post(1, "edited")], policy: .replace)
        #expect(try store.post(.init(channelUsername: "iosgr", messageID: 1))?.text == "edited",
                "--full must still repair a post captured wrong")
    }
}

/// Round-2 review findings on the store.
extension StoreTests {

    /// 🟡 When the last post is an album its span runs past that post's own id, so deriving the
    /// range's upper bound from the row made `covered` larger than the range itself —
    /// `unexplained` went negative and Doctor could report coverage above 100%.
    @Test("a trailing album cannot push coverage above 100%")
    func trailingAlbumIntegrity() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [
            Self.post(1, "one"),
            Self.post(5, "album at the end", kind: .album, mediaCount: 6),   // covers 5...10
        ])
        let i = try #require(try store.integrity(forChannel: "iosgr"))
        #expect(i.highest == 10, "the range must end at the last COVERED id, not the last row's id")
        #expect(i.unexplained >= 0, "coverage cannot exceed the range")
        #expect(i.covered <= i.highest - i.lowest + 1)
        #expect(i.unexplained == 3, "2, 3 and 4 are the genuine gaps")
    }

    /// 🔍 A silently skipped row turns a truncated or version-skewed file into a
    /// successful-looking import missing rows nobody counted.
    @Test("unreadable resolution rows are counted, not silently dropped")
    func importReportsSkippedRows() throws {
        let (store, _) = try Self.seeded()
        let jsonl = """
        {"url_canonical":"https://a.example","final_url":"https://a.example","http_status":200,"hops":0,"resolved_at":"2026-09-06T01:00:00.000000+00:00"}
        {"url_canonical":"https://b.example","final_
        {"url_canonical":"https://c.example","final_url":"https://c.example","http_status":200,"hops":0,"resolved_at":"2026-09-06T01:00:00.000000+00:00"}
        """
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("res-\(UUID().uuidString).jsonl").path
        try jsonl.write(toFile: path, atomically: true, encoding: .utf8)

        let report = try store.importResolutions(fromJSONLAt: path)
        #expect(report.imported == 2)
        #expect(report.skipped == 1, "the truncated line must be reported, not vanish")
    }
}

/// Round-3 review findings on the store.
extension StoreTests {

    /// 🔴 A resumed walk only visits OLDER pages. Replacing the stored high-water mark with its
    /// maximum regresses the mark, and later incremental syncs re-walk history they already have.
    @Test("a resumed walk never lowers the stored high-water mark")
    func resumedWalkPreservesHighest() {
        // A capped first run stored 500...1000; the resume then fetches 1...499.
        let before = Store.CrawlState(lowest: 500, highest: 1000, backfillComplete: false)
        let after = before.merged(lowest: 1, highest: 499, full: false)
        #expect(after.highest == 1000, "the resume's own maximum (499) must not replace 1000")
        #expect(after.lowest == 1, "but the low-water mark does advance")
    }

    @Test("a walk that fetched nothing leaves both bounds untouched")
    func emptyWalkPreservesBounds() {
        let before = Store.CrawlState(lowest: 500, highest: 1000, backfillComplete: false)
        let after = before.merged(lowest: nil, highest: nil, full: false)
        #expect(after.lowest == 500 && after.highest == 1000,
                "an empty resume reported zeros, which would have erased both bounds")
    }

    @Test("a full crawl, which starts at the newest page, may replace the bounds")
    func fullCrawlReplaces() {
        let before = Store.CrawlState(lowest: 500, highest: 1000, backfillComplete: false)
        let after = before.merged(lowest: 1, highest: 1200, full: true)
        #expect(after.lowest == 1 && after.highest == 1200)
    }
}

/// Round-4 review findings on the store.
extension StoreTests {

    /// 🔴 After one page of an incremental walk, the page's own maximum was committed as the mark
    /// and `backfillComplete` was cleared. An interruption then resumed from the historical
    /// low-water mark — or, with only the flag kept, stopped at the new mark — and either way the
    /// posts between that page and the old mark were never fetched.
    @Test("an interrupted incremental sync still walks down to the old mark")
    func interruptedIncrementalKeepsGapOpen() throws {
        let (store, _) = try Self.seeded()
        try store.recordCrawlState(channel: "iosgr", lowest: 1, highest: 100, backfillComplete: true)
        let before = try store.crawlState(forChannel: "iosgr")
        #expect(before.since(full: false) == 100)

        // 101...160 appear. The walk commits its newest page, 141...160, then dies.
        let next = before.afterPage(lowest: 141, highest: 160, full: false)
        try store.commitPage((141...160).map { Self.post($0, "new \($0)") }, channel: "iosgr",
                             lowest: next.lowest, highest: next.highest,
                             backfillComplete: next.backfillComplete, policy: .keepExisting)

        let after = try store.crawlState(forChannel: "iosgr")
        #expect(after.since(full: false) == 100, "the next run must still fetch 101...140")
        #expect(after.resumeFrom(full: false) == nil,
                "and must not become a resume from message 1, which skips them too")
    }

    @Test("an incremental walk advances the mark only once it arrives")
    func incrementalWalkAdvancesOnlyOnArrival() {
        let before = Store.CrawlState(lowest: 1, highest: 100, backfillComplete: true)
        let stoppedShort = before.afterWalk(lowest: 141, highest: 160, full: false,
                                            reachedEnd: false, reachedSince: false)
        #expect(stoppedShort == before, "a capped walk left 101...140 unfetched")
        let arrived = before.afterWalk(lowest: 81, highest: 160, full: false,
                                       reachedEnd: false, reachedSince: true)
        #expect(arrived == Store.CrawlState(lowest: 1, highest: 160, backfillComplete: true))
    }

    /// The fix must not freeze a first backfill, which is contiguous from the newest page down.
    @Test("a first backfill still records progress page by page and completes only at the end")
    func backfillRecordsProgress() {
        let empty = Store.CrawlState(lowest: nil, highest: nil, backfillComplete: false)
        let page = empty.afterPage(lowest: 141, highest: 160, full: false)
        #expect(page == Store.CrawlState(lowest: 141, highest: 160, backfillComplete: false))
        #expect(page.resumeFrom(full: false) == 141)
        let done = page.afterWalk(lowest: 1, highest: 140, full: false,
                                  reachedEnd: true, reachedSince: false)
        #expect(done == Store.CrawlState(lowest: 1, highest: 160, backfillComplete: true))
    }

    /// 🔍 Word hits filled `limit`, and truncation discarded every substring-only hit unseen.
    @Test("combined search orders substring-only hits after word hits and counts a cut tail")
    func combinedSearchReportsTruncatedTail() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [Self.post(1, "swift news"), Self.post(2, "swift tips"),
                                 Self.post(3, "SwiftUI layout")])
        let cut = try store.search("swift", mode: .both, limit: 2)
        #expect(cut.hits.map(\.id.messageID).sorted() == [1, 2])
        #expect(cut.total == 3, "the SwiftUI post matches and must be reported, not dropped")
        let all = try store.search("swift", mode: .both, limit: 10)
        #expect(all.hits.last?.id.messageID == 3, "word hits first, substring-only after")
        #expect(try store.search("swift", mode: .words, limit: 10).total == 2)
    }
}
