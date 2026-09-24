import Foundation
import GRDB
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

    /// The seam contract behind `find_links`: match on the link's EFFECTIVE URL against the
    /// query's — a shortener query must find the destination's posts, and a destination query
    /// must find every spelling that resolved to it (S6).
    @Test("links(to:) joins a shortener and its destination both ways")
    func linksFollowResolution() throws {
        let (store, _) = try Self.seeded()
        let short = "https://clck.ru/33ABCD"
        let dest = "https://habr.com/ru/post/1"
        try store.upsert(posts: [
            Self.post(1, "через сокращатель", links: [LinkRef(urlRaw: short)]),
            Self.post(2, "напрямую", links: [LinkRef(urlRaw: dest + "?utm_source=tg")]),
            Self.post(3, "не то", links: [LinkRef(urlRaw: "https://example.com/other")]),
        ])
        let shortCanonical = try #require(URLCanonicaliser.canonicalise(short))
        let destCanonical = try #require(URLCanonicaliser.canonicalise(dest))

        // Before any resolution the shortener is a destination of its own.
        #expect(try store.links(to: short).map(\.id.messageID) == [1])
        #expect(try store.links(to: dest).map(\.id.messageID) == [2])

        try store.upsert(resolutions: [URLResolution(
            urlCanonical: shortCanonical, resolvedCanonical: destCanonical,
            httpStatus: "200", hops: 1, resolvedAt: Date())])

        // Once resolved, the shortener query finds the destination post too — and vice versa.
        #expect(try store.links(to: short).map(\.id.messageID) == [1, 2])
        #expect(try store.links(to: dest).map(\.id.messageID) == [1, 2])
        let hit = try store.links(to: dest).first { $0.id.messageID == 1 }
        #expect(hit?.urlRaw == short)
        #expect(hit?.effectiveURL == destCanonical)
    }

    @Test("links(to:) falls back to the raw spelling when the URL cannot be canonicalised")
    func linksMatchRawWhenNotCanonicalisable() throws {
        let (store, _) = try Self.seeded()
        // ftp:// is a real URL Telegram renders, but the canonical spec is http(s)-only,
        // so the link is stored with urlCanonical NULL.
        try store.upsert(posts: [
            Self.post(4, "файл", links: [LinkRef(urlRaw: "ftp://files.example.com/x")])])
        #expect(try store.links(to: "ftp://files.example.com/x").map(\.id.messageID) == [4])
    }

    @Test("posts(ids:) hydrates a page in input order and skips a missing post")
    func postsHydrateInOrder() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [Self.post(1, "a"), Self.post(2, "b"), Self.post(3, "c")])
        let ids = [Post.ID(channelUsername: "iosgr", messageID: 3),
                   Post.ID(channelUsername: "iosgr", messageID: 99),
                   Post.ID(channelUsername: "iosgr", messageID: 1)]
        #expect(try store.posts(ids: ids).map(\.id.messageID) == [3, 1])
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
        // Round 5 changed this from "keep the old mark", which never closed a gap wider than the
        // cap (TD-18). See `cappedIncrementalResumesThroughTheGap`.
        #expect(stoppedShort.since(full: false) == nil, "a capped walk left 101...140 unfetched")
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

/// Round-5 review findings on the store.
extension StoreTests {

    static func commit(_ store: Store, _ state: Store.CrawlState, _ range: ClosedRange<Int>) throws {
        try store.commitPage(range.map { Self.post($0, "p\($0)") }, channel: "iosgr",
                             lowest: state.lowest, highest: state.highest,
                             backfillComplete: state.backfillComplete, policy: .keepExisting)
    }

    /// 🟡 With more new pages than the cap, every run walked the newest pages, kept the old mark
    /// and started again — the gap below never entered the store (TD-18).
    @Test("a capped incremental walk becomes a resumable backfill that crosses the gap")
    func cappedIncrementalResumesThroughTheGap() {
        let finished = Store.CrawlState(lowest: 1, highest: 100, backfillComplete: true)
        // New posts reach 20,000; the capped walk got down to 10,001.
        let capped = finished.afterWalk(lowest: 10_001, highest: 20_000, full: false,
                                        reachedEnd: false, reachedSince: false)
        #expect(capped == Store.CrawlState(lowest: 10_001, highest: 20_000, backfillComplete: false))
        #expect(capped.resumeFrom(full: false) == 10_001, "the next run starts below what it has")
        #expect(capped.since(full: false) == nil, "and does not stop at the new top")
        let done = capped.afterWalk(lowest: 1, highest: 10_000, full: false,
                                    reachedEnd: true, reachedSince: false)
        #expect(done == Store.CrawlState(lowest: 1, highest: 20_000, backfillComplete: true))
    }

    /// 🔍 The interruption matrix in REVIEW.md names four walks; two had no test.
    @Test("an interrupted resumed backfill keeps its top and resumes below the page it wrote")
    func interruptedResumedBackfill() throws {
        let (store, _) = try Self.seeded()
        try store.recordCrawlState(channel: "iosgr", lowest: 500, highest: 1000, backfillComplete: false)
        let before = try store.crawlState(forChannel: "iosgr")
        #expect(before.resumeFrom(full: false) == 500)
        try Self.commit(store, before.afterPage(lowest: 480, highest: 499, full: false), 480...499)

        let after = try store.crawlState(forChannel: "iosgr")
        #expect(after == Store.CrawlState(lowest: 480, highest: 1000, backfillComplete: false))
        #expect(after.resumeFrom(full: false) == 480 && after.since(full: false) == nil)
    }

    @Test("an interrupted --full over a finished channel stays finished and loses nothing")
    func interruptedFullOverFinishedChannel() throws {
        let (store, _) = try Self.seeded()
        try store.recordCrawlState(channel: "iosgr", lowest: 1, highest: 1000, backfillComplete: true)
        let before = try store.crawlState(forChannel: "iosgr")
        try Self.commit(store, before.afterPage(lowest: 981, highest: 1100, full: true), 981...1100)

        let after = try store.crawlState(forChannel: "iosgr")
        #expect(after.backfillComplete,
                "the refresh removed nothing; clearing the flag would re-walk all history for nothing")
        #expect(after.since(full: false) == 1100, "a plain sync continues above what the refresh reached")
    }

    @Test("an interrupted --full over an unfinished channel resumes below the page it wrote")
    func interruptedFullOverUnfinishedChannel() throws {
        let (store, _) = try Self.seeded()
        try store.recordCrawlState(channel: "iosgr", lowest: 500, highest: 1000, backfillComplete: false)
        let before = try store.crawlState(forChannel: "iosgr")
        try Self.commit(store, before.afterPage(lowest: 981, highest: 1100, full: true), 981...1100)

        let after = try store.crawlState(forChannel: "iosgr")
        #expect(after == Store.CrawlState(lowest: 981, highest: 1100, backfillComplete: false))
        #expect(after.resumeFrom(full: false) == 981, "posts below 981 are not proven stored")
    }

    /// 🟡 Sync wrote a full channel row carrying only the id, nulling metadata from elsewhere.
    @Test("recording a crawled identity leaves title and subscriber count alone")
    func identityUpdateKeepsMetadata() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(channel: Channel(username: "iosgr", rawChannelID: 1, title: "iOS Good Reads",
                                          subscriberCount: 1234, reachability: .previewDisabled))
        try store.updateIdentity(channel: "iosgr", rawChannelID: 1_076_035_790, reachability: .webPreview)
        let row = try #require(try store.dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM channel WHERE username = 'iosgr'") })
        #expect(row["title"] as String? == "iOS Good Reads")
        #expect(row["subscriberCount"] as Int? == 1234)
        #expect(row["rawChannelID"] as Int64? == 1_076_035_790)
        #expect(row["reachability"] as String? == Channel.Reachability.webPreview.rawValue)
    }

    /// 🟡 A row with a bad `resolved_at` decoded fine and was stamped "now".
    @Test("a resolution with an unparseable timestamp is counted as unreadable, not stamped now")
    func malformedTimestampIsSkipped() throws {
        let (store, _) = try Self.seeded()
        let jsonl = """
        {"url_canonical":"https://a.example","final_url":"https://a.example","http_status":200,"hops":0,"resolved_at":"2026-09-05T22:50:59.691197+00:00"}
        {"url_canonical":"https://b.example","final_url":"https://b.example","http_status":200,"hops":0,"resolved_at":"yesterday"}
        """
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("res-\(UUID().uuidString).jsonl").path
        try jsonl.write(toFile: path, atomically: true, encoding: .utf8)

        let report = try store.importResolutions(fromJSONLAt: path)
        #expect(report.imported == 1 && report.skipped == 1)
        let stored = try store.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT urlCanonical FROM urlResolution ORDER BY urlCanonical") }
        #expect(stored == ["https://a.example"], "the malformed row must not be imported as fresh")
    }
}

/// Round-6 review findings on the store.
extension StoreTests {

    /// 🟡 A non-string, non-integer `http_status` decoded as `""`, which read as "checked and
    /// failed" — so the import overwrote a good resolution with a failed observation.
    @Test("a resolution whose http_status is neither string nor number is unreadable, not failed")
    func malformedStatusIsSkipped() throws {
        let (store, _) = try Self.seeded()
        let good = #"{"url_canonical":"https://a.example","final_url":"https://a.example/x","http_status":200,"hops":1,"resolved_at":"2026-09-05T22:50:59.691197+00:00"}"#
        let bad = #"{"url_canonical":"https://a.example","final_url":"https://a.example","http_status":{"code":500},"hops":0,"resolved_at":"2026-09-05T22:51:00.000000+00:00"}"#
        func importing(_ jsonl: String) throws -> Store.ImportReport {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("res-\(UUID().uuidString).jsonl").path
            try jsonl.write(toFile: path, atomically: true, encoding: .utf8)
            return try store.importResolutions(fromJSONLAt: path)
        }
        #expect(try importing(good).imported == 1)
        let report = try importing(bad)
        #expect(report.imported == 0 && report.skipped == 1)
        #expect(try store.effectiveURL(forCanonical: "https://a.example") == "https://a.example/x",
                "the valid resolution must survive a malformed row for the same URL")
    }

    /// 🔍 Integrity materialised every id between the bounds, so its cost tracked the id RANGE.
    /// TDLib ids are spaced by 2^20, which would make that unusable.
    @Test("integrity cost follows the number of posts, not the width of the id range")
    func integrityDoesNotScanTheIDSpan() throws {
        let (store, _) = try Self.seeded()
        // Three posts spread over a billion ids — the old implementation inserted 10^9 ids.
        try store.upsert(posts: [Self.post(1, "first"), Self.post(500_000_000, "middle"),
                                 Self.post(1_000_000_000, "last")])
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let i = try #require(try store.integrity(forChannel: "iosgr"))
            #expect(i.posts == 3 && i.covered == 3 && i.lowest == 1 && i.highest == 1_000_000_000)
            // Two gaps: 2…499,999,999 and 500,000,001…999,999,999. The second is one longer.
            #expect(i.longestGap == 499_999_999 && i.longestGapStart == 500_000_001)
        }
        #expect(elapsed < .seconds(1), "a span-sized scan would take far longer than this")
    }

    /// 🔍 `search` read every hit from both indexes to report `total`, so a 20-row page held
    /// thousands of rows.
    @Test("a small page reads a small page, and still reports the true total")
    func searchPageIsBounded() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: (1...50).map { Self.post($0, "swift post \($0)") }
                       + [Self.post(51, "SwiftUI only")])
        let page = try store.search("swift", mode: .both, limit: 5)
        #expect(page.hits.count == 5)
        #expect(page.total == 51, "50 word hits plus the substring-only SwiftUI post")
        // The substring-only tail is still reachable by asking for more.
        let all = try store.search("swift", mode: .both, limit: 100)
        #expect(all.hits.count == 51 && all.hits.last?.id.messageID == 51)
        #expect(try store.search("swift", mode: .words, limit: 5).total == 50)
        #expect(try store.search("swiftui", mode: .substring, limit: 5).total == 1)
    }
}

extension StoreTests {
    /// Two `tgkb sync` processes are two writers on one file. Without a busy timeout the second
    /// fails the instant the first holds the lock, rather than waiting out a page commit.
    @Test("a second writer waits for the lock instead of failing immediately")
    func secondWriterWaitsForTheLock() async throws {
        let path = Self.tempPath()
        let first = try Store.openForWriting(at: path)
        let second = try Store.openForWriting(at: path)

        let holding = Task.detached {
            try first.dbPool.write { db in
                try db.execute(sql: "INSERT INTO channel (username, rawChannelID, reachability) VALUES ('held', 1, 'webPreview')")
                Thread.sleep(forTimeInterval: 0.4)   // hold the write lock
            }
        }
        try await Task.sleep(for: .milliseconds(120))
        try second.ensureChannel(username: "waited", reachability: .webPreview)   // must not throw
        try await holding.value
        #expect(try second.channelUsernames() == ["held", "waited"])
    }
}

/// Round-8: the claim that a combined page can come back short of `limit` while more
/// substring-only matches exist. The bound that decides it: substring candidates are fetched
/// only when the word page did NOT fill, and that is exactly when the word set is complete — so
/// at most `words.count` of those candidates can be duplicates.
extension StoreTests {
    @Test("a combined page is never short while more matches exist",
          arguments: [1, 2, 3, 5, 9, 10, 11, 20, 31, 40, 50])
    func combinedPageIsNeverShort(limit: Int) throws {
        let (store, _) = try Self.seeded()
        // Heavy overlap on purpose: 30 posts match both indexes, 5 match only the trigram one.
        try store.upsert(posts: (1...30).map { Self.post($0, "swift core swift \($0)") }
                       + (31...35).map { Self.post($0, "SwiftUI layout \($0)") })
        let page = try store.search("swift", mode: .both, limit: limit)
        #expect(page.total == 35)
        #expect(page.hits.count == min(limit, page.total),
                "a page must fill while matches remain (limit \(limit))")
        #expect(Set(page.hits.map(\.id)).count == page.hits.count, "no duplicates across indexes")
    }
}

/// Round-10: `--full` may replace the bounds, but a walk that fetched nothing has nothing to
/// replace them with — writing its nils back sent every later sync into a fresh backfill.
extension StoreTests {
    @Test("a --full walk that fetched nothing leaves the bounds alone")
    func emptyFullWalkKeepsBounds() {
        let before = Store.CrawlState(lowest: 1, highest: 1000, backfillComplete: true)
        let after = before.afterWalk(lowest: nil, highest: nil, full: true,
                                     reachedEnd: false, reachedSince: false)
        #expect(after.lowest == 1 && after.highest == 1000)
        #expect(after.backfillComplete, "and it must not undo a completed backfill either")
        // A --full walk that DID fetch still replaces, which is the point of the flag.
        #expect(before.afterWalk(lowest: 500, highest: 1200, full: true,
                                 reachedEnd: false, reachedSince: false).lowest == 500)
    }
}

/// Phrase search: quoting a run of words makes their ORDER part of the query. Word search ANDs
/// its terms, so without this `адаптивная вёрстка` and `вёрстка адаптивная` were the same query.
extension StoreTests {

    static func phraseStore() throws -> Store {
        let (store, _) = try seeded()
        try store.upsert(posts: [
            post(1, "Адаптивная вёрстка экрана на SwiftUI"),
            post(2, "Вёрстка адаптивная — обратный порядок слов"),
            post(3, "Просто вёрстка, без второго слова"),
        ])
        return store
    }

    @Test("a quoted phrase matches in order; unquoted terms still match in any order")
    func phraseRespectsOrder() throws {
        let store = try Self.phraseStore()
        let phrase = try store.search("\"адаптивная вёрстка\"", mode: .words, limit: 10)
        #expect(phrase.hits.map(\.id.messageID) == [1], "only the post with that word order")
        #expect(phrase.total == 1, "and the count agrees with the page")

        let loose = try store.search("адаптивная вёрстка", mode: .words, limit: 10)
        #expect(Set(loose.hits.map(\.id.messageID)) == [1, 2], "unquoted is still an AND of terms")
    }

    @Test("phrase search ignores case and ё, like every other query here")
    func phraseIgnoresCaseAndYo() throws {
        let store = try Self.phraseStore()
        for query in ["\"АДАПТИВНАЯ ВЁРСТКА\"", "\"адаптивная верстка\"", "«Адаптивная Вёрстка»"] {
            #expect(try store.search(query, mode: .words, limit: 10).hits.map(\.id.messageID) == [1],
                    "\(query) must find the same post")
        }
    }

    @Test("a phrase combines with loose terms, and an unclosed quote is treated as words")
    func phraseCombinesAndToleratesTypos() throws {
        let store = try Self.phraseStore()
        #expect(try store.search("\"адаптивная вёрстка\" SwiftUI", mode: .words, limit: 10)
                    .hits.map(\.id.messageID) == [1])
        #expect(try store.search("\"адаптивная вёрстка\" отсутствует", mode: .words, limit: 10)
                    .hits.isEmpty, "the loose term still has to match")
        // An unclosed quote is a typo, not a reason to return nothing.
        #expect(!(try store.search("\"адаптивная вёрстка", mode: .words, limit: 10).hits.isEmpty))
    }

    @Test("quotes are not operators: a searcher cannot inject FTS5 syntax")
    func quotedTextCannotBecomeAnOperator() throws {
        let store = try Self.phraseStore()
        // `OR`, `NOT` and `*` are FTS5 operators. Inside a phrase they must be literal text,
        // and none of these queries may throw or match everything.
        for query in ["\"вёрстка OR swiftui\"", "\"вёрстка\" NOT", "вёрстка*", "\"\"", "\"*\""] {
            let results = try store.search(query, mode: .both, limit: 10)
            #expect(results.hits.count <= 3, "\(query) must not match beyond the corpus")
        }
    }

    @Test("a quoted phrase in substring mode matches the literal text, quotes stripped")
    func phraseInSubstringMode() throws {
        let store = try Self.phraseStore()
        #expect(try store.search("\"адаптивная вёрстка\"", mode: .substring, limit: 10)
                    .hits.map(\.id.messageID) == [1])
    }
}

/// Round-12 and 13 findings on search.
extension StoreTests {

    /// 🟡 Surface text and lemmas shared one column separated by a newline, which FTS5 tokenises
    /// away — so a phrase could match the last word of the text beside the first lemma, in a post
    /// containing that phrase in neither form.
    @Test("a phrase cannot straddle the text and the lemmas")
    func phraseDoesNotCrossTheLemmaBoundary() throws {
        let (store, _) = try Self.seeded()
        // Indexed as text "кошка сидела на окне" and lemmas "кошка сидеть на окно".
        try store.upsert(posts: [Self.post(1, "Кошка сидела на окне")])
        #expect(try store.search("\"окне кошка\"", mode: .words, limit: 10).hits.isEmpty,
                "the last word of the text is not adjacent to the first lemma")
        #expect(try store.search("\"кошка сидела\"", mode: .words, limit: 10).hits.count == 1,
                "a phrase within the text still matches")
    }

    /// 🟡 A query carrying any phrase stopped lemmatising its loose terms, so it found less than
    /// the same words unquoted.
    @Test("loose terms beside a phrase are still lemmatised")
    func looseTermsKeepTheirLemmasBesideAPhrase() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [Self.post(1, "Тут про навигацию в SwiftUI сегодня")])
        // The query term is the inflected one: a bare term already reaches the lemmas column, so
        // only lemmatising the TERM connects "навигацией" to a post carrying "навигацию".
        #expect(try store.search("\"в swiftui\" навигацией", mode: .words, limit: 10).hits.count == 1,
                "a loose term must still be lemmatised while a phrase is present")
    }

    /// 🟡 Substring search is literal, and grouping the phrases first searched a sequence the
    /// searcher never typed.
    @Test("a substring query keeps the order it was typed in")
    func substringKeepsTypedOrder() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [Self.post(1, "swift чистая архитектура в проекте")])
        #expect(try store.search("swift \"чистая архитектура\"", mode: .substring, limit: 10)
                    .hits.count == 1, "the literal text runs in the typed order")
    }

    /// 🔍 SQLite reads a negative LIMIT as unlimited, so a caller asking for less than nothing
    /// received the whole corpus.
    @Test("a negative limit returns nothing, not everything")
    func negativeLimitIsNotUnlimited() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: (1...5).map { Self.post($0, "swift \($0)") })
        #expect(try store.searchWords("swift", limit: -1).isEmpty)
        #expect(try store.searchSubstring("swift", limit: -1).isEmpty)
        #expect(try store.searchWords("swift", limit: nil).count == 5, "nil still means every match")
    }
}

/// The `v4` migration recreates `postFTS` and refills it through `rebuildWordIndex`. Found by
/// self-review: the first version skipped a mapping whose post had gone, leaving a row pointing
/// at nothing and a post missing from the index with nothing saying so.
extension StoreTests {
    @Test("rebuilding the word index re-indexes posts and drops mappings pointing at nothing")
    func rebuildDropsStaleMappings() throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: [Self.post(1, "адаптивная вёрстка"), Self.post(2, "swift concurrency")])

        let report: (indexed: Int, staleRemoved: Int) = try store.dbPool.write { db in
            // A mapping whose post is gone — what the migration has to cope with.
            try db.execute(sql: "DELETE FROM post WHERE messageID = 2")
            return try Store.rebuildWordIndex(in: db)
        }
        #expect(report == (indexed: 1, staleRemoved: 1))

        #expect(try store.searchWords("вёрстка").count == 1, "the surviving post is still findable")
        #expect(try store.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM ftsMap") } == 1,
                "the mapping pointing at nothing is gone, not left behind")

        // And every index row with it: the trigram table is NOT recreated by the migration, so a
        // survivor there would be counted by `matchCount` and missing from the page — a total
        // that disagrees with what it summarises.
        let gone = try store.search("concurrency", mode: .both, limit: 10)
        #expect(gone.hits.isEmpty && gone.total == 0,
                "the deleted post must not survive in either index, in the page or in the count")
    }
}

/// Track A for S6: filters, an opaque cursor, and a `total` that counts what the page can return.
extension StoreTests {

    static func filterStore() throws -> Store {
        let (store, _) = try seeded()
        try store.upsert(channel: Channel(username: "iosdev", rawChannelID: 2))
        func post(_ channel: String, _ mid: Int, _ text: String, kind: PostKind, day: Int) -> Post {
            Post(id: .init(channelUsername: channel, messageID: mid),
                 date: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400),
                 kind: kind, formatSource: .web, mediaCount: 1, text: text)
        }
        try store.upsert(posts: (1...12).map { post("iosgr", $0, "swift concurrency \($0)", kind: .text, day: $0) }
                       + [post("iosgr", 20, "swift photo post", kind: .photo, day: 20)]
                       + (1...5).map { post("iosdev", $0, "swift elsewhere \($0)", kind: .text, day: $0) })
        return store
    }

    @Test("a channel filter narrows the page AND the count together")
    func filterByChannel() throws {
        let store = try Self.filterStore()
        let all = try store.search("swift", mode: .both, limit: 100)
        #expect(all.total == 18)

        let one = try store.search("swift", mode: .both, filter: .init(channel: "iosdev"), limit: 100)
        #expect(one.total == 5, "the count must not promise posts the filter excludes")
        #expect(one.hits.allSatisfy { $0.id.channelUsername == "iosdev" })
        // Casing is folded at the boundary, as everywhere else.
        #expect(try store.search("swift", mode: .both, filter: .init(channel: "IOSDev"), limit: 100).total == 5)
    }

    @Test("kind and date filters narrow to what they name")
    func filterByKindAndDate() throws {
        let store = try Self.filterStore()
        #expect(try store.search("swift", mode: .both, filter: .init(kind: .photo), limit: 100)
                    .hits.map(\.id.messageID) == [20])

        let firstWeek = Date(timeIntervalSince1970: 1_700_000_000 + 5 * 86_400)
        let early = try store.search("swift", mode: .both,
                                     filter: .init(channel: "iosgr", to: firstWeek), limit: 100)
        #expect(early.total == 5 && early.hits.count == 5, "days 1 to 5 in that channel")
    }

    /// The page must walk the result set once: no gaps, no repeats, and a cursor that stops.
    @Test("paging with the cursor covers every hit exactly once")
    func cursorPagesWithoutGapsOrRepeats() throws {
        let store = try Self.filterStore()
        let everything = try store.search("swift", mode: .both, limit: 100)

        var collected: [Post.ID] = []
        var cursor: String? = nil
        var pages = 0
        repeat {
            let page = try store.search("swift", mode: .both, limit: 5, cursor: cursor)
            #expect(page.total == everything.total, "the total does not drift between pages")
            collected += page.hits.map(\.id)
            cursor = page.nextCursor
            pages += 1
            #expect(pages < 10, "pagination must terminate")
        } while cursor != nil

        #expect(collected.count == everything.total)
        #expect(Set(collected).count == collected.count, "no post appears on two pages")
        #expect(collected == everything.hits.map(\.id), "and in the same order as one big page")
    }

    @Test("a cursor belongs to its query, and a foreign or broken one is refused")
    func cursorIsBoundToItsQuery() throws {
        let store = try Self.filterStore()
        let first = try store.search("swift", mode: .both, limit: 5)
        let cursor = try #require(first.nextCursor)

        // Same cursor, different query — a silent slice of another result set if accepted.
        #expect(throws: Store.SearchError.cursorDoesNotMatchQuery) {
            try store.search("concurrency", mode: .both, limit: 5, cursor: cursor)
        }
        // Same query, different filter.
        #expect(throws: Store.SearchError.cursorDoesNotMatchQuery) {
            try store.search("swift", mode: .both, filter: .init(channel: "iosgr"), limit: 5, cursor: cursor)
        }
        #expect(throws: Store.SearchError.cursorMalformed) {
            try store.search("swift", mode: .both, limit: 5, cursor: "not-a-cursor")
        }
    }

    @Test("the last page carries no cursor")
    func lastPageEndsPagination() throws {
        let store = try Self.filterStore()
        let onePage = try store.search("swift", mode: .both, limit: 100)
        #expect(onePage.nextCursor == nil, "everything fitted, so there is nothing to continue")
        let empty = try store.search("гравитационные волны", mode: .both, limit: 5)
        #expect(empty.hits.isEmpty && empty.total == 0 && empty.nextCursor == nil)
    }
}

extension StoreTests {
    /// Paging is where an off-by-one hides. Walk the whole result set at several page sizes and
    /// in every mode, over a corpus built so the two indexes overlap heavily.
    @Test("paging covers the result set exactly, at any page size and in any mode",
          arguments: [1, 2, 3, 7, 18, 50] as [Int])
    func pagingIsExhaustiveAtEveryPageSize(pageSize: Int) throws {
        let (store, _) = try Self.seeded()
        try store.upsert(posts: (1...20).map { Self.post($0, "swift concurrency \($0)") }
                       + (21...25).map { Self.post($0, "SwiftUI only \($0)") })

        for mode in Store.SearchMode.allCases {
            let whole = try store.search("swift", mode: mode, limit: 1000)
            var collected: [Post.ID] = []
            var cursor: String? = nil
            var guard_ = 0
            repeat {
                let page = try store.search("swift", mode: mode, limit: pageSize, cursor: cursor)
                #expect(page.hits.count <= pageSize)
                collected += page.hits.map(\.id)
                cursor = page.nextCursor
                guard_ += 1
                #expect(guard_ <= whole.total + 2, "\(mode) at page size \(pageSize) did not terminate")
            } while cursor != nil

            #expect(collected == whole.hits.map(\.id),
                    "\(mode) at page size \(pageSize): paged order must equal the single-page order")
            #expect(Set(collected).count == collected.count, "\(mode): a post appeared twice")
            #expect(collected.count == whole.total, "\(mode): paging lost \(whole.total - collected.count) hit(s)")
        }
    }
}

extension StoreTests {
    /// A sync landing between two pages re-ranks the result set, so an offset no longer points
    /// where it did. The page still comes back — refusing it would break paging after every sync —
    /// but it says the ground moved, because a silently skipped post is the failure this project
    /// refuses.
    @Test("a page served after the corpus moved says so")
    func pagingReportsCorpusDrift() throws {
        let store = try Self.filterStore()
        let first = try store.search("swift", mode: .both, limit: 5)
        let cursor = try #require(first.nextCursor)
        #expect(!first.indexMovedSinceCursor, "a first page has nothing to compare against")

        let quiet = try store.search("swift", mode: .both, limit: 5, cursor: cursor)
        #expect(!quiet.indexMovedSinceCursor, "nothing was written between the pages")

        try store.upsert(posts: [Self.post(999, "swift arrived mid-pagination")])
        let moved = try store.search("swift", mode: .both, limit: 5, cursor: cursor)
        #expect(moved.indexMovedSinceCursor, "the corpus changed under the walk and must say so")
        #expect(!moved.hits.isEmpty, "and the page is still served, not refused")
    }

    /// Filter values are bound parameters, never string-built SQL. The sanctioned path for text
    /// arriving from an LLM tool call, applied to the filter as well as the query.
    @Test("a filter value cannot break out of its placeholder")
    func filterValuesAreBound() throws {
        let store = try Self.filterStore()
        for hostile in ["iosgr' OR 1=1 --", "'; DROP TABLE post; --", "iosgr\" OR \"\"=\""] {
            let results = try store.search("swift", mode: .both, filter: .init(channel: hostile), limit: 100)
            #expect(results.hits.isEmpty && results.total == 0, "\(hostile) matched nothing, as a channel name")
        }
        // The table is still there, which is the other half of the assertion.
        #expect(try store.search("swift", mode: .both, limit: 100).total == 18)
    }
}

/// PR #2, review round 1.
extension StoreTests {

    /// 🔴 A cursor is text from a model. One decoding to an offset near Int.max made
    /// `offset + limit` overflow and trap the process, instead of being refused.
    @Test("an absurd cursor offset is refused, not a crash")
    func hugeCursorOffsetIsRefused() throws {
        let store = try Self.filterStore()
        let first = try store.search("swift", mode: .both, limit: 5)
        let real = try #require(first.nextCursor)
        let decoded = try #require(Store.Cursor.decode(real))
        for offset in [Int.max, Int.max - 1, Store.Cursor.maxOffset + 1] {
            let forged = Data("2:\(offset):\(decoded.fingerprint):\(decoded.generation)".utf8).base64EncodedString()
            #expect(throws: Store.SearchError.cursorMalformed) {
                try store.search("swift", mode: .both, limit: 5, cursor: forged)
            }
        }
    }

    /// 🟡 The generation was derived from the newest sync time and the number of indexed posts.
    /// A post replaced in place changes neither, so drift went unreported.
    @Test("replacing a post in place still reports drift to a paging walk")
    func inPlaceReplacementReportsDrift() throws {
        let store = try Self.filterStore()
        let cursor = try #require(try store.search("swift", mode: .both, limit: 5).nextCursor)
        // Same id, new text: no new row, no sync — the case the old heuristic missed.
        try store.upsert(posts: [Self.post(3, "swift concurrency rewritten")], policy: .replace)
        #expect(try store.search("swift", mode: .both, limit: 5, cursor: cursor).indexMovedSinceCursor)
    }

    /// 🟡 `filter.channel = "IOSDev"` bypassed the initialiser's lowercasing and matched nothing.
    @Test("a channel assigned after initialisation is folded too")
    func assignedChannelIsFolded() throws {
        let store = try Self.filterStore()
        var filter = Store.SearchFilter()
        filter.channel = "IOSDev"
        #expect(filter.channel == "iosdev")
        #expect(try store.search("swift", mode: .both, filter: filter, limit: 100).total == 5)
    }

    /// 🔍 bm25 ties are common, and ORDER BY rank alone left them arbitrary — so the same offset
    /// could point at a different post on the next page even with nothing written in between.
    @Test("equal-ranked hits come back in one deterministic order")
    func tiesAreOrderedByIdentity() throws {
        let (store, _) = try Self.seeded()
        // Identical text, so identical bm25: only the tie-break decides the order.
        try store.upsert(posts: [30, 10, 20, 40].map { Self.post($0, "одинаковый текст") })
        for _ in 0..<3 {
            #expect(try store.search("одинаковый", mode: .words, limit: 10).hits.map(\.id.messageID)
                    == [10, 20, 30, 40])
        }
    }

    /// 🔍 The fingerprint hashed the raw spelling, so two queries that run the same search refused
    /// each other's cursors.
    @Test("spellings that run the same search share a cursor")
    func equivalentSpellingsShareACursor() throws {
        let store = try Self.filterStore()
        let cursor = try #require(try store.search("Swift", mode: .both, limit: 5).nextCursor)
        let next = try store.search("swift", mode: .both, limit: 5, cursor: cursor)
        #expect(!next.hits.isEmpty, "a cursor from `Swift` continues a search for `swift`")
    }
}

/// PR #2, review round 2.
extension StoreTests {

    /// 🔴 + 🔍 Every earlier migration test started from an EMPTY file, and an empty v3 store has
    /// nothing to rebuild — so v4's rebuild never ran the indexing code that now needs v5's
    /// `indexState`, and "no such table" stayed invisible. Reproduced on a real 155-post v3 store
    /// before the fix; this builds a populated v3 store hermetically instead.
    @Test("a populated store from before v4 upgrades through every later migration")
    func populatedV3StoreUpgrades() throws {
        let path = Self.tempPath()
        do {
            let queue = try DatabaseQueue(path: path)
            try Schema.migrator.migrate(queue, upTo: "v3-watermarks-in-channel")
            try queue.write { db in
                // What v3-era code wrote: a channel, a post, its mapping, and single-column FTS rows.
                try db.execute(sql: "INSERT INTO channel (username, rawChannelID, reachability) VALUES ('iosgr', 1, 'webPreview')")
                try db.execute(sql: """
                    INSERT INTO post (channelUsername, messageID, date, kind, formatSource, text)
                    VALUES ('iosgr', 7, ?, 'text', 'web', 'Навигация в SwiftUI')
                    """, arguments: [Date()])
                try db.execute(sql: "INSERT INTO ftsMap (rowid, channelUsername, messageID) VALUES (1, 'iosgr', 7)")
                try db.execute(sql: "INSERT INTO postFTS (rowid, content) VALUES (1, 'навигация в swiftui')")
                try db.execute(sql: "INSERT INTO postTrigram (rowid, content) VALUES (1, 'навигация в swiftui')")
            }
        }
        let store = try Store.openForWriting(at: path)   // runs v4 then v5 over real rows
        #expect(try store.searchWords("навигация").map(\.id.messageID) == [7],
                "the post survives the upgrade and is findable through the rebuilt index")
        #expect(try store.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT generation FROM indexState WHERE id = 1") } ?? 0 > 0,
                "the rebuild recorded its writes in the generation")
    }

    /// 🔴 `limit: Int.max` made the substring bound `end + words.count` overflow and trap.
    @Test("an enormous page size is clamped, not a crash")
    func hugePageSizeIsClamped() throws {
        let store = try Self.filterStore()
        let page = try store.search("swift", mode: .both, limit: .max)
        #expect(page.hits.count == page.total, "clamped to a page far above the corpus, so everything fits")
    }

    /// 🟡 Separator-joined fields let a query containing the separator shift the boundaries, so two
    /// different searches produced one fingerprint and accepted each other's cursors.
    @Test("fingerprints cannot be forged by shifting field boundaries")
    func fingerprintFieldsAreUnambiguous() {
        let s = "\u{1}"
        // Under the old encoding these two joined to the same string: a|both|b|both|c.
        let one = Store.Cursor.fingerprint(query: "a\(s)both\(s)b", mode: .both,
                                           filter: .init(channel: "c"))
        let two = Store.Cursor.fingerprint(query: "a", mode: .both,
                                           filter: .init(channel: "b\(s)both\(s)c"))
        #expect(one != two)
    }
}
