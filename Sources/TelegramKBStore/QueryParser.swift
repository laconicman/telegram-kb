import Foundation

/// Splits a query into quoted **phrases**, where order matters, and loose **tokens**, where it
/// does not.
///
/// Word search ANDs tokens, so `адаптивная вёрстка` and `вёрстка адаптивная` were the same query —
/// measured on the corpus, both returned the same post. Quoting is how a searcher says otherwise,
/// and it is the convention every search box already teaches.
///
/// **Typographic quotes count.** A Russian keyboard produces `«…»` and macOS turns `"` into `“…”`
/// as you type; a searcher who types the quotes their keyboard gives them means the same thing as
/// one who types ASCII ones. All three pairs open and close a phrase.
public enum QueryParser {

    public struct Parsed: Equatable, Sendable {
        /// Quoted runs, in the order typed. Each is matched as an ordered phrase.
        public var phrases: [String]
        /// Everything outside quotes, split on whitespace. Order carries no meaning.
        public var tokens: [String]
        public var isEmpty: Bool { phrases.isEmpty && tokens.isEmpty }
    }

    /// Opening character → the character that closes it. `"` closes itself.
    static let quotePairs: [Character: Character] = ["\"": "\"", "“": "”", "«": "»", "„": "“"]

    public static func parse(_ query: String) -> Parsed {
        var phrases: [String] = [], tokens: [String] = []
        var current = "", closing: Character?

        func endToken() {
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { tokens.append(current) }
            current = ""
        }
        for character in query {
            if let expected = closing {
                if character == expected {
                    // An empty pair — `""` — is not a phrase; it says nothing and must not become
                    // a pattern that matches everything.
                    let phrase = current.trimmingCharacters(in: .whitespaces)
                    if !phrase.isEmpty { phrases.append(phrase) }
                    current = ""; closing = nil
                } else {
                    current.append(character)
                }
            } else if let expected = quotePairs[character] {
                endToken()
                closing = expected
            } else if character.isWhitespace {
                endToken()
            } else {
                current.append(character)
            }
        }
        // An unclosed quote is a typo, not an error: treat the rest as ordinary words rather than
        // returning nothing for a query the searcher clearly meant.
        if closing != nil {
            for word in current.split(whereSeparator: \.isWhitespace) { tokens.append(String(word)) }
        } else {
            endToken()
        }
        return Parsed(phrases: phrases, tokens: tokens)
    }

    /// The FTS5 expression for a parsed query: every phrase and token quoted, so nothing a
    /// searcher types can become an operator. Phrases keep their order; the rest is an implicit
    /// AND, which is what FTS5 does between bare terms.
    ///
    /// - Parameter lemmatised: the same phrases run through the lemmatiser, when it produced
    ///   anything. A document stores its lemmas in reading order, so a lemma phrase matches the
    ///   inflected original — `"адаптивной вёрсткой"` finds `адаптивная вёрстка`.
    static func expression(_ parsed: Parsed, lemmatised: [String?] = []) -> String? {
        guard !parsed.isEmpty else { return nil }
        func quoted(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }

        var parts: [String] = []
        for (index, phrase) in parsed.phrases.enumerated() {
            let lemma = index < lemmatised.count ? lemmatised[index] : nil
            if let lemma, !lemma.isEmpty, lemma != phrase {
                parts.append("(\(quoted(phrase)) OR \(quoted(lemma)))")
            } else {
                parts.append(quoted(phrase))
            }
        }
        parts.append(contentsOf: parsed.tokens.map(quoted))
        return parts.joined(separator: " AND ")
    }
}
