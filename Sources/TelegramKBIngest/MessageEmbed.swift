import Foundation
import SwiftSoup
import TelegramKBModel

/// One message's embed page, `https://t.me/<chat>/<id>?embed=1`.
///
/// **The one web page that renders a public GROUP's message.** The `/s/` preview 302s for a group
/// (`ChannelClassifier`), but a single message still embeds — verified on `@sdl_static`,
/// 2026-09-21. It carries what a chat export lacks: the date in UTC (`<time datetime>`), and the
/// chat's bare id in `data-peer`. So one request can confirm that an export belongs to the chat
/// it is being filed under, and in which zone its dates were written.
public enum MessageEmbed {

    public static func url(chat: String, messageID: Int) -> URL {
        URL(string: "https://t.me/\(chat)/\(messageID)?embed=1")!
    }

    /// The message as the embed renders it — the same widget the preview uses, so the preview's
    /// parser reads it. `nil` when the page holds no message (deleted, or not a public chat), and
    /// also when it holds no readable `<time datetime>`: the preview's parser then dates a post to
    /// 1970 rather than failing, and a check against that date would blame the time zone.
    public static func post(html: String) throws -> Post? {
        guard let stamp = try SwiftSoup.parse(html).select("div.tgme_widget_message time[datetime]").first(),
              (try? WebPreviewParser.iso.parse(try stamp.attr("datetime"))) != nil else { return nil }
        return try WebPreviewParser.page(html: html).posts.first
    }

    /// The chat's bare id, from `data-peer="c1234567890_-1111111111111111111"`: `c`, the id, then a
    /// hash that is not ours to interpret.
    public static func rawChannelID(html: String) throws -> Int64? {
        let peer = try SwiftSoup.parse(html).select("div.tgme_widget_message[data-peer]").first()?.attr("data-peer")
        guard let peer, peer.hasPrefix("c"),
              let id = Int64(peer.dropFirst().prefix { $0.isNumber }), id > 0 else { return nil }
        return id
    }
}
