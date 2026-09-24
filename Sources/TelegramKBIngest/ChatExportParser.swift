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
    ///   - observedAt: when the export was written — the date its link previews were taken.
    public static func parse(pages: [String], channel: String, timeZone: TimeZone,
                             observedAt: Date) throws -> Export {
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
                                          dates: dates, observedAt: observedAt) else {
                    export.unreadable += 1
                    continue
                }
                export.posts.append(post)
            }
        }
        return export
    }

    static func post(from block: Element, channel: String, sender: inout String?,
                     dates: DateFormatter, observedAt: Date) throws -> Post? {
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
        let text = try textEl.map(NodeText.text(of:)) ?? ""

        return Post(
            id: .init(channelUsername: channel, messageID: id),
            date: date,
            kind: try kind(in: body),
            formatSource: .export,
            text: text,
            authorName: sender,
            isEdited: try dateEl.text().lowercased().hasPrefix("edited"),
            replyTo: try replyTarget(in: body),
            forward: try forwardOrigin(in: body),
            hashtags: try textEl.map(hashtags(in:)) ?? [],
            links: try links(in: body, text: textEl, observedAt: observedAt),
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

    /// Read from the anchor's visible `#tag`, not from its `onclick`: the macOS export routes
    /// cashtags through the same call (`ShowHashtag('$TKN')` — shell variables in pasted snippets),
    /// where tdesktop has a separate `ShowCashtag`. The web preview links a cashtag to `?q=%24…`,
    /// which `NodeText.hashtags` does not collect, so neither source calls `$TKN` a hashtag.
    static func hashtags(in text: Element) throws -> [String] {
        try text.select("a[onclick*=ShowHashtag]").compactMap { a in
            let shown = try NodeText.text(of: a)
            return shown.hasPrefix("#") && shown.count > 1 ? String(shown.dropFirst()) : nil
        }
    }

    /// The same rule as the web preview (`WebPreviewParser.links`): every absolute `http(s)` href
    /// in the text — mentions included, rendered as `https://t.me/<name>` — then the link preview,
    /// attached to the matching link or added as its own.
    static func links(in body: Element, text: Element?, observedAt: Date) throws -> [LinkRef] {
        var refs: [LinkRef] = []
        var seen = Set<String>()
        if let text {
            for url in try NodeText.absoluteLinks(in: text) where seen.insert(url).inserted {
                refs.append(LinkRef(urlRaw: url))
            }
        }
        if let preview = try body.select("> div.media_wrap a.webpage_preview[href]").first() {
            let url = try preview.attr("href")
            let meta = LinkPreview(
                siteName: try preview.select("div.webpage_site").first().map(NodeText.text(of:)),
                title: try preview.select("div.webpage_title").first().map(NodeText.text(of:)),
                description: try preview.select("div.webpage_description").first().map(NodeText.text(of:)),
                resolvedURL: url,
                observedAt: observedAt)
            if let i = refs.firstIndex(where: { $0.urlRaw == url }) {
                refs[i].preview = meta
            } else if url.hasPrefix("http://") || url.hasPrefix("https://") {
                var ref = LinkRef(urlRaw: url); ref.preview = meta; refs.append(ref)
            }
        }
        return refs
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
