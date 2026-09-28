import Foundation
import SwiftSoup
import TelegramKBModel

/// Reads the HTML chat export a Telegram client writes — "Export Chat History…" — into posts.
///
/// **Why HTML.** Telegram for macOS offers no format choice for a single chat (verified in its
/// export dialog, 2026-09-21); its account-wide export offers JSON but cannot pick one chat. The
/// markup matches Telegram Desktop's HTML exporter
/// (`telegramdesktop/tdesktop`, `Telegram/SourceFiles/export/output/export_output_html.cpp`),
/// with small differences, so a real export — not the source — is the authority here.
///
/// What the markup carries, and what it does not:
/// - **Dates have no offset.** The title reads `3 April 2023, 12:34:07`, rendered in the local
///   time zone of the machine that wrote the export. Checked against `t.me` message embeds, which
///   carry UTC: seven of seven messages sat exactly three hours apart on a Mac in Europe/Moscow.
///   The zone is therefore an input, never a guess.
/// - **An edited message keeps its send time** in the title; the visible label merely reads
///   `edited 12:34`. Checked on six edited messages against their embeds.
/// - **A "joined" message omits its sender**: the exporter folds consecutive messages from one
///   sender within 900 s (`kJoinWithinSeconds`). The sender carries over from the message before.
/// - **Sender names are the exporting account's view.** Telegram shows a contact's saved name in
///   place of their profile name, and the export is written from that account: one sender's name
///   in a real export differed from the one their message's public embed shows (`TD-24`).
/// - **No album grouping.** Each item of a media group is its own message block, as TDLib has it
///   (`TD-8`); the web preview is the source that folds them.
public enum ChatExportParser {

    public struct Export: Sendable {
        /// The chat's title, from the export's page header.
        public var title: String?
        /// Every message that could be read, in the order the export lists them.
        public var posts: [Post]
        /// Joins, pins, renames: counted, never stored. They occupy message ids no post fills.
        public var serviceMessages = 0
        /// Message blocks with no readable id or date. Their posts are missing — never guessed.
        public var unreadable = 0
    }

    /// The export's pages in the order the client wrote them: `messages.html`, `messages2.html`, …
    /// Sorted by number, so `messages10.html` follows `messages9.html`.
    ///
    /// The sequence must start at `messages.html` and have no holes: the exporter numbers pages
    /// contiguously, so a missing number is a file lost after the export — never a page it
    /// skipped (tdesktop `HtmlWriter.messagesFile`; the page size differs by client, the
    /// numbering does not). Accepting the remainder would import a partial history and report
    /// nothing missing (PR #3, round 2).
    public static func pageFiles(in directory: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let pages = names.compactMap { name -> (Int, URL)? in
            guard name.hasPrefix("messages"), name.hasSuffix(".html") else { return nil }
            let digits = name.dropFirst("messages".count).dropLast(".html".count)
            guard let n = digits.isEmpty ? 1 : Int(digits) else { return nil }
            return (n, directory.appendingPathComponent(name))
        }.sorted { $0.0 < $1.0 }
        for (page, expected) in zip(pages.map(\.0), 1...) where page != expected {
            throw IncompleteExport(directory: directory, missing: expected)
        }
        return pages.map(\.1)
    }

    /// The export's page sequence has a hole — a file was lost or the copy is partial.
    public struct IncompleteExport: Error, Equatable, CustomStringConvertible {
        public var directory: URL
        /// The first absent page: `1` when `messages.html` itself is missing.
        public var missing: Int
        public var description: String {
            let file = missing == 1 ? "messages.html" : "messages\(missing).html"
            return "\(directory.path): \(file) is missing — the export is incomplete, and "
                 + "importing what remains would silently drop the posts it held"
        }
    }

    /// - Parameters:
    ///   - pages: the export's HTML pages, in order (see ``pageFiles(in:)``).
    ///   - channel: the username to file posts under. The export does not carry it.
    ///   - timeZone: the zone of the machine that wrote the export.
    public static func parse(pages: [String], channel: String, timeZone: TimeZone) throws -> Export {
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.timeZone = timeZone
        dates.dateFormat = "d MMMM yyyy, HH:mm:ss"

        var export = Export(title: nil, posts: [])
        var sender: String?                 // carried into "joined" messages, across pages too
        for html in pages {
            let doc = try SwiftSoup.parse(html)
            if export.title == nil {
                export.title = try doc.select("div.page_header div.name").first().map(NodeText.text(of:))
            }
            for block in try doc.select("div.history > div.message") {
                if block.hasClass("service") {
                    // Day separators carry no id; only real service messages are counted.
                    if !block.id().isEmpty { export.serviceMessages += 1 }
                    continue
                }
                guard let post = try post(from: block, channel: channel, sender: &sender,
                                          dates: dates) else {
                    export.unreadable += 1
                    continue
                }
                export.posts.append(post)
            }
        }
        return export
    }

    static func post(from block: Element, channel: String, sender: inout String?,
                     dates: DateFormatter) throws -> Post? {
        guard let body = try block.select("> div.body").first() else { return nil }
        // The sender first, even from a block that turns out unreadable: the "joined" message
        // after it still continues from this sender, not from the one before.
        if let name = try body.select("> div.from_name").first() {
            // `ownText`, not the whole element: a bot relay appends a `via @bot` span to the name.
            sender = name.ownText().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard block.id().hasPrefix("message"), let id = Int(block.id().dropFirst("message".count)), id > 0,
              let dateEl = try body.select("> div.date").first(),
              let date = dates.date(from: try dateEl.attr("title")) else { return nil }
        let textEl = try body.select("> div.text").first()
        var formatted = try textEl.map { try EntityMarkup.formattedText(of: $0, entity: entity(for:)) }
            ?? FormattedText(text: "")
        if formatted.text.isEmpty {
            // An uncaptioned document or audio file still names itself: the media block's title
            // is the file's name — the only searchable text such a message has (PR #3, round 4).
            formatted.text = try body.select(".media_file .title, .media_audio_file .title")
                .first().map(NodeText.text(of:)) ?? ""
        }
        // A preview is dated to the post itself — the only reliable timestamp the export carries.
        // The page file's modification time looks like the export's moment, but a copied folder
        // rewrites it, misdating every preview it held (PR #3, round 4); the snapshot Telegram
        // rendered rode with the message, so the message's date is the honest claim.
        let fields = PostText(formatted, webPage: try webPage(in: body), observedAt: date)

        return Post(
            id: .init(channelUsername: channel, messageID: id),
            date: date,
            kind: try kind(in: body),
            formatSource: .export,
            text: fields.text,
            authorName: sender,
            isEdited: try dateEl.text().lowercased().hasPrefix("edited"),
            replyTo: try replyTarget(in: body),
            forward: try forwardOrigin(in: body),
            hashtags: fields.hashtags,
            links: fields.links,
            reactions: try reactions(in: body),
            poll: try poll(in: body))
    }

    /// Only the markup a real export was seen to write, plus `media_audio_file` from tdesktop's
    /// source; anything else in a media block is `.unknown`, never a guess.
    static func kind(in body: Element) throws -> PostKind {
        let known: [(String, PostKind)] = [
            ("div.media_poll", .poll),
            (".photo_wrap", .photo),
            (".video_file_wrap", .video),
            (".sticker_wrap", .sticker),
            (".media_voice_message", .voice),
            (".media_audio_file", .audio),
            (".media_file", .document),
        ]
        for (selector, kind) in known where try !body.select(selector).isEmpty() { return kind }
        // A link preview is a text post that links somewhere, as on the web.
        let media = try body.select("> div.media_wrap").filter { try $0.select("a.webpage_preview").isEmpty() }
        return media.isEmpty ? .text : .unknown
    }

    /// `In reply to <a onclick="return GoToMessage(5842)">` — a message in this same chat.
    static func replyTarget(in body: Element) throws -> Int? {
        guard let a = try body.select("> div.reply_to a[onclick]").first() else { return nil }
        let call = try a.attr("onclick")
        guard let open = call.range(of: "GoToMessage("), let close = call[open.upperBound...].firstIndex(of: ")")
        else { return nil }
        return Int(call[open.upperBound..<close])
    }

    /// `Forwarded from opennet.ru`: the export names the origin but gives no id to follow.
    static func forwardOrigin(in body: Element) throws -> ForwardOrigin? {
        guard let el = try body.select("> div.forwarded_from").first() else { return nil }
        let name = try NodeText.text(of: el)
            .replacingOccurrences(of: "Forwarded from", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : ForwardOrigin(authorName: name)
    }

    /// How an export marks entities up: tdesktop's `FormatText` (`export_output_html.cpp`), and the
    /// macOS client as its real exports show it.
    /// - A hashtag is a `ShowHashtag(…)` call. So is a cashtag in the macOS client
    ///   (`ShowHashtag('$TKN')` — shell variables in pasted snippets), where tdesktop has
    ///   `ShowCashtag`; both are read. The two are told apart by the visible `#` or `$`, never by
    ///   the call's argument.
    /// - A bot command is `ShowBotCommand(…)`; a mention of a user, `ShowMentionName()`.
    /// - An email address links to `mailto:`, a phone number to `tel:`.
    /// - A mention links to `https://t.me/<name>`, and a URL to its address (`EntityMarkup.link`).
    static func entity(for anchor: Element) throws -> TextEntity? {
        // Case-insensitive, as the `a[onclick*=ShowHashtag]` selector this replaces matched.
        let call = try anchor.attr("onclick").lowercased()
        let shown = try NodeText.text(of: anchor)
        // A bare `#` or `$` is no tag.
        let tagged = { (sign: String) in call.contains("showhashtag") && shown.hasPrefix(sign) && shown.count > 1 }
        if tagged("#") { return TextEntity(.hashtag, text: shown) }
        let href = try anchor.attr("href")
        if let link = try EntityMarkup.link(anchor, href: href) { return link }
        if tagged("$") || call.contains("showcashtag") { return TextEntity(.cashtag, text: shown) }
        if call.contains("showbotcommand") { return TextEntity(.botCommand, text: shown) }
        if call.contains("showmentionname") { return TextEntity(.mentionName, text: shown) }
        if href.hasPrefix("mailto:") { return TextEntity(.emailAddress, text: shown) }
        if href.hasPrefix("tel:") { return TextEntity(.phoneNumber, text: shown) }
        return nil
    }

    static func webPage(in body: Element) throws -> WebPage? {
        guard let card = try body.select("> div.media_wrap a.webpage_preview[href]").first() else { return nil }
        return WebPage(
            url: try card.attr("href"),
            siteName: try card.select("div.webpage_site").first().map(NodeText.text(of:)),
            title: try card.select("div.webpage_title").first().map(NodeText.text(of:)),
            description: try card.select("div.webpage_description").first().map(NodeText.text(of:)))
    }

    /// `<span class="reaction"><span class="emoji">👍</span><span class="count">1</span></span>`
    static func reactions(in body: Element) throws -> [Reaction] {
        try body.select("div.reactions span.reaction").map { r in
            let emoji = try r.select("span.emoji").first().map(NodeText.text(of:)).flatMap { $0.isEmpty ? nil : $0 }
            let count = Int(try r.select("span.count").text().filter(\.isNumber)) ?? 0
            return Reaction(emoji: emoji, count: count)
        }
    }

    /// `div.question`, then one `div.answer` per option written `- Option`; the total, when there
    /// is one, reads like `42 votes`.
    static func poll(in body: Element) throws -> Poll? {
        guard let p = try body.select("div.media_poll").first() else { return nil }
        let question = try p.select("div.question").first().map(NodeText.text(of:)) ?? ""
        let options = try p.select("div.answer").map { answer -> String in
            let t = try NodeText.text(of: answer)
            return t.hasPrefix("- ") ? String(t.dropFirst(2)) : t
        }
        let total = Int(try p.select("div.total").text().filter(\.isNumber))
        return Poll(question: question, options: options, totalVotes: total)
    }
}
