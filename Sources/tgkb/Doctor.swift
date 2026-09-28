import ArgumentParser
import Foundation
import TelegramKBIngest
import TelegramKBStore

/// Checks the things whose failure messages point at the wrong problem.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the store and channel reachability.")

    @OptionGroup var store: StoreOptions

    @Argument(help: "Channel usernames to classify, without the @.")
    var channels: [String] = []

    func run() async throws {
        let healthy = try reportStore(at: store.databasePath)
        // Channel reachability is independent of the store, and is the one check that still
        // works before the first sync — so it runs even when the store is missing.
        try await classifyChannels()
        // Printing FAILED is for the person reading; only the exit status reaches automation,
        // and a later check passing does not undo an earlier failure.
        guard healthy else { throw ExitCode(1) }
    }

    /// - Returns: `false` if any store check failed. Every early return is a failure; reaching
    ///   the end means every check passed.
    private func reportStore(at path: String) throws -> Bool {
        print("store: \(path)")

        // Checked explicitly because SQLite's own error names the DATABASE as read-only when in
        // fact the DIRECTORY is unwritable — a WAL reader must still create the -shm file. The
        // message sends whoever debugs it at the wrong file (TD-6).
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let writable = FileManager.default.isWritableFile(atPath: directory.path)
        print("  directory writable: \(writable)"
            + (writable ? "" : "  <- a read-only open will fail with 'attempt to write a readonly database'"))
        // Not an early return: an existing -shm file lets today's open succeed, so the remaining
        // checks still carry information. It is still a failure — `tgkb-mcp` will fail on a
        // machine where that file has been cleaned up, which is the whole of TD-6.

        guard FileManager.default.fileExists(atPath: path) else {
            print("  exists:            false  <- nothing to check; run `tgkb sync` first")
            return false
        }
        print("  exists:            true")

        // One open for both checks. Not `try?`: a swallowed failure would skip every channel's
        // integrity check, and a doctor that reports nothing looks exactly like one that found
        // nothing wrong.
        let db: Store
        do {
            db = try Store.openForReading(at: path)
            _ = try db.searchWords("a", limit: 1)
        } catch {
            print("  read-only open:    FAILED — \(error)")
            print("\nintegrity: SKIPPED — the store could not be read")
            return false
        }
        print("  read-only open:    ok (queryable)")

        try reportIntegrity(db)
        return writable
    }

    /// Integrity: ids are a dense sequence, posts are not dense within it. An album covers
    /// several consecutive ids, so most absences are explained by `mediaCount`. A LONG run of
    /// unexplained ids is the one worth alarming about — that is a missed page, not deletions.
    private func reportIntegrity(_ db: Store) throws {
        let names = try db.channelUsernames()
        guard !names.isEmpty else { return }
        print("\nintegrity:")
        for name in names {
            guard let i = try db.integrity(forChannel: name) else { continue }
            if i.reachability == .group {
                // Imported, never crawled: there is no page to have missed and no sync to come, and a
                // group's joins and pins take ids no post fills. The crawl alarms would all be false.
                print("  @\(name): \(i.posts) posts, ids \(i.lowest)–\(i.highest) — a group, from a chat export")
                print("    \(i.unexplained) ids hold no post: service messages (joins, pins) and deletions")
                continue
            }
            let pct = Double(i.covered) / Double(i.highest - i.lowest + 1) * 100
            print(String(format: "  @%@: %d posts, ids %d–%d, %.1f%% of the id range accounted for",
                         name, i.posts, i.lowest, i.highest, pct))
            print("    unexplained ids: \(i.unexplained) (deletions and service messages are normal)")
            if let start = i.longestGapStart, i.longestGap >= 25 {
                print("    ⚠︎ longest unexplained run: \(i.longestGap) ids from \(start)"
                    + " — long runs suggest a missed PAGE rather than deletions; consider --full")
            } else {
                print("    longest unexplained run: \(i.longestGap) — consistent with scattered deletions")
            }
            if !i.backfillComplete {
                print("    ⚠︎ backfill never completed — the next sync will re-crawl in full")
            }
        }
    }

    private func classifyChannels() async throws {
        guard !channels.isEmpty else { return }
        print("\nchannels:")
        let classifier = ChannelClassifier(fetcher: URLSessionPageFetcher(delay: .seconds(1)))
        for channel in channels.map({ $0.lowercased() }) {
            let verdict = try await classifier.classify(channel)
            let note: String
            switch verdict {
            case .webPreview:      note = "crawlable now"
            case .previewDisabled: note = "owner disabled the preview — embeds render a frame but withhold content; needs TDLib"
            case .group:           note = "a group, not a broadcast channel; load a chat export with `tgkb import`"
            case .unresolvable:    note = "not publicly resolvable"
            }
            print("  @\(channel): \(verdict.rawValue) — \(note)")
        }
    }
}
