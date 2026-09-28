import Foundation
import TelegramKBStore

/// `tgkb sync --import-resolutions`: the standalone resolver's JSONL into the store.
///
/// Like ``ChannelSync`` and ``ChatImport``, a library so its wiring can be tested — the
/// executable cannot be imported, and this path's WAL reclaim was the one no test could reach
/// (PR #6, review round 4). It is a write session like the others, so it ends the same way
/// (`Store.endingWithWALReclaim`, TD-22); the CLI only reports.
public enum ResolutionImport {

    public struct Outcome: Sendable, Equatable {
        public var imported: Int
        /// Unreadable rows: resolutions we will never have, which the CLI reports loudly.
        public var skipped: Int
        /// The end-of-session WAL reclaim failed with a real error (`TD-22`).
        public var walCleanupFailed: Bool
    }

    public static func run(store: Store, jsonl path: String) async throws -> Outcome {
        let session = try await store.endingWithWALReclaim {
            try store.importResolutions(fromJSONLAt: path)
        }
        return Outcome(imported: session.value.imported, skipped: session.value.skipped,
                       walCleanupFailed: session.walCleanupFailed)
    }
}
