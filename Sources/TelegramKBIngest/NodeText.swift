import Foundation
import SwiftSoup

/// Extracts text from a Telegram message body, preserving line breaks.
///
/// **`Element.text()` silently drops `<br/>`** — verified: `Строка один<br>Строка два` yields
/// `Строка один Строка два`, and `text(trimAndNormaliseWhitespace: false)` does not fix it.
/// Telegram uses `<br/>` for every line break inside a message, so `text()` would silently
/// concatenate paragraphs (`research/swiftsoup.md`).
///
/// A node walk fixes that. What the anchors in a body mean is `EntityMarkup`'s concern.
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
}
