import Foundation
import NaturalLanguage

// Reads JSONL on stdin, emits "<id>\t<lemmas>" per line. Language detected per post.
let rec = NLLanguageRecognizer()
var n = 0
let t0 = Date()
while let line = readLine() {
    guard let d = line.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let id = o["id"] as? Int else { continue }
    var text = (o["text"] as? String) ?? ""
    if let p = o["preview"] as? [String: Any] {
        text += " " + [p["title"], p["desc"]].compactMap { $0 as? String }.joined(separator: " ")
    }
    guard !text.isEmpty else { print("\(id)\t"); continue }
    rec.reset(); rec.processString(text)
    let lang = rec.dominantLanguage ?? .russian          // explicit — never auto per-token
    let tagger = NLTagger(tagSchemes: [.lemma])
    tagger.string = text
    tagger.setLanguage(lang, range: text.startIndex..<text.endIndex)
    var out: [String] = []
    tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                         options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, r in
        out.append((tag?.rawValue ?? String(text[r])).lowercased()); return true
    }
    print("\(id)\t\(out.joined(separator: " "))")
    n += 1
}
FileHandle.standardError.write("lemmatised \(n) posts in \(String(format: "%.1f", -t0.timeIntervalSinceNow))s\n".data(using: .utf8)!)
