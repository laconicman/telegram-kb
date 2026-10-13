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
        usage: tgkb-mcp [--db <path>] [--version]
          --db        SQLite store (default: \(Store.defaultPath))
          --version   Print the build's version, as `tgkb --version` does, and exit.
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
    case "--version":
        // The one stdout write here, and a safe one: it exits before any transport exists, so
        // there is no protocol stream to corrupt yet.
        print(BuildVersion.string)
        exit(0)
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

logger.info("tgkb-mcp \(BuildVersion.string) serving \(databasePath)")
let server: Server
do {
    server = try await TGKBServer.makeServer(store: store, version: BuildVersion.string)
} catch {
    fail("cannot read \(databasePath): \(error)")
}
try await server.start(transport: TGKBServer.guardedStdioTransport(logger: logger))
await server.waitUntilCompleted()
