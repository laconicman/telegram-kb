import Foundation
import Testing
@testable import TelegramKBModel

/// The one rule that derives a post's text fields from typed entities, whichever source mapped them.
struct PostTextTests {

    static let seen = Date(timeIntervalSince1970: 1_680_514_447)

    /// One of each kind the model carries, in a known order.
    static let everyKind = FormattedText(text: "…", entities: [
        TextEntity(.hashtag, text: "#swift"),
        TextEntity(.cashtag, text: "$CASH"),
        TextEntity(.mention(username: "kb_author"), text: "@kb_author"),
        TextEntity(.url, text: "https://example.com/notes/"),
        TextEntity(.textURL(href: "https://example.org/docs"), text: "the docs"),
        TextEntity(.emailAddress, text: "kb@example.com"),
        TextEntity(.phoneNumber, text: "+15550100"),
        TextEntity(.botCommand, text: "/start"),
        TextEntity(.mentionName, text: "Kim Example"),
        TextEntity(.hashtag, text: "#swift"),
    ])

    @Test("hashtags keep text order and repeats; only hashtags are tags")
    func hashtags() {
        let fields = PostText(Self.everyKind, webPage: nil, observedAt: Self.seen)
        #expect(fields.hashtags == ["swift", "swift"], "a cashtag is not a hashtag")
        #expect(fields.text == "…")
    }

    /// A mention is still a link to its `t.me` page: moving mentions to a field of their own is a
    /// separate change (`TD-26`), and this pins the rule until it lands.
    @Test("links: URLs, text URLs and mentions, in text order — no email, phone or command")
    func links() {
        let fields = PostText(Self.everyKind, webPage: nil, observedAt: Self.seen)
        #expect(fields.links.map(\.urlRaw)
                == ["https://t.me/kb_author", "https://example.com/notes/", "https://example.org/docs"])
        #expect(fields.links.allSatisfy { $0.preview == nil })
    }

    @Test("a link repeated in the text is recorded once")
    func linksAreUnique() {
        let text = FormattedText(text: "…", entities: [
            TextEntity(.url, text: "https://example.com/"),
            TextEntity(.textURL(href: "https://example.com/"), text: "again"),
        ])
        #expect(PostText(text, webPage: nil, observedAt: Self.seen).links.map(\.urlRaw) == ["https://example.com/"])
    }

    @Test("a text URL to anything but a web address is not a link")
    func nonWebTextURLIsNotALink() {
        let text = FormattedText(text: "…", entities: [TextEntity(.textURL(href: "tg://resolve?domain=x"), text: "x")])
        #expect(PostText(text, webPage: nil, observedAt: Self.seen).links.isEmpty)
    }

    @Test("a preview attaches to the text's link to the same address")
    func previewAttachesToItsLink() throws {
        let page = WebPage(url: "https://example.com/notes/", siteName: "Example", title: "Notes",
                           description: "What changed")
        let fields = PostText(Self.everyKind, webPage: page, observedAt: Self.seen)
        #expect(fields.links.count == 3, "no second link for the same address")
        let preview = try #require(fields.links.first { $0.urlRaw == page.url }?.preview)
        #expect(preview == LinkPreview(siteName: "Example", title: "Notes", description: "What changed",
                                       resolvedURL: page.url, observedAt: Self.seen))
    }

    @Test("a preview of an address the text does not link is a link of its own, last")
    func previewOfItsOwn() {
        let page = WebPage(url: "https://example.net/", title: "Elsewhere")
        let fields = PostText(Self.everyKind, webPage: page, observedAt: Self.seen)
        #expect(fields.links.map(\.urlRaw).last == "https://example.net/")
        #expect(fields.links.last?.preview?.title == "Elsewhere")
    }

    /// 🔴 The web parser kept a preview whatever its address — an empty `href` became a link `""` —
    /// while the export's refused anything but `http(s)`. The check now exists once, here (`TD-26`).
    @Test("a preview of anything but a web address is no link at all")
    func nonWebPreviewIsNotALink() {
        for url in ["", "tg://resolve?domain=x", "?q=%23swift", "mailto:kb@example.com"] {
            let fields = PostText(FormattedText(text: "text"), webPage: WebPage(url: url, title: "t"),
                                  observedAt: Self.seen)
            #expect(fields.links.isEmpty, "a preview of \(url.debugDescription) became a link")
        }
    }
}
