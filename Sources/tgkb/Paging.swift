import ArgumentParser
import Foundation

/// `--limit` and `--cursor`: how `query` and `links` page, with the opaque cursor
/// `tgkb_search_posts` and `tgkb_find_links` hand out — a cursor from either binary continues
/// in the other, because both build the same filter from the same arguments.
struct PageOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Maximum results on this page.")
    var limit: Int = 20

    @Option(help: "Continue after an earlier page: the cursor its last line printed.")
    var cursor: String?

    /// `Array.prefix` **traps** on a negative length, so a bad `--limit` would crash rather than
    /// report. SQLite treats a negative LIMIT as unlimited, so the failure surfaces only later,
    /// in Swift. Zero stays valid — an empty result set is a legitimate request.
    func validate() throws {
        guard limit >= 0 else {
            throw ValidationError("--limit must be zero or greater (got \(limit)).")
        }
    }

    /// The page's last line. The store decides whether a page continues (`nextCursor`), so this
    /// follows it: a final page smaller than `total` is the end of the walk, not a page to raise
    /// `--limit` on. The cursor is printed under the flag that takes it.
    static func footer(_ shown: Int, of total: Int, noun: String, nextCursor: String?) -> String {
        if let nextCursor {
            return "\(shown) of \(total) \(noun)(s) — for the rest, add --cursor \(nextCursor)"
        }
        return shown < total ? "\(shown) of \(total) \(noun)(s)" : "\(shown) \(noun)(s)"
    }

    /// A sync committed between the cursor's page and this one, so a post may have been skipped
    /// or repeated across the boundary. On stderr: `--quiet` output is parsed.
    static func warnIfIndexMoved(_ moved: Bool) {
        guard moved else { return }
        FileHandle.standardError.write(Data("""
            note: the index changed since that cursor was printed — a post may have been skipped \
            or repeated. Run again without --cursor to restart the walk.\n
            """.utf8))
    }
}
