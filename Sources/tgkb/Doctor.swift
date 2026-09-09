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
        let path = store.databasePath
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        print("store: \(path)")
        print("  exists:            \(FileManager.default.fileExists(atPath: path))")

        // Checked explicitly because SQLite's own error names the DATABASE as read-only when in
        // fact the DIRECTORY is unwritable — a WAL reader must still create the -shm file. The
        // message sends whoever debugs it at the wrong file (TD-6).
        let writable = FileManager.default.isWritableFile(atPath: directory.path)
        print("  directory writable: \(writable)"
            + (writable ? "" : "  <- a read-only open will fail with 'attempt to write a readonly database'"))

        if FileManager.default.fileExists(atPath: path) {
            do {
                let db = try Store.openForReading(at: path)
                let n = try db.searchWords("a", limit: 1).count
                print("  read-only open:    ok (\(n >= 0 ? "queryable" : ""))")
            } catch {
                print("  read-only open:    FAILED — \(error)")
            }
        }

        // Integrity: ids are a dense sequence, posts are not dense within it. An album covers
        // several consecutive ids, so most absences are explained by mediaCount. A LONG run of
        // unexplained ids is the one worth alarming about — that is a missed page, not deletions.
        if FileManager.default.fileExists(atPath: path), let db = try? Store.openForReading(at: path) {
            let names = try db.channelUsernames()
            if !names.isEmpty { print("\nintegrity:") }
            for name in names {
                guard let i = try db.integrity(forChannel: name) else { continue }
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

        guard !channels.isEmpty else { return }
        print("\nchannels:")
        let fetcher = URLSessionPageFetcher(delay: .seconds(1))
        let classifier = ChannelClassifier(fetcher: fetcher)
        for channel in channels {
            let verdict = try await classifier.classify(channel)
            let note: String
            switch verdict {
            case .webPreview:      note = "crawlable now"
            case .previewDisabled: note = "owner disabled the preview — embeds render a frame but withhold content; needs TDLib"
            case .group:           note = "a group, not a broadcast channel; needs TDLib"
            case .unresolvable:    note = "not publicly resolvable"
            }
            print("  @\(channel): \(verdict.rawValue) — \(note)")
        }
    }
}
