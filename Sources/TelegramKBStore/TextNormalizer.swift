import Foundation
import NaturalLanguage

/// Turns post text into the form that goes *into* the search index.
///
/// **Stored text stays verbatim; only index content is normalised** — the same principle as
/// `urlRaw`. What was crawled is a fact; the index is derived from it and can be rebuilt.
public enum TextNormalizer {

    /// Folds `ё` to `е`.
    ///
    /// `unicode61 remove_diacritics 2` does **not** do this — `ё` is a distinct Cyrillic letter,
    /// not an accented `е`. Verified: index `вёрстка`, query `верстка`, zero hits. 5% of posts in
    /// one corpus channel contain `ё`, and Telegram's own search folds them (`TD-10`).
    ///
    /// Must be applied to **both** the indexed text and the query, or it makes matters worse.
    public static func foldYo(_ s: String) -> String {
        s.replacingOccurrences(of: "ё", with: "е")
         .replacingOccurrences(of: "Ё", with: "Е")
    }

    /// Lemmas for `text`, or `nil` when the text is too short to identify a language.
    ///
    /// **The language is always set explicitly.** Under auto-detection a *single* Russian word
    /// silently yields no tag at all — including the nominative form, which is the one most
    /// likely to be typed as a query (`TD-4`). Detection happens once over the whole post, which
    /// has enough text to be reliable, and the result is reused for its tokens.
    public static func lemmas(_ text: String, language: NLLanguage? = nil) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lang: NLLanguage
        if let language {
            lang = language
        } else {
            let rec = NLLanguageRecognizer()
            rec.processString(text)
            guard let detected = rec.dominantLanguage else { return nil }
            lang = detected
        }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        tagger.setLanguage(lang, range: text.startIndex..<text.endIndex)
        var out: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, range in
            // An unknown token (a library name, say) has no lemma; index it verbatim.
            out.append((tag?.rawValue ?? String(text[range])).lowercased())
            return true
        }
        return out.isEmpty ? nil : out.joined(separator: " ")
    }

    /// The blob indexed for word search: folded text plus its lemmas, so both an exact form and
    /// an inflected one match.
    /// The two things a post contributes to the word index, kept apart.
    ///
    /// They used to be one string with a newline between them, and FTS5 tokenises a newline
    /// away — so a quoted phrase could match the last word of the text followed by the first
    /// lemma, a post that contains the phrase in neither form. They live in separate columns now.
    public static func indexed(text: String, extras: [String] = []) -> (surface: String, lemmas: String) {
        let joined = ([text] + extras.filter { !$0.isEmpty }).joined(separator: "\n")
        let folded = foldYo(joined)
        return (folded, lemmas(folded) ?? "")
    }

    /// Normalises a user query the same way the index was built. Never skip this.
    public static func normalizeQuery(_ q: String) -> String { foldYo(q) }
}
