import Foundation
import Testing
import TelegramKBModel
@testable import TelegramKBIngest

/// Pins every extracted field against committed HTML.
///
/// `TD-1`'s discharge. The class names we parse are internal to Telegram's web front end and
/// carry no compatibility contract, and the failure mode is **silent recall loss, not a crash** —
/// so these assert field-by-field rather than merely that parsing succeeded. During Phase 0 a
/// wrong selector silently truncated 15% of bodies and reported 30 replies as zero, and nothing
/// threw.
struct WebPreviewParserTests {

    static func html(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "html"),
                               "fixture \(name).html is missing from the test bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func onlyPost(_ fixture: String) throws -> Post {
        let posts = try WebPreviewParser.parse(html: try html(fixture))
        return try #require(posts.first, "\(fixture) produced no posts")
    }

    // MARK: - The trap that cost 15% of bodies

    @Test("the body comes from js-message_text, never the reply quote")
    func bodyIsNotTheReplyQuote() throws {
        let post = try Self.onlyPost("post-reply")
        #expect(post.replyTo != nil, "this fixture IS a reply; if nil, the reply selector is wrong")
        #expect(!post.text.isEmpty)
        #expect(!post.text.hasSuffix("…"),
                "a trailing ellipsis means we harvested the truncated reply QUOTE, not the body")
    }

    @Test("line breaks survive extraction")
    func lineBreaksPreserved() throws {
        // Element.text() silently drops <br/>, and Telegram uses it for every line break.
        let posts = try WebPreviewParser.parse(html: try Self.html("swiftui_dev"))
        let multiline = posts.filter { $0.text.contains("\n") }
        #expect(!multiline.isEmpty,
                "no post has a newline — text() is dropping <br/> and paragraphs are being fused")
    }

    // MARK: - Per-kind fixtures

    @Test("poll: question and every option are extracted")
    func poll() throws {
        let post = try Self.onlyPost("post-poll")
        let poll = try #require(post.poll, "poll not parsed")
        #expect(post.kind == .poll)
        #expect(poll.question.contains("гаджет"), "got: \(poll.question)")
        #expect(poll.options.count >= 2, "got \(poll.options.count) options")
        #expect(poll.options.allSatisfy { !$0.isEmpty })
        #expect(poll.options.contains { $0.contains("Apple Watch") }, "got: \(poll.options)")
    }

    @Test("forward: origin is captured, and an unlinked origin has no username")
    func forward() throws {
        let post = try Self.onlyPost("post-forward")
        let fwd = try #require(post.forward, "forward origin not parsed")
        #expect(fwd.authorName?.isEmpty == false, "origin display name missing")
        #expect(fwd.authorName?.contains("Воробья") == true, "got: \(fwd.authorName ?? "nil")")
        // This fixture's origin is a bare <span>, not a link, so the username is genuinely
        // absent rather than missed — the nil path must not be mistaken for a parse failure.
        #expect(fwd.channelUsername == nil)
    }

    @Test("album: one post, mediaCount > 1, spanning consecutive ids")
    func album() throws {
        let post = try Self.onlyPost("post-album")
        #expect(post.kind == .album)
        #expect(post.mediaCount > 1, "an album parsed as a single-media post loses the span")
        #expect(post.isAlbum)
        #expect(post.messageIDSpan.count == post.mediaCount)
    }

    // MARK: - Page-level extraction

    @Test("reactions: emoji, counts, and paid reactions with no emoji at all")
    func reactions() throws {
        let posts = try WebPreviewParser.parse(html: try Self.html("swiftui_dev"))
        let withReactions = posts.filter { !$0.reactions.isEmpty }
        #expect(withReactions.count == posts.count,
                "every message on this page carries reactions; \(withReactions.count)/\(posts.count) parsed")
        #expect(posts.allSatisfy { $0.reactions.allSatisfy { $0.count > 0 } },
                "a zero count means the digits were not read — `</i>` sits between `</b>` and them")
        let paid = posts.flatMap(\.reactions).filter(\.isPaid)
        #expect(!paid.isEmpty, "paid reactions exist on this page")
        #expect(paid.allSatisfy { $0.emoji == nil },
                "paid reactions carry no emoji; an extractor keyed on <b> or the sprite drops them")
    }

    @Test("link previews carry Telegram's resolved metadata")
    func linkPreviews() throws {
        let posts = try WebPreviewParser.parse(html: try Self.html("swiftui_dev"))
        let previews = posts.flatMap(\.links).compactMap(\.preview)
        #expect(!previews.isEmpty)
        #expect(previews.contains { $0.title?.isEmpty == false })
        #expect(previews.contains { $0.description?.isEmpty == false },
                "descriptions matter: one corpus post matched Telegram's search ONLY via this field")
    }

    @Test("hashtags are separated from external links by shape, not by guesswork")
    func hashtagsVsLinks() throws {
        let posts = try WebPreviewParser.parse(html: try Self.html("swiftui_dev"))
        #expect(posts.contains { !$0.hashtags.isEmpty })
        #expect(posts.allSatisfy { $0.hashtags.allSatisfy { !$0.contains("#") && !$0.contains("?q=") } },
                "hashtags must be bare tags, not the relative ?q=%23 hrefs they come from")
        #expect(posts.allSatisfy { $0.links.allSatisfy { $0.urlRaw.hasPrefix("http") } },
                "links must be absolute; relative ?q= hrefs are hashtags and belong elsewhere")
    }

    @Test("dates parse to real instants, not the epoch")
    func dates() throws {
        let posts = try WebPreviewParser.parse(html: try Self.html("swiftui_dev"))
        #expect(posts.allSatisfy { $0.date.timeIntervalSince1970 > 1_400_000_000 },
                "an epoch date means the ISO8601 offset form failed to parse")
    }

    @Test("views are captured and flagged approximate when abbreviated")
    func views() throws {
        let posts = try WebPreviewParser.parse(html: try Self.html("swiftui_dev"))
        let views = posts.compactMap(\.views)
        #expect(!views.isEmpty)
        #expect(views.contains { $0.isApproximate },
                "this page renders counts as '1.4K'; losing the flag lets a lossy value be compared as exact")
    }

    /// Cross-checks the Swift parser against an **independent** Python implementation.
    ///
    /// Both parsed the same committed page; these totals came from the Python crawler in
    /// `research/crawl_corpus.py`. Two implementations agreeing is far stronger evidence than
    /// either agreeing with itself — and disagreement with an independent oracle is precisely
    /// what exposed the reply-quote bug during Phase 0, when every hand-written check passed.
    @Test("agrees with the independent Python crawler on the same page")
    func agreesWithIndependentImplementation() throws {
        let posts = try WebPreviewParser.parse(html: try Self.html("swiftui_dev"))
        #expect(posts.count == 20)
        #expect(posts.map(\.id.messageID).min() == 262)
        #expect(posts.map(\.id.messageID).max() == 297)
        #expect(posts.filter { !$0.reactions.isEmpty }.count == 20)
        #expect(posts.reduce(0) { $0 + $1.totalReactions } == 268,
                "reaction total diverging means digits are being misread somewhere")
        #expect(posts.filter { $0.links.contains { $0.preview != nil } }.count == 3)
        #expect(posts.filter { !$0.hashtags.isEmpty }.count == 18)
        #expect(posts.allSatisfy { $0.replyTo == nil }, "no post on this page is a reply")
    }

    @Test("a full page yields every message, oldest first")
    func pageShape() throws {
        let posts = try WebPreviewParser.parse(html: try Self.html("swiftui_dev"))
        #expect(posts.count == 20, "this fixture page holds 20 messages, got \(posts.count)")
        #expect(posts.map(\.id.messageID) == posts.map(\.id.messageID).sorted())
        #expect(posts.allSatisfy { $0.id.channelUsername == "swiftui_dev" })
        #expect(posts.allSatisfy { $0.formatSource == .web },
                "web-parsed posts must be marked .web so consumers know kind is sparse here")
    }
}

extension WebPreviewParserTests {
    /// The bare channel id is what lets a web-crawled channel produce a TDLib `chat_id`, so the
    /// two sources can reconcile (`TD-8`).
    @Test("the bare channel id is decoded from the data-view payload")
    func rawChannelIDFromDataView() throws {
        let id = try #require(try WebPreviewParser.rawChannelID(html: try Self.html("swiftui_dev"), channel: "swiftui_dev"))
        #expect(id == 1_492_664_793, "measured from this fixture's data-view during Phase 0")

        // …and it must yield the familiar chat id, arithmetically.
        let channel = TelegramKBModel.Channel(username: "swiftui_dev", rawChannelID: id)
        #expect(channel.tdlibChatID == -1_001_492_664_793)
    }
}

extension WebPreviewParserTests {
    /// 🔍 The first decodable `data-view` was trusted whatever channel its block belonged to.
    @Test("a foreign message block cannot supply the channel's identity")
    func rawChannelIDIgnoresForeignBlocks() throws {
        // {"c":-999} — a block for another channel, placed first.
        let foreign = #"<div class="tgme_widget_message" data-post="other/1" data-view="eyJjIjotOTk5fQ"></div>"#
        let html = try Self.html("swiftui_dev").replacingOccurrences(of: "<body", with: "<body>\(foreign)<div hidden")
        let id = try #require(try WebPreviewParser.rawChannelID(html: html, channel: "swiftui_dev"))
        #expect(id == 1_492_664_793, "the foreign block's 999 must not be taken")
        #expect(try WebPreviewParser.rawChannelID(html: html, channel: "nobody") == nil)
    }
}

extension WebPreviewParserTests {
    /// 🔴 A block the parser cannot read was dropped silently, while the walk still recorded the
    /// highest id it *could* read — so the skipped post sat below the mark where no later
    /// incremental run would look for it.
    @Test("an unreadable message block is counted, not silently dropped")
    func unreadableBlocksAreCounted() throws {
        let broken = #"""
        <div class="tgme_widget_message" data-post="not-a-post-id">
          <div class="tgme_widget_message_text js-message_text">who knows</div>
        </div>
        """#
        let html = try Self.html("swiftui_dev").replacingOccurrences(of: "<body", with: "<body>\(broken)<div hidden")
        let page = try WebPreviewParser.page(html: html)
        #expect(page.skippedBlocks == 1)
        #expect(page.posts.count == 20, "the readable blocks on the same page still parse")
    }
}

extension WebPreviewParserTests {
    /// `TD-25`: the parser used to date a block with no readable `time[datetime]` to
    /// `1970-01-01`, silently — a guessed value where `REVIEW.md` requires an unreadable row.
    /// A layout change is exactly when that fallback would do its damage.
    @Test("a block with no readable date is an unreadable block, not a 1970 post")
    func undatedBlockIsUnreadable() throws {
        let undated = #"""
        <div class="tgme_widget_message" data-post="swiftui_dev/99999">
          <div class="tgme_widget_message_text js-message_text">no date here</div>
        </div>
        """#
        let unparseable = #"""
        <div class="tgme_widget_message" data-post="swiftui_dev/99998">
          <time datetime="next tuesday, probably"></time>
          <div class="tgme_widget_message_text js-message_text">date that is not a date</div>
        </div>
        """#
        let html = try Self.html("swiftui_dev")
            .replacingOccurrences(of: "<body", with: "<body>\(undated)\(unparseable)<div hidden")
        let page = try WebPreviewParser.page(html: html)
        #expect(page.skippedBlocks == 2)
        #expect(page.posts.count == 20, "the dated blocks on the same page still parse")
        #expect(page.posts.allSatisfy { $0.date > Date(timeIntervalSince1970: 0) })
    }
}

extension WebPreviewParserTests {
    /// Found by self-review before pushing, where a free DeepWiki pass could not reach: the parser
    /// accepted any integer as a message id — negatives included — and the id feeds span arithmetic
    /// that traps near Int.max.
    @Test("an out-of-range message id is an unreadable block, not a post")
    func outOfRangeIDsAreUnreadable() throws {
        let block = { (post: String) in
            #"<div class="tgme_widget_message" data-post="\#(post)"><div class="tgme_widget_message_text js-message_text">x</div></div>"#
        }
        let hostile = block("chan/-5") + block("chan/0") + block("chan/9223372036854775807")
        let html = try Self.html("swiftui_dev").replacingOccurrences(of: "<body", with: "<body>\(hostile)<div hidden")
        let page = try WebPreviewParser.page(html: html)
        #expect(page.skippedBlocks == 3)
        #expect(page.posts.count == 20, "the real blocks on the same page still parse")
        #expect(page.posts.allSatisfy { $0.id.messageID > 0 })
    }

    /// A `tgme_widget_message` div without `data-post` can never become a post — it has no
    /// channel/id — but it is still an unreadable block. Selecting `[data-post]` would make it
    /// invisible to `skippedBlocks`, a hole between the two counts (PR #4, round 1).
    @Test("a message block missing data-post counts as unreadable, not as nothing")
    func missingDataPostIsCounted() throws {
        let html = #"""
        <div class="tgme_widget_message">
          <div class="tgme_widget_message_text js-message_text">id-less block</div>
        </div>
        <div class="tgme_widget_message" data-post="c/7">
          <div class="tgme_widget_message_text js-message_text">real post</div>
          <a class="tgme_widget_message_date"><time datetime="2026-01-01T00:00:00+00:00"></time></a>
        </div>
        """#
        let page = try WebPreviewParser.page(html: html)
        #expect(page.posts.count == 1)
        #expect(page.skippedBlocks == 1, "the id-less block is unreadable, not invisible")
    }
}
