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

    @Argument(help: ArgumentHelp("What to search for.", discussion: """
        Terms match in any order, and all of them must appear.
        Quote a run of words to require that ORDER instead:
          tgkb query '"адаптивная вёрстка"'   only that phrase
          tgkb query  адаптивная вёрстка      both words, any order
        Case and ё/е never matter. «…» and “…” quote a phrase as well as "…".

        The quotes must survive the shell, hence the single quotes above.
        A plain tgkb query "адаптивная вёрстка" arrives with the quotes already
        eaten by the shell, and is an unordered pair of terms.
        """))
    var terms: [String]

    @Option(name: .long, help: "words | substring | both (word hits first, then substring-only)")
    var mode: Store.SearchMode = .both

    @Option(name: .shortAndLong, help: "Maximum results.")
    var limit: Int = 20

    @Flag(name: .long, help: "Print ids and counts only — for eval scripting.")
    var quiet = false

    /// `Array.prefix` **traps** on a negative length, so a bad `--limit` would crash rather than
    /// report. SQLite treats a negative LIMIT as unlimited, so the failure surfaces only later,
    /// in Swift. Zero stays valid — an empty result set is a legitimate request.
    func validate() throws {
        guard limit >= 0 else {
            throw ValidationError("--limit must be zero or greater (got \(limit)).")
        }
    }

    func run() async throws {
        let db = try Store.openForReading(at: store.databasePath)
        let query = terms.joined(separator: " ")

        // The merge policy lives in the store, not here: `tgkb-mcp` cannot depend on this target.
        let results = try db.search(query, mode: mode, limit: limit)
        let hits = results.hits

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
        print(hits.count < results.total
              ? "\n\(hits.count) of \(results.total) result(s) — raise --limit for the rest"
              : "\n\(hits.count) result(s)")
    }

    static func snippet(_ text: String, limit: Int = 140) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}

extension Store.SearchMode: ExpressibleByArgument {}
