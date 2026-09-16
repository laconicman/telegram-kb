import ArgumentParser
import Foundation
import TelegramKBIngest
import TelegramKBModel
import TelegramKBStore
import TelegramKBSync

/// Crawls channels and writes them to the store.
struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Crawl channels and update the local index.")

    @OptionGroup var store: StoreOptions

    @Argument(help: "Channel usernames, without the @.")
    var channels: [String] = []

    @Flag(name: .long, help: ArgumentHelp(
        "Re-crawl from the newest page, overwriting stored copies of every post it sees.",
        discussion: """
            Refreshes content; it does not reconcile. Posts since deleted on Telegram stay in \
            the index by design — a citation must not vanish because its source did.
            """))
    var full = false

    @Option(name: .long, help: "Seconds between requests.")
    var delay: Double = 1.0

    @Option(name: .long, help: "Import resolver JSONL into url_resolution and exit.")
    var importResolutions: String?

    /// Negative or non-finite values would reach `Duration.seconds` and the rate-limit
    /// arithmetic. Zero is valid — no delay is a legitimate, if impolite, request.
    func validate() throws {
        guard delay.isFinite, delay >= 0 else {
            throw ValidationError("--delay must be a finite number of seconds, zero or greater (got \(delay)).")
        }
    }

    /// Why a channel was not crawled, in the words the person running it needs.
    static func explain(_ reachability: Channel.Reachability) -> String {
        switch reachability {
        case .previewDisabled:
            // Its embeds still render a frame, but body text and media are withheld, so there is
            // nothing worth indexing until TDLib.
            "web preview disabled by the owner — needs TDLib (Phase 2)"
        case .group:      "a group, not a broadcast channel — needs TDLib (Phase 2)"
        case .unresolvable: "not publicly resolvable"
        case .webPreview: "crawlable"
        }
    }

    func run() async throws {
        try store.ensureDirectory()
        let db = try Store.openForWriting(at: store.databasePath)

        if let path = importResolutions {
            let report = try db.importResolutions(fromJSONLAt: path)
            print("imported \(report.imported) resolutions")
            if report.skipped > 0 {
                // Loud on purpose: a skipped row is a resolution we will never have.
                let msg = "warning: \(report.skipped) unreadable row(s) skipped — the file "
                        + "may be truncated or from a different schema\n"
                FileHandle.standardError.write(Data(msg.utf8))
                // Non-zero, not just a warning. Automation reads exit status, not stderr prose,
                // and a zero exit on a partial import is a check reporting success because it
                // did not fully run.
                throw ExitCode(3)
            }
            return
        }
        guard !channels.isEmpty else {
            throw ValidationError("Name at least one channel, or pass --import-resolutions.")
        }

        let fetcher = URLSessionPageFetcher(delay: .seconds(delay))
        let sync = ChannelSync(store: db, fetcher: fetcher)

        // The loop itself lives in `TelegramKBSync`, where tests can drive it. What stays here is
        // what a CLI owns: arguments, and words on a terminal.
        for channel in channels {
            let outcome = try await sync.sync(channel: channel, full: full)
            if let skipped = outcome.skipped {
                FileHandle.standardError.write(Data("\(outcome.channel): \(Self.explain(skipped))\n".utf8))
                continue
            }
            print("\(outcome.channel): \(outcome.postCount) posts, \(outcome.pagesFetched) pages"
                + (outcome.since.map { ", since \($0)" } ?? ", full backfill"))
        }
    }
}
