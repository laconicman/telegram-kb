import ArgumentParser
import Foundation
import TelegramKBModel
import TelegramKBStore

/// Searches the store from the terminal — `tgkb_search_posts`, with the same filters and paging.
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

    @Option(help: "Only this channel or group; a leading @ is accepted.")
    var channel: String?

    @Option(help: "Only this kind of post.")
    var kind: PostKind?

    @Option(help: ArgumentHelp(
        "Oldest post date, inclusive: ISO-8601, or YYYY-MM-DD for a whole UTC day.",
        valueName: "date"))
    var from: Store.SearchFilter.DateBound?

    @Option(help: ArgumentHelp(
        "Newest post date, inclusive: ISO-8601, or YYYY-MM-DD for a whole UTC day.",
        valueName: "date"))
    var to: Store.SearchFilter.DateBound?

    @OptionGroup var page: PageOptions

    @Flag(name: .long, help: "Print ids and counts only — for eval scripting.")
    var quiet = false

    /// What `--channel`, `--kind`, `--from` and `--to` describe, through the grammar
    /// `tgkb_search_posts` shares — so equal arguments build equal filters, and a cursor from one
    /// binary continues in the other.
    var filter: Store.SearchFilter {
        var filter = Store.SearchFilter(channel: channel, kind: kind)
        if let from { filter.narrow(from: from) }
        if let to { filter.narrow(to: to) }
        return filter
    }

    func run() async throws {
        let db = try Store.openForReading(at: store.databasePath)
        let query = terms.joined(separator: " ")

        // The merge policy lives in the store, not here: `tgkb-mcp` cannot depend on this target.
        // Hits and their posts from ONE read, as `tgkb_search_posts` loads them: a sync committing
        // between two reads would pair this page's total and cursor with another corpus.
        let found = try db.searchPosts(query, mode: mode, filter: filter, limit: page.limit,
                                       cursor: page.cursor)
        let results = found.results
        PageOptions.warnIfIndexMoved(results.indexMovedSinceCursor)

        if quiet {
            print(results.hits.count)
            for h in results.hits { print("\(h.id.channelUsername)/\(h.id.messageID)") }
            return
        }
        // `total`, not this page: `--limit 0`, or a cursor at the end, is an empty page of a
        // non-empty result.
        guard results.total > 0 else { print("no results for \(query.debugDescription)"); return }

        for post in found.posts {
            let date = post.date.formatted(.iso8601.year().month().day())
            let reactions = post.totalReactions > 0 ? "  ♥\(post.totalReactions)" : ""
            // A compact record with a citable link — never the full body. Of seven Telegram MCP
            // servers surveyed, not one emits a link its output can be cited by.
            print("\(date)  \(post.permalink)\(reactions)")
            print("    \(Self.snippet(post.text.isEmpty ? (post.poll?.question ?? "") : post.text))")
        }
        print("\n" + PageOptions.footer(found.posts.count, of: results.total, noun: "result",
                                        nextCursor: results.nextCursor))
    }

    static func snippet(_ text: String, limit: Int = 140) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}

extension Store.SearchMode: ExpressibleByArgument {}

// The grammar is the store's and the model's, shared with `tgkb-mcp`; these only adapt it to
// ArgumentParser, which then lists the kinds in `--help`.
extension PostKind: ExpressibleByArgument {}

extension Store.SearchFilter.DateBound: ExpressibleByArgument {
    public init?(argument: String) { self.init(parsing: argument) }
}
