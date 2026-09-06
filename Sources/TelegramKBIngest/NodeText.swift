import Foundation
import SwiftSoup

/// Extracts text from a Telegram message body, preserving line breaks.
///
/// **`Element.text()` silently drops `<br/>`** — verified: `Строка один<br>Строка два` yields
/// `Строка один Строка два`, and `text(trimAndNormaliseWhitespace: false)` does not fix it.
/// Telegram uses `<br/>` for every line break inside a message, so `text()` would silently
/// concatenate paragraphs (`research/swiftsoup.md`).
///
/// A node walk fixes that and gives `<a href>` extraction for free.
enum NodeText {

    /// Visible text with `<br>` mapped to a newline, normalised to NFC.
    ///
    /// NFC matters because SwiftSoup decodes entities into decomposed forms in places, and FTS5
    /// compares bytes — an unnormalised `й` will not match a normalised one.
    static func text(of element: Element) throws -> String {
        var out = ""
        try append(element, into: &out)
        return out
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    private static func append(_ node: Node, into out: inout String) throws {
        for child in node.getChildNodes() {
            if let t = child as? TextNode {
                out += t.getWholeText()
            } else if let e = child as? Element {
                if e.tagName() == "br" {
                    out += "\n"
                } else {
                    try append(e, into: &out)
                }
            }
        }
    }

    /// Absolute `http(s)` hrefs inside `element`.
    ///
    /// Hashtags are deliberately excluded: Telegram renders them as *relative* links
    /// (`href="?q=%23swiftpm"`), so filtering on an absolute scheme separates the two cleanly
    /// with no special-casing.
    static func absoluteLinks(in element: Element) throws -> [String] {
        try element.select("a[href]").compactMap { a -> String? in
            let href = try a.attr("href")
            return href.hasPrefix("http://") || href.hasPrefix("https://") ? href : nil
        }
    }

    /// Hashtags, from the relative `?q=%23tag` links Telegram emits.
    static func hashtags(in element: Element) throws -> [String] {
        try element.select("a[href^=?q=%23]").compactMap { a -> String? in
            let href = try a.attr("href")
            guard let raw = href.split(separator: "=").last else { return nil }
            return String(raw).removingPercentEncoding?.replacingOccurrences(of: "#", with: "")
        }
    }
}
