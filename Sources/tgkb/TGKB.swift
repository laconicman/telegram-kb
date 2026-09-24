import ArgumentParser
import Foundation
import TelegramKBStore

/// The ingestion CLI. Owns all network and, later, all credentials.
///
/// Deliberately has **no `serve` subcommand** — the MCP server is the separate `tgkb-mcp`
/// binary. A working fat path would make the slim one vestigial: whichever binary the client
/// config points at becomes the real one, and the invariant that `tgkb-mcp` links nothing it
/// does not need would survive only as documentation. See `Design`.
///
/// `query` is not the same case and belongs here: it needs only the store, and it is how the
/// golden-query evals run without an MCP client in the loop.
@main
struct TGKB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tgkb",
        abstract: "Build and query a searchable knowledge base from Telegram channels.",
        subcommands: [Sync.self, Query.self, Doctor.self])
}

/// Options every subcommand shares.
struct StoreOptions: ParsableArguments {
    @Option(name: [.customLong("db")], help: "Path to the SQLite store.")
    var databasePath: String = Store.defaultPath

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: databasePath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
    }
}
