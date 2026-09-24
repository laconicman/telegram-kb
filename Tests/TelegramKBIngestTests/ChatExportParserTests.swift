import Foundation
import Testing
@testable import TelegramKBIngest
import TelegramKBModel

/// The HTML chat export, against a synthetic two-page export modelled on a real one.
///
/// Every expectation here was first observed on the real export — 12,471 messages of a public
/// group, parsed with no unreadable block — and is pinned on invented content so the fixture
/// carries no one's messages.
struct ChatExportParserTests {

    static let moscow = TimeZone(identifier: "Europe/Moscow")!
    static let observed = Date(timeIntervalSince1970: 1_790_000_000)

    static func page(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/export/\(name)", withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func export() throws -> ChatExportParser.Export {
        try ChatExportParser.parse(pages: [page("messages"), page("messages2")], channel: "testgroup",
                                   timeZone: moscow, observedAt: observed)
    }

    static func post(_ id: Int) throws -> Post {
        try #require(try export().posts.first { $0.id.messageID == id })
    }

    @Test("reads every message, counts service messages, and counts what it cannot read")
    func counts() throws {
        let export = try Self.export()
        #expect(export.title == "Static Analysis Test Chat")
        #expect(export.posts.map(\.id.messageID) == [10, 11, 12, 13, 14, 20, 21, 22, 23, 24, 25])
        #expect(export.serviceMessages == 2, "the renaming and the join; a day separator has no id")
        #expect(export.unreadable == 2, "a date that is not a date, and a block with no id")
        #expect(export.posts.allSatisfy { $0.formatSource == .export && $0.id.channelUsername == "testgroup" })
    }

    /// The title carries no offset. Measured against `t.me` embeds, it is the exporting machine's
    /// local time: 12:34:07 in Moscow is 09:34:07 UTC.
    @Test("dates are read in the exporting machine's zone")
    func datesUseTheGivenZone() throws {
        #expect(try Self.post(10).date == ISO8601DateFormatter().date(from: "2023-04-03T09:34:07Z"))
    }

    @Test("an edited message keeps its send time, and is marked edited")
    func edited() throws {
        let post = try Self.post(11)
        #expect(post.isEdited)
        #expect(post.date == ISO8601DateFormatter().date(from: "2023-04-03T09:40:00Z"))
        #expect(try !Self.post(10).isEdited)
    }

    @Test("a joined message takes the sender before it — across a page, and past an unreadable block")
    func joinedSendersCarryOver() throws {
        #expect(try Self.post(11).authorName == "Alice Example")
        #expect(try Self.post(14).authorName == "Carol Example")
        #expect(try Self.post(20).authorName == "Dave Example",
                "message 15 was unreadable, but it still named the sender message 20 continues from")
    }

    @Test("text keeps its line breaks and its code blocks")
    func textWalk() throws {
        #expect(try Self.post(10).text.hasPrefix("Первая строка про @someone\nВторая строка"))
        #expect(try Self.post(11).text.contains("make: *** [all] Error 1\nexit 2"))
    }

    @Test("a mention is a t.me link, as on the web; a cashtag is not a hashtag")
    func mentionsAndTags() throws {
        let post = try Self.post(10)
        #expect(post.links.map(\.urlRaw) == ["https://t.me/someone"])
        #expect(post.hashtags == ["Svace"], "$TKN is a cashtag — a shell variable in a pasted snippet")
    }

    @Test("replies, forwards and reactions")
    func replyForwardReactions() throws {
        #expect(try Self.post(11).replyTo == 10)
        #expect(try Self.post(12).forward == ForwardOrigin(authorName: "Example News"))
        #expect(try Self.post(11).reactions == [Reaction(emoji: "👍", count: 3), Reaction(emoji: "🔥", count: 1)])
    }

    /// The web preview's rule, kept: a preview whose URL differs from the text's link — here by a
    /// trailing slash — is a second link, and canonicalisation folds the two later.
    @Test("a link preview becomes a link with its metadata, dated when the export was taken")
    func linkPreview() throws {
        let links = try Self.post(12).links
        #expect(links.map(\.urlRaw) == ["https://example.org/article/", "https://example.org/article"])
        #expect(links[1].preview == LinkPreview(siteName: "Example", title: "An article",
                                                description: "What the article says",
                                                resolvedURL: "https://example.org/article", observedAt: Self.observed))
        #expect(links[0].urlCanonical == links[1].urlCanonical)
    }

    @Test("a poll's options lose their leading dash, and its total is read")
    func poll() throws {
        let post = try Self.post(14)
        #expect(post.kind == .poll)
        #expect(post.poll == Poll(question: "Which analyser do you use?", options: ["Svace", "Something else"], totalVotes: 7))
    }

    @Test("every media kind the export marks up, and unknown for anything else")
    func kinds() throws {
        let kinds = try Self.export().posts.map(\.kind)
        #expect(kinds == [.text, .text, .text, .photo, .poll, .text, .document, .voice, .sticker, .video, .unknown])
    }

    @Test("pages are read in number order, so messages10 follows messages9")
    func pageOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in (["messages.html"] + (2...10).map { "messages\($0).html" }) + ["style.css"] {
            try "".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        #expect(try ChatExportParser.pageFiles(in: dir).map(\.lastPathComponent)
                == ["messages.html"] + (2...10).map { "messages\($0).html" })
    }

    /// 🔴 The exporter numbers pages contiguously from `messages.html` (tdesktop `HtmlWriter`),
    /// so a hole is a lost file. Accepting the remainder would import a partial history and
    /// report nothing missing (PR #3, review round 2).
    @Test("a hole in the page sequence is a partial export, not a valid one")
    func pageSequenceGapIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["messages.html", "messages3.html"] {
            try "".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        #expect(throws: ChatExportParser.IncompleteExport(directory: dir, missing: 2)) {
            try ChatExportParser.pageFiles(in: dir)
        }
    }

    @Test("a folder that starts at messages2.html is missing its first page")
    func pageSequenceFirstPageIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "".write(to: dir.appendingPathComponent("messages2.html"), atomically: true, encoding: .utf8)
        #expect(throws: ChatExportParser.IncompleteExport(directory: dir, missing: 1)) {
            try ChatExportParser.pageFiles(in: dir)
        }
    }

    // MARK: - The message embed: the one web page a group's message has

    static func embed() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/embed-group-message", withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("an embed yields the message's UTC date, text and the chat's bare id")
    func embed() throws {
        let html = try Self.embed()
        let post = try #require(try MessageEmbed.post(html: html))
        #expect(post.date == ISO8601DateFormatter().date(from: "2023-04-03T09:34:07Z"))
        #expect(post.text.hasPrefix("Первая строка про @someone"))
        #expect(try MessageEmbed.rawChannelID(html: html) == 1_234_567_890)
    }

    /// The preview's parser dates a message with no `<time>` to 1970 instead of failing. A check
    /// comparing against that date would report a wrong time zone, not a broken page.
    @Test("an embed with no readable date is no message at all")
    func embedWithoutDate() throws {
        let html = try Self.embed().replacingOccurrences(of: "datetime=\"2023-04-03T09:34:07+00:00\"", with: "")
        #expect(try MessageEmbed.post(html: html) == nil)
    }
}
