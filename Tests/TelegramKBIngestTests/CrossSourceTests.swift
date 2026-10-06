import Foundation
import Testing
@testable import TelegramKBIngest
import TelegramKBModel

/// One message, two renderings — `t.me/s` and a chat export — and one set of derived fields.
///
/// The markup differs for every entity, and the web marks fewer of them: a cashtag and an email
/// address are plain text there. What must not differ is what a post records. Two parsers deriving
/// `text`, `hashtags` and `links` by their own copies of the rules had already drifted (`TD-26`);
/// both now map markup to typed entities and derive through `PostText`, and this pins the result.
struct CrossSourceTests {

    static func html(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/cross-source/\(name)", withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func posts(_ id: Int) throws -> (web: Post, export: Post) {
        let web = try WebPreviewParser.parse(html: html("web"))
        let export = try ChatExportParser.parse(pages: [html("export")], channel: "kbtest",
                                                timeZone: ChatExportParserTests.moscow).posts
        return (try #require(web.first { $0.id.messageID == id }),
                try #require(export.first { $0.id.messageID == id }))
    }

    /// What each message says, whichever source rendered it.
    struct Expected: Sendable, CustomTestStringConvertible {
        var id: Int
        var text: String
        var hashtags: [String]
        var links: [String]
        var preview: WebPage
        var testDescription: String { "message \(id)" }
    }

    static let messages = [
        // Every entity kind, a line break on each side of a hashtag, and a preview of a link the
        // text carries. A mention is a link until mentions get a field of their own (`TD-26`).
        Expected(id: 10,
                 text: "Release notes: https://example.com/notes/ (the docs) by @kb_author\n#swift\n"
                     + "$CASH — write to kb@example.com or call +15550100",
                 hashtags: ["swift"],
                 links: ["https://example.com/notes/", "https://example.org/docs", "https://t.me/kb_author"],
                 preview: WebPage(url: "https://example.com/notes/", siteName: "Example",
                                  title: "Release notes", description: "What changed in this release")),
        // tdesktop's dialect on the export side (`ShowCashtag`, `href=""`), and a preview of an
        // address the text does not carry.
        Expected(id: 11,
                 text: "Worth a look #release\n$TKN, /help, thanks Kim Example",
                 hashtags: ["release"],
                 links: ["https://example.net/talk"],
                 preview: WebPage(url: "https://example.net/talk", siteName: "Example Video", title: "The talk")),
    ]

    @Test("t.me/s and a chat export derive the same text, hashtags and links", arguments: messages)
    func crossSourceFieldsAgree(_ message: Expected) throws {
        let (web, export) = try Self.posts(message.id)
        #expect(web.date == export.date, "the fixtures must render one message, at one instant")

        for (source, post) in [("web", web), ("export", export)] {
            #expect(post.text == message.text, "\(source)")
            #expect(post.hashtags == message.hashtags, "\(source)")
            #expect(post.links.map(\.urlRaw) == message.links, "\(source)")
            let preview = try #require(post.links.first { $0.urlRaw == message.preview.url }?.preview, "\(source)")
            #expect(WebPage(url: preview.resolvedURL ?? "", siteName: preview.siteName, title: preview.title,
                            description: preview.description) == message.preview, "\(source)")
            #expect(post.links.filter { $0.preview != nil }.count == 1, "\(source): one preview, on one link")
        }

        // The same claim, stated source against source. A preview's `observedAt` is the one field
        // that differs by design: the page dates no preview, so the crawl does; the export's is the
        // post's own date.
        let undated = { (links: [LinkRef]) in links.map { link in
            var link = link; link.preview?.observedAt = .distantPast; return link } }
        #expect(web.text == export.text)
        #expect(web.hashtags == export.hashtags)
        #expect(undated(web.links) == undated(export.links))
    }
}
