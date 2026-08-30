// swift-tools-version: 6.1
import PackageDescription

// The TDLib ingestion path is trait-gated. Verified empirically (research/spm-traits-binarytarget.md):
// with the trait off, SwiftPM does not resolve the dependency, does not download the ~binary
// artifact, and `swift package show-dependencies` reports it as absent entirely.
let package = Package(
    name: "telegram-kb",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TelegramKB", targets: ["TelegramKB"]),
        .executable(name: "tgkb", targets: ["tgkb"]),
        .executable(name: "tgkb-mcp", targets: ["tgkb-mcp"]),
    ],
    traits: [
        .trait(
            name: "TDLib",
            description: "Enable the TDLib ingestion source. Pulls a large prebuilt XCFramework."
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.7"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.5.0"),
        // NB: TDLibKit tags are pre-release-shaped (`1.5.2-tdlib-1.8.66-022d6020`), so a version
        // *range* will not select them — SwiftPM excludes pre-releases from ranges. Must be .exact.
        .package(url: "https://github.com/Swiftgram/TDLibKit.git",
                 exact: "1.5.2-tdlib-1.8.66-022d6020"),
    ],
    targets: [
        // Docs-only umbrella. Hosts the DocC catalog; carries no API.
        .target(name: "TelegramKB", dependencies: ["TelegramKBModel"]),

        .target(name: "TelegramKBModel"),

        .target(name: "TelegramKBStore", dependencies: [
            "TelegramKBModel",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),

        .target(name: "TelegramKBIngest", dependencies: [
            "TelegramKBModel", "TelegramKBStore",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
        ]),

        // The ONLY target permitted to link TDLibKit.
        .target(name: "TelegramKBIngestTDLib", dependencies: [
            "TelegramKBModel", "TelegramKBStore",
            .product(name: "TDLibKit", package: "TDLibKit", condition: .when(traits: ["TDLib"])),
        ]),

        .target(name: "TelegramKBMCP", dependencies: [
            "TelegramKBModel", "TelegramKBStore",
            .product(name: "MCP", package: "swift-sdk"),
        ]),

        // The fat binary by design: login, sync, query, doctor. Deliberately NOT `serve` —
        // see <doc:Design> "Why `tgkb` has no `serve` subcommand". `query` is not the same
        // case and stays: it needs only the Store, and it is how the golden-query evals run
        // without an MCP client in the loop.
        .executableTarget(name: "tgkb", dependencies: [
            "TelegramKBIngest", "TelegramKBStore",
            .target(name: "TelegramKBIngestTDLib", condition: .when(traits: ["TDLib"])),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),

        // Hard invariant, stated positively: the transitive target closure of `tgkb-mcp` must
        // be exactly {TelegramKBMCP, TelegramKBStore, TelegramKBModel}. An allowlist fails
        // loudly on any addition; a check for the *absence* of TelegramKBIngestTDLib would
        // pass for the wrong reasons as the graph grows. Enforced by Scripts/check-invariants.sh.
        .executableTarget(name: "tgkb-mcp", dependencies: ["TelegramKBMCP", "TelegramKBStore"]),

        .testTarget(name: "TelegramKBStoreTests", dependencies: ["TelegramKBStore"]),
        .testTarget(name: "TelegramKBIngestTests", dependencies: ["TelegramKBIngest"]),
    ]
)
