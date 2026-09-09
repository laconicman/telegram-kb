import ArgumentParser
import Foundation
import TelegramKBModel
import TelegramKBStore

/// Searches the store from the terminal.
///
/// Exists so retrieval quality is measurable without an MCP client in the loop — this is how
/// `evals/golden-queries.md` is run.
struct Query: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search the local index.")

    @OptionGroup var store: StoreOptions

    @Argument(help: "What to search for.")
    var terms: [String]

    @Option(name: .long, help: "words | substring | both")
    var mode: Mode = .both

    @Option(name: .shortAndLong, help: "Maximum results.")
    var limit: Int = 20

    @Flag(name: .long, help: "Print ids and counts only — for eval scripting.")
    var quiet = false

    enum Mode: String, ExpressibleByArgument { case words, substring, both }

    func run() async throws {
        let db = try Store.openForReading(at: store.databasePath)
        let query = terms.joined(separator: " ")

        var hits: [Store.Hit] = []
        if mode != .substring { hits += try db.searchWords(query, limit: limit) }
        if mode != .words {
            let seen = Set(hits.map(\.id))
            hits += try db.searchSubstring(query, limit: limit).filter { !seen.contains($0.id) }
        }
        hits = Array(hits.prefix(limit))

        if quiet {
            print(hits.count)
            for h in hits { print("\(h.id.channelUsername)/\(h.id.messageID)") }
            return
        }
        guard !hits.isEmpty else { print("no results for \(query.debugDescription)"); return }

        for hit in hits {
            guard let post = try db.post(hit.id) else { continue }
            let date = post.date.formatted(.iso8601.year().month().day())
            let reactions = post.totalReactions > 0 ? "  ♥\(post.totalReactions)" : ""
            // A compact record with a citable link — never the full body. Of seven Telegram MCP
            // servers surveyed, not one emits a link its output can be cited by.
            print("\(date)  \(post.permalink)\(reactions)")
            print("    \(Self.snippet(post.text.isEmpty ? (post.poll?.question ?? "") : post.text))")
        }
        print("\n\(hits.count) result(s)")
    }

    static func snippet(_ text: String, limit: Int = 140) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}
