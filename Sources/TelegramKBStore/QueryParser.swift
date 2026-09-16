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
        /// Everything outside quotes, split on whitespace. Order carries no meaning to word
        /// search, which ANDs them.
        public var tokens: [String]
        /// Every piece in the order it was typed, phrases and tokens alike. Substring search is
        /// literal, so it must rebuild the query as written: grouping the phrases first searched
        /// a sequence the searcher never asked for, and lost real matches.
        public var pieces: [String]
        public var isEmpty: Bool { phrases.isEmpty && tokens.isEmpty }
    }

    /// Opening character → the character that closes it. `"` closes itself.
    static let quotePairs: [Character: Character] = ["\"": "\"", "“": "”", "«": "»", "„": "“"]

    public static func parse(_ query: String) -> Parsed {
        var phrases: [String] = [], tokens: [String] = [], pieces: [String] = []
        var current = "", closing: Character?

        func endToken() {
            let token = current.trimmingCharacters(in: .whitespaces)
            if !token.isEmpty { tokens.append(current); pieces.append(token) }
            current = ""
        }
        for character in query {
            if let expected = closing {
                if character == expected {
                    // An empty pair — `""` — is not a phrase; it says nothing and must not become
                    // a pattern that matches everything.
                    let phrase = current.trimmingCharacters(in: .whitespaces)
                    if !phrase.isEmpty { phrases.append(phrase); pieces.append(phrase) }
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
            for word in current.split(whereSeparator: \.isWhitespace) {
                tokens.append(String(word)); pieces.append(String(word))
            }
        } else {
            endToken()
        }
        return Parsed(phrases: phrases, tokens: tokens, pieces: pieces)
    }

    /// The FTS5 expression for a parsed query: every phrase and token quoted, so nothing a
    /// searcher types can become an operator. Phrases keep their order; the rest is an implicit
    /// AND, which is what FTS5 does between bare terms.
    ///
    /// **Columns matter here.** A phrase whose lemmatised form differs is searched as
    /// `(content:"surface" OR lemmas:"lemmas")` — qualified, because an unqualified phrase may
    /// match across the two columns' boundary and find a post that contains it in neither form.
    /// A phrase the lemmatiser leaves alone stays unqualified on purpose, so that a query in the
    /// dictionary form still finds a post that only carries an inflected one.
    ///
    /// - Parameters:
    ///   - phraseLemmas: each phrase run through the lemmatiser, or `nil` where it produced
    ///     nothing. Documents store lemmas in reading order, so a lemma phrase matches the
    ///     inflected original — `"адаптивной вёрсткой"` finds *адаптивная вёрстка*.
    ///   - tokenLemmas: the same for loose tokens. Without them a query carrying any phrase lost
    ///     lemmatisation for its other words, so it found less than the same query unquoted.
    static func expression(_ parsed: Parsed,
                           phraseLemmas: [String?] = [],
                           tokenLemmas: [String?] = []) -> String? {
        guard !parsed.isEmpty else { return nil }
        func quoted(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }

        func widened(_ text: String, _ lemma: String?, qualified: Bool) -> String {
            guard let lemma, !lemma.isEmpty, lemma != text else { return quoted(text) }
            return qualified
                ? "(content:\(quoted(text)) OR lemmas:\(quoted(lemma)))"
                : "(\(quoted(text)) OR \(quoted(lemma)))"
        }

        var parts: [String] = []
        for (index, phrase) in parsed.phrases.enumerated() {
            parts.append(widened(phrase, index < phraseLemmas.count ? phraseLemmas[index] : nil,
                                 qualified: true))
        }
        for (index, token) in parsed.tokens.enumerated() {
            parts.append(widened(token, index < tokenLemmas.count ? tokenLemmas[index] : nil,
                                 qualified: false))
        }
        return parts.joined(separator: " AND ")
    }
}
