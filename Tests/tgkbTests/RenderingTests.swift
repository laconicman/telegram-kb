import Foundation
import Testing
import TelegramKBModel
@testable import tgkb

/// What `show`, `query` and `links` print — the parts a reader at a terminal has no other way to see.
struct RenderingTests {

    @Test("show prints the whole post: text, links with their previews, reactions")
    func showRendersThePostInFull() {
        let body = String(repeating: "Длинный текст поста. ", count: 20)
        let post = Post(
            id: .init(channelUsername: "iosgr", messageID: 7),
            date: Date(timeIntervalSince1970: 1_700_006_399.5),
            kind: .text, formatSource: .web, text: body, authorName: "Автор",
            forward: ForwardOrigin(channelUsername: "origin", messageID: 3),
            hashtags: ["swiftui"],
            links: [LinkRef(urlRaw: "https://clck.ru/33ABCD",
                            preview: LinkPreview(siteName: "Example", title: "Заголовок статьи",
                                                 description: "Описание статьи",
                                                 observedAt: Date(timeIntervalSince1970: 0)))],
            reactions: [Reaction(emoji: "👍", count: 5), Reaction(emoji: nil, count: 2, isPaid: true)])
        let text = Show.render(post)

        #expect(text.contains(body), "the full text, not a snippet")
        #expect(text.contains("https://t.me/iosgr/7"))
        #expect(text.contains("2023-11-14T23:59:59.500Z"),
                "the precision the store keeps, so the date works as an inclusive --to")
        #expect(text.contains("by Автор"))
        #expect(text.contains("https://clck.ru/33ABCD"))
        #expect(text.contains("Example — Заголовок статьи"))
        #expect(text.contains("Описание статьи"))
        #expect(text.contains("Forwarded from https://t.me/origin/3"))
        #expect(text.contains("👍 5") && text.contains("2 paid") && text.contains("7 in all"))
        #expect(text.contains("#swiftui"))
    }

    @Test("show prints a poll's question and options, which are its content")
    func showRendersAPoll() {
        let post = Post(id: .init(channelUsername: "iosgr", messageID: 5),
                        date: Date(timeIntervalSince1970: 1_700_000_005),
                        kind: .poll, formatSource: .web, mediaCount: 0,
                        poll: Poll(question: "Какой паттерн?", options: ["MVVM", "TCA"], totalVotes: 42))
        let text = Show.render(post)
        for line in ["Poll: Какой паттерн?", "  • MVVM", "  • TCA", "42 vote(s)"] {
            #expect(text.contains(line))
        }
        #expect(!text.contains("no text"), "a poll is not an empty post")
    }

    /// The store decides whether a walk continues. A last page smaller than `total` is the end,
    /// and offering a cursor or a bigger `--limit` there would send the reader looking for more.
    @Test("the footer offers --cursor exactly when the store returned one")
    func footerFollowsNextCursor() {
        #expect(PageOptions.footer(3, of: 22, noun: "result", nextCursor: "abc")
                == "3 of 22 result(s) — for the rest, add --cursor abc")
        #expect(PageOptions.footer(1, of: 22, noun: "result", nextCursor: nil) == "1 of 22 result(s)")
        #expect(PageOptions.footer(3, of: 3, noun: "post", nextCursor: nil) == "3 post(s)")
    }
}
