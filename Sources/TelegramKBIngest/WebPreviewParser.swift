import Foundation
import SwiftSoup
import TelegramKBModel

/// Parses `t.me/s/<channel>` and `t.me/<channel>/<id>?embed=1` HTML into ``Post`` values.
///
/// Every selector here is pinned by a fixture test against committed HTML. The class names are
/// internal to Telegram's web front end and carry no compatibility contract (`TD-1`), and the
/// characteristic failure is **silent recall loss, not a crash** — which is why the tests assert
/// field-by-field rather than merely that parsing succeeded.
public enum WebPreviewParser {

    public enum ParseError: Error { case noMessages }

    /// Parses every message on a page, oldest first.
    ///
    /// SwiftSoup's `Document`/`Element` are deliberately not `Sendable`, so parsing and
    /// extraction happen in one isolation domain and only `Sendable` structs escape.
    public static func parse(html: String) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        // Select the message element itself, not its wrapper. A listing page nests it in
        // `tgme_widget_message_wrap`, but a single-post `?embed=1` page has no wrapper at all —
        // selecting the wrapper silently parses zero posts from every embed. The fixtures for
        // poll, forward, reply and album are all embeds, which is how this surfaced.
        return try doc.select("div.tgme_widget_message[data-post]").compactMap(post(from:))
    }

    static func post(from message: Element) throws -> Post? {
        let dataPost = try message.attr("data-post")
        guard !dataPost.isEmpty else { return nil }
        let parts = dataPost.split(separator: "/")
        guard parts.count == 2, let messageID = Int(parts[1]) else { return nil }
        // Lowercased at the parser boundary. Telegram resolves usernames case-insensitively but
        // SQLite compares keys exactly, so `tgkb sync IOSGR` stored channel `IOSGR` while posts
        // arrived as `iosgr` — and the first page failed its foreign key against a channel that
        // plainly exists. The CLI normalises the same way; the two must agree.
        let channel = String(parts[0]).lowercased()

        // The BODY is `js-message_text`. The sibling `js-message_reply_text` is the quoted
        // reply preview, which Telegram truncates to ~256 chars — selecting on the shared
        // class prefix silently harvests the quote instead, which is exactly what happened
        // during Phase 0 and cost a 15% body-truncation rate before it was noticed.
        let bodyEl = try message.select("div.tgme_widget_message_text.js-message_text").first()
        let text = try bodyEl.map(NodeText.text(of:)) ?? ""

        let date = try message.select("time[datetime]").first()
            .map { try $0.attr("datetime") }
            .flatMap { try? Self.iso.parse($0) } ?? Date(timeIntervalSince1970: 0)

        let author = try message.select("span.tgme_widget_message_from_author").first()
            .map(NodeText.text(of:))
            ?? message.select("a.tgme_widget_message_owner_name").first().map(NodeText.text(of:))

        let mediaCount = try albumMediaCount(in: message)
        let poll = try self.poll(in: message)
        let kind = try self.kind(in: message, text: text, mediaCount: mediaCount, hasPoll: poll != nil)

        return Post(
            id: .init(channelUsername: channel, messageID: messageID),
            date: date,
            kind: kind,
            // The web preview cannot express document/audio/voice/sticker/location at all, so
            // consumers must be able to tell "not a document" from "this source cannot say".
            formatSource: .web,
            mediaCount: mediaCount,
            text: text,
            authorName: author,
            isEdited: try message.select("span.tgme_widget_message_meta").first()
                .map { try $0.text().contains("edited") } ?? false,
            replyTo: try replyTarget(in: message),
            forward: try forwardOrigin(in: message),
            hashtags: try bodyEl.map(NodeText.hashtags(in:)) ?? [],
            links: try links(in: message, body: bodyEl),
            reactions: try reactions(in: message),
            poll: poll,
            views: try views(in: message))
    }

    /// The channel's **bare** id, decoded from the `data-view` payload.
    ///
    /// `data-view` is base64 JSON — `{"c":-1492664793,"p":268,"t":…,"h":…}` — where `c` is the
    /// raw channel id (negative there) and `p` the post id. `t` is the *request* time, part of a
    /// signed view-tracking token, and is not the post's date.
    ///
    /// This is what lets a web-crawled channel produce a TDLib `chat_id`
    /// (`Channel.tdlibChatID`), so the two sources can reconcile (`TD-8`).
    ///
    /// Only a block whose `data-post` names `channel` is trusted. Every page observed so far —
    /// eight fixtures and live `@iosgr` / `@ios_broadcast` listings, forwards included — carries
    /// the host channel's id on every block, so this never rejects real markup; it keeps a
    /// foreign block, should Telegram ever render one first, from becoming this channel's identity.
    public static func rawChannelID(html: String, channel: String) throws -> Int64? {
        let doc = try SwiftSoup.parse(html)
        for element in try doc.select("div.tgme_widget_message[data-view][data-post]") {
            let owner = try element.attr("data-post").split(separator: "/").first.map(String.init)
            guard owner?.lowercased() == channel.lowercased() else { continue }
            let encoded = try element.attr("data-view")
            let padded = encoded.padding(toLength: ((encoded.count + 3) / 4) * 4,
                                         withPad: "=", startingAt: 0)
            guard let data = Data(base64Encoded: padded),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let c = json["c"] as? Int64 ?? (json["c"] as? Int).map(Int64.init)
            else { continue }
            return abs(c)
        }
        return nil
    }

    // MARK: - Pieces

    /// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the format style is a
    /// Sendable value type, so it can be a `static let` under Swift 6 strict concurrency, where
    /// the formatter class cannot. Verified to parse Telegram's `+00:00` offset form.
    static let iso = Date.ISO8601FormatStyle()

    /// An album renders as ONE wrapper containing several media, and occupies that many
    /// consecutive message ids — the trailing ids never appear as posts of their own.
    static func albumMediaCount(in message: Element) throws -> Int {
        guard try !message.select("div.tgme_widget_message_grouped").isEmpty() else { return 1 }
        let media = try message.select(
            "a.tgme_widget_message_photo_wrap, div.tgme_widget_message_video_wrap").count
        return max(1, media)
    }

    static func kind(in message: Element, text: String, mediaCount: Int, hasPoll: Bool) throws -> PostKind {
        if hasPoll { return .poll }
        if mediaCount > 1 { return .album }
        if try !message.select("div.tgme_widget_message_roundvideo_wrap").isEmpty() { return .videoNote }
        if try !message.select("div.tgme_widget_message_voice_wrap, audio.tgme_widget_message_voice").isEmpty() { return .voice }
        if try !message.select("div.tgme_widget_message_audio_wrap").isEmpty() { return .audio }
        if try !message.select("div.tgme_widget_message_document_wrap").isEmpty() { return .document }
        if try !message.select("i.tgme_widget_message_sticker").isEmpty() { return .sticker }
        if try !message.select("div.tgme_widget_message_location_wrap").isEmpty() { return .location }
        if try !message.select("div.tgme_widget_message_video_wrap").isEmpty() { return .video }
        if try !message.select("a.tgme_widget_message_photo_wrap").isEmpty() { return .photo }
        return text.isEmpty ? .unknown : .text
    }

    static func replyTarget(in message: Element) throws -> Int? {
        guard let a = try message.select("a.tgme_widget_message_reply").first() else { return nil }
        let href = try a.attr("href")
        return Int(href.split(separator: "/").last ?? "")
    }

    static func forwardOrigin(in message: Element) throws -> ForwardOrigin? {
        guard let from = try message.select("div.tgme_widget_message_forwarded_from").first()
        else { return nil }
        let nameEl = try from.select(".tgme_widget_message_forwarded_from_name").first()
        let name = try nameEl.map(NodeText.text(of:))
        // The origin is a link only when it is publicly addressable; otherwise a bare span,
        // so the username is genuinely absent rather than missed.
        var username: String?
        var originID: Int?
        if let href = try nameEl.map({ try $0.attr("href") }), href.contains("t.me/") {
            let parts = href.split(separator: "/")
            if let last = parts.last, let n = Int(last) {
                originID = n
                username = parts.count >= 2 ? String(parts[parts.count - 2]) : nil
            } else if let last = parts.last {
                username = String(last)
            }
        }
        return ForwardOrigin(channelUsername: username, messageID: originID, authorName: name)
    }

    static func poll(in message: Element) throws -> Poll? {
        guard let p = try message.select("div.tgme_widget_message_poll").first() else { return nil }
        let question = try p.select("div.tgme_widget_message_poll_question").first()
            .map(NodeText.text(of:)) ?? ""
        let options = try p.select("div.tgme_widget_message_poll_option_text").map(NodeText.text(of:))
        return Poll(question: question, options: options, totalVotes: nil)
    }

    static func reactions(in message: Element) throws -> [Reaction] {
        try message.select("span.tgme_reaction").map { span in
            let isPaid = span.hasClass("tgme_reaction_paid")
            // Paid reactions carry NO emoji and no sprite URL, so an extractor keyed on either
            // drops them entirely.
            let emoji = try span.select("b").first().map { try $0.text() }
            // The count is the span's trailing text; `</i>` sits between `</b>` and the digits,
            // so a `</b>\s*(\d+)` pattern silently yields zero reactions on every message.
            let digits = try span.text().filter(\.isNumber)
            return Reaction(emoji: isPaid ? nil : emoji, count: Int(digits) ?? 0, isPaid: isPaid)
        }
    }

    static func views(in message: Element) throws -> ViewCount? {
        guard let el = try message.select("span.tgme_widget_message_views").first() else { return nil }
        let raw = try el.text().trimmingCharacters(in: .whitespaces)
        // Rendered abbreviated ("1.4K", "1.67K"), so the parsed value is lossy by construction
        // and must never be compared as exact against a TDLib count (`TD-7`).
        let isApprox = raw.contains("K") || raw.contains("M")
        let number = raw.filter { $0.isNumber || $0 == "." }
        guard let v = Double(number) else { return nil }
        let scale: Double = raw.contains("M") ? 1_000_000 : (raw.contains("K") ? 1_000 : 1)
        return ViewCount(value: Int(v * scale), isApproximate: isApprox)
    }

    static func links(in message: Element, body: Element?) throws -> [LinkRef] {
        var refs: [LinkRef] = []
        var seen = Set<String>()
        if let body {
            for url in try NodeText.absoluteLinks(in: body) where seen.insert(url).inserted {
                refs.append(LinkRef(urlRaw: url))
            }
        }
        if let prev = try message.select("a.tgme_widget_message_link_preview").first() {
            let url = try prev.attr("href")
            let preview = LinkPreview(
                siteName: try prev.select("div.link_preview_site_name").first().map(NodeText.text(of:)),
                title: try prev.select("div.link_preview_title").first().map(NodeText.text(of:)),
                description: try prev.select("div.link_preview_description").first().map(NodeText.text(of:)),
                resolvedURL: url,
                observedAt: Date())
            if let i = refs.firstIndex(where: { $0.urlRaw == url }) {
                refs[i].preview = preview
            } else {
                var ref = LinkRef(urlRaw: url); ref.preview = preview; refs.append(ref)
            }
        }
        return refs
    }
}
