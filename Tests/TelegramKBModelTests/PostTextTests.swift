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
        #expect(fields.links.allSatisfy { $0.isAutoLink == false },
                "no bare address in everyKind — and PostText never leaves the flag undecided")
    }

    @Test("a link repeated in the text is recorded once — flag included, from the first")
    func linksAreUnique() {
        let text = FormattedText(text: "…", entities: [
            TextEntity(.textURL(href: "https://example.com/"), text: "example.com"),
            TextEntity(.url, text: "https://example.com/"),
        ])
        let links = PostText(text, webPage: nil, observedAt: Self.seen).links
        #expect(links.map(\.urlRaw) == ["https://example.com/"])
        #expect(links.first?.isAutoLink == true,
                "the first entity's flag survives; the repeat contributes nothing")
    }

    /// Issue #13: Telegram auto-links plain text ending in a TLD, so `build.sh` becomes a link
    /// to `http://build.sh` — `.sh` is a TLD. The flag records the shape the markup carries —
    /// covered text vs `href` — so a consumer never has to guess from the URL's suffix.
    @Test("isAutoLink marks the bare address, not a hidden link, a typed URL, or a mention")
    func autoLinkFlag() {
        let text = FormattedText(text: "…", entities: [
            // What the renderers write for a bare address: the shown text minus the scheme
            // they added — http or https, trailing slash or not.
            TextEntity(.textURL(href: "http://build.sh/"), text: "build.sh"),
            TextEntity(.textURL(href: "https://apivalidator.ru/"), text: "apivalidator.ru"),
            // A genuine hidden link — prose over the href.
            TextEntity(.textURL(href: "https://example.org/docs"), text: "the docs"),
            // The full address typed with its scheme is a deliberate share, not an auto-link.
            TextEntity(.url, text: "https://example.com/notes/"),
            TextEntity(.mention(username: "kb_author"), text: "@kb_author"),
            // A hidden link whose text reads like its own address flags the same — the
            // accepted residue. The tracking parameter is why the canonical forms meet.
            TextEntity(.textURL(href: "https://example.com/page?utm_source=tg"), text: "example.com/page"),
        ])
        let fields = PostText(text, webPage: nil, observedAt: Self.seen)
        #expect(fields.links.map(\.isAutoLink) == [true, true, false, false, false, true])
    }

    /// A `.textURL` whose covered text carries its own scheme — `[http://a.com](https://b.com)`
    /// — was typed or hidden, never a bare address the source linkified.
    @Test("a text URL showing a full address is not an auto-link")
    func autoLinkWithSchemeInText() {
        let text = FormattedText(text: "…", entities: [
            TextEntity(.textURL(href: "https://example.com/"), text: "http://example.com"),
        ])
        #expect(PostText(text, webPage: nil, observedAt: Self.seen).links.first?.isAutoLink == false)
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
        #expect(fields.links.last?.isAutoLink == false,
                "a preview's address is no link the text made — false, not unknown")
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
