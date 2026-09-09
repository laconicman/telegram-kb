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
        #expect(try store.importResolutions(fromJSONLAt: path) == 3)

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
