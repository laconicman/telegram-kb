import ArgumentParser
import Foundation
import TelegramKBIngest
import TelegramKBModel
import TelegramKBStore
import TelegramKBSync

/// Loads a Telegram client's chat export — the way in for a public group, which has no web
/// preview. The decisions live in `ChatImport`; what stays here is arguments and words.
struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Load a chat export (Telegram's “Export Chat History”, HTML) into the local index.",
        discussion: """
            The way in for a public group, which has no web preview. The export does not name the \
            chat, so --channel does. Its dates carry no offset: they are read in --timezone, which \
            must be the zone of the Mac that wrote the export.

            Before anything is written, one message is fetched from t.me/<channel>/<id>?embed=1: \
            its words prove the export is this chat, its moment proves the zone, and it names the \
            chat's id. --no-verify skips that — for a chat with no public username.
            """)

    @OptionGroup var store: StoreOptions

    @Argument(help: "The export's folder — the one holding messages.html.")
    var export: String

    @Option(help: "The chat's username, without the @.")
    var channel: String

    @Option(help: "The time zone of the Mac that wrote the export, e.g. Europe/Moscow. Default: this Mac's.")
    var timezone: String?

    @Flag(help: "Overwrite posts already stored — for an export taken after edits.")
    var replace = false

    @Flag(name: .customLong("no-verify"), help: "Import without the check against t.me: nothing verified, no id learned.")
    var noVerify = false

    func validate() throws {
        if let timezone, TimeZone(identifier: timezone) == nil {
            throw ValidationError("Unknown time zone \(timezone) — use an identifier such as Europe/Moscow.")
        }
        if channel.hasPrefix("@") || channel.isEmpty {
            throw ValidationError("--channel takes the username without the @ (got \(channel)).")
        }
    }

    func run() async throws {
        try store.ensureDirectory()
        let db = try Store.openForWriting(at: store.databasePath)
        let zone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let outcome = try await ChatImport(store: db, fetcher: noVerify ? nil : URLSessionPageFetcher())
            .run(export: URL(fileURLWithPath: export), channel: channel, timeZone: zone,
                 policy: replace ? .replace : .keepExisting)

        let range = outcome.lowest.flatMap { lo in outcome.highest.map { "ids \(lo)–\($0)" } } ?? "no ids"
        print("@\(outcome.channel)\(outcome.title.map { " «\($0)»" } ?? ""): \(outcome.posts) posts, \(range)")
        print("  written \(outcome.written), kept \(outcome.kept) already stored"
            + (outcome.kept > 0 ? " — --replace refreshes them" : "")
            + "; \(outcome.serviceMessages) service messages are not posts")
        if let verified = outcome.verifiedMessageID {
            print("  verified against t.me/\(outcome.channel)/\(verified): this chat, dates in \(zone.identifier)"
                + (outcome.rawChannelID.map { "; chat id \($0)" } ?? ""))
        } else {
            print("  not verified (--no-verify): dates read in \(zone.identifier), chat id unknown")
        }
        if outcome.unreadable > 0 {
            // Loud and non-zero, as for resolver rows: these posts are missing from the index, and
            // automation reads the exit status, not the prose.
            let warning = "warning: \(outcome.unreadable) message block(s) could not be read and are MISSING — "
                        + "the export's format may have changed\n"
            FileHandle.standardError.write(Data(warning.utf8))
            throw ExitCode(3)
        }
    }
}
