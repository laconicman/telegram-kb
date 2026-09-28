import Foundation
import Logging
import MCP
import TelegramKBMCP
import TelegramKBStore

// The read-only MCP server over the store. No network, no credentials, no writes —
// the target closure is enforced by Scripts/check-invariants.sh.
//
// fd 1 is the protocol channel: the spec reserves stdout for MCP messages and sanctions
// stderr as the diagnostics stream. Log there; `guardedStdioTransport` makes anything
// else that prints land there too.
LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }
let logger = Logger(label: "tgkb-mcp")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("tgkb-mcp: \(message)\n".utf8))
    exit(1)
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: tgkb-mcp [--db <path>]
          --db   SQLite store (default: \(Store.defaultPath))
        Serves the MCP protocol on stdin/stdout. See Design § "MCP tool surface".
        """.utf8))
    exit(2)
}

// Parsed by hand, not ArgumentParser: this binary's target closure is allowlisted, and
// one flag does not justify widening it.
var databasePath = Store.defaultPath
var argv = CommandLine.arguments.dropFirst()
while let arg = argv.popFirst() {
    switch arg {
    case "--db":
        guard let value = argv.popFirst() else { usage() }
        databasePath = value
    case "-h", "--help":
        usage()
    default:
        usage()
    }
}

let store: Store
do {
    store = try Store.openForReading(at: databasePath)
} catch {
    fail("cannot open \(databasePath): \(error). Sync first — tgkb sync @channel.")
}

logger.info("tgkb-mcp \(TGKBServer.version) serving \(databasePath)")
let server = await TGKBServer.makeServer(store: store)
try await server.start(transport: TGKBServer.guardedStdioTransport(logger: logger))
await server.waitUntilCompleted()
