import ArgumentParser
import Foundation
import TelegramKBModel
import TelegramKBStore

/// The posts that shared one URL — `tgkb_find_links`, with the same paging.
struct Links: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the posts that link to a URL.")

    @OptionGroup var store: StoreOptions

    @Argument(help: ArgumentHelp("The link, whole.", discussion: """
        Matched on where it leads: a shortener finds the posts that link to its destination, and
        the destination finds every spelling that resolved to it. A site or a word is not a link;
        tgkb query searches link-preview titles for those.
        """))
    var url: String

    @OptionGroup var page: PageOptions

    func run() async throws {
        let db = try Store.openForReading(at: store.databasePath)
        // Hits and their posts from one read, as `tgkb_find_links` loads them.
        let found = try db.linkedPosts(to: url, limit: page.limit, cursor: page.cursor)
        let results = found.results
        PageOptions.warnIfIndexMoved(results.indexMovedSinceCursor)

        guard results.total > 0 else {
            print("no posts link to \(url.debugDescription) — it must be a whole link, not a site or a word; "
                  + "tgkb query searches link-preview titles")
            return
        }
        let byID = Dictionary(found.posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for hit in results.hits {
            guard let post = byID[hit.id] else { continue }
            print(Self.render(post: post, hit: hit))
        }
        print("\n" + PageOptions.footer(results.hits.count, of: results.total, noun: "post",
                                        nextCursor: results.nextCursor))
    }

    /// One hit's block — the post's date and permalink, the URL as written with its
    /// `(auto-linked)` mark and resolved target, then the post's own words about it.
    /// Extracted so the marker is testable, the same reason `Show.render` exists.
    static func render(post: Post, hit: Store.LinkHit) -> String {
        var lines = ["\(post.date.formatted(.iso8601.year().month().day()))  \(post.permalink)"]
        var line = "    \(hit.urlRaw)"
        if hit.isAutoLink == true { line += "  (auto-linked)" }
        if let resolved = hit.effectiveURL, resolved != hit.urlRaw { line += "  →  \(resolved)" }
        lines.append(line)
        // What the post said about the link — a body often says "статья" over its URL.
        let snippet = Query.snippet(post.text.isEmpty ? (post.poll?.question ?? "") : post.text)
        if !snippet.isEmpty { lines.append("    \(snippet)") }
        return lines.joined(separator: "\n")
    }
}
