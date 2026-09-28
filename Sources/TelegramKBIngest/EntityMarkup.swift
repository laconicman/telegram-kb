import SwiftSoup
import TelegramKBModel

/// What the two HTML sources share in mapping a message body onto ``FormattedText``: the walk over
/// its anchors, and the shape an absolute link takes in both.
///
/// What an anchor *means* differs by source — a hashtag is a `?q=%23` search link on `t.me/s` and
/// a `ShowHashtag` call in an export — so each parser supplies its own `entity(for:)`. Everything
/// after the mapping is ``PostText``'s.
///
/// One anchor is one entity. An anchor to a web address is a link whatever script it also calls,
/// as every such anchor was a link before entities existed. The one exception is an export's
/// hashtag, read first, and no exporter gives one a web `href`: it is `""` in tdesktop and `#` in
/// the macOS client.
enum EntityMarkup {

    /// The body's visible text, and one entity per anchor `entity` recognises, in document order.
    static func formattedText(of body: Element,
                              entity: (Element) throws -> TextEntity?) throws -> FormattedText {
        FormattedText(text: try NodeText.text(of: body), entities: try body.select("a").compactMap(entity))
    }

    /// An anchor to an absolute `http(s)` address, read the way both sources write it; `nil` for
    /// any other `href`.
    ///
    /// - `https://t.me/<name>` showing `@name` is a mention: tdesktop writes its internal links
    ///   domain plus the name (`FormatText`), and `t.me/s` the same address.
    /// - An anchor showing exactly its own address is a URL.
    /// - Anything else is a text URL. A bare address written without a scheme lands here too: both
    ///   renderers link `example.com` to an address with one (tdesktop's `SafeMessageHref` prepends
    ///   `https://`), so the markup cannot tell it from a hidden link. It yields the same link.
    ///
    /// Each case yields `href` itself as its link (``PostText``), so the address stored is the
    /// markup's, byte for byte.
    static func link(_ anchor: Element, href: String) throws -> TextEntity? {
        guard PostText.isWebURL(href) else { return nil }
        let shown = try NodeText.text(of: anchor)
        let mentionPrefix = "https://t.me/"
        if href.hasPrefix(mentionPrefix) {
            let name = String(href.dropFirst(mentionPrefix.count))
            if Channel.isUsername(name), shown.lowercased() == "@" + name.lowercased() {
                return TextEntity(.mention(username: name), text: shown)
            }
        }
        return shown == href ? TextEntity(.url, text: shown) : TextEntity(.textURL(href: href), text: shown)
    }
}
