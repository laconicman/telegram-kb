import Foundation
import TelegramKBIngest
import TelegramKBModel
import TelegramKBStore

/// Loads a Telegram client's chat export into the store — the way in for a public **group**,
/// which no web page lists (`ChannelClassifier` finds "N members" and `/s/` redirects).
///
/// Like ``ChannelSync``, this is a library so its decisions can be tested; the CLI only reports.
/// The sequence, and why each step is where it is:
///
/// 1. **Parse.** Nothing is written from an export with no readable post.
/// 2. **Never mix sources.** A username the store crawls from the web is a channel, not this
///    group, and the two sources disagree on albums.
/// 3. **Verify against one embed**, when a fetcher is given: the newest message with text is fetched
///    from `t.me/<chat>/<id>?embed=1`. Different words mean the export is not this chat; a
///    different moment means the export's zone is wrong — its dates carry no offset. The embed
///    also names the chat's bare id, so the import learns `rawChannelID`.
/// 4. **One chat, one row.** Until `S7` keys channels by `rawChannelID`, nothing in the schema stops
///    two usernames holding one id, so it is checked here, before anything is written.
/// 5. **Write in batches**, each one `commitPage`: the posts and the id bounds they extend commit
///    together. `backfillComplete` is never set — an export is a snapshot of a chat, not a walk
///    that proved it reached the start — and a group is never synced, so nothing reads it.
public struct ChatImport: Sendable {
    let store: Store
    let fetcher: PageFetcher?
    let batchSize: Int

    /// - Parameter fetcher: `nil` imports offline: nothing is verified and no id is learned.
    public init(store: Store, fetcher: PageFetcher?, batchSize: Int = 1_000) {
        self.store = store
        self.fetcher = fetcher
        self.batchSize = max(1, batchSize)
    }

    public struct Outcome: Sendable, Equatable {
        public var channel: String
        public var title: String?
        /// Readable posts in the export.
        public var posts = 0
        /// Posts written: new ones, and under `.replace` stored ones too.
        public var written = 0
        /// Posts already stored and left as they were (`.keepExisting`).
        public var kept = 0
        public var serviceMessages = 0
        /// Message blocks the parser could not read: posts missing from the index.
        public var unreadable = 0
        public var lowest: Int?
        public var highest: Int?
        /// Learned from the embed; `nil` offline.
        public var rawChannelID: Int64?
        /// The message whose embed confirmed the chat and the zone; `nil` offline.
        public var verifiedMessageID: Int?
    }

    public enum ImportError: Error, CustomStringConvertible, Equatable {
        case notAnExport(URL)
        case nothingReadable(unreadable: Int)
        case crawledChannel(String)
        case notFound(channel: String, tried: [Int])
        case notThisChat(channel: String, messageID: Int)
        case wrongZone(channel: String, messageID: Int, offset: TimeInterval)
        case identityConflict(String)
        case embedFailed(URL, status: Int)

        public var description: String {
            switch self {
            case .notAnExport(let url):
                return "\(url.path) holds no messages*.html — not a Telegram chat export"
            case .nothingReadable(let n):
                return "no message could be read (\(n) unreadable) — a different export format?"
            case .crawledChannel(let c):
                return "@\(c) is crawled from its web preview; an export of it would mix two sources"
            case .notFound(let c, let tried):
                return "none of messages \(tried) of the export exists at t.me/\(c) — not a public chat "
                     + "by that name, or they were deleted; pass --no-verify to import unchecked"
            case .notThisChat(let c, let id):
                return "t.me/\(c)/\(id) says something else than the export's message \(id) — "
                     + "this export is not @\(c)"
            case .wrongZone(let c, let id, let offset):
                let hours = offset / 3600
                return "the export's message \(id) is \(String(format: "%+g", hours)) h off t.me/\(c)/\(id): "
                     + "its dates were written in another zone — pass the zone of the Mac that exported it"
            case .identityConflict(let why):
                return why
            case .embedFailed(let url, let status):
                return "\(url.absoluteString) answered \(status)"
            }
        }
    }

    /// How many of the newest messages with text to try, when the newest have been deleted since.
    static let candidates = 3

    public func run(export directory: URL, channel name: String, timeZone: TimeZone,
                    policy: Store.WritePolicy = .keepExisting) async throws -> Outcome {
        let channel = name.lowercased()

        let files = try ChatExportParser.pageFiles(in: directory)
        guard let first = files.first else { throw ImportError.notAnExport(directory) }
        let written = (try? FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate]) as? Date
        let export = try ChatExportParser.parse(
            pages: try files.map { try String(contentsOf: $0, encoding: .utf8) },
            channel: channel, timeZone: timeZone, observedAt: written ?? Date())
        guard !export.posts.isEmpty else { throw ImportError.nothingReadable(unreadable: export.unreadable) }

        let known = try store.identity(forChannel: channel)
        if known?.reachability == .webPreview { throw ImportError.crawledChannel(channel) }

        var outcome = Outcome(channel: channel, title: export.title, posts: export.posts.count,
                              serviceMessages: export.serviceMessages, unreadable: export.unreadable)
        if let fetcher {
            let verified = try await verify(export.posts, channel: channel, fetcher: fetcher)
            outcome.verifiedMessageID = verified.messageID
            outcome.rawChannelID = verified.rawChannelID
        }
        if let id = outcome.rawChannelID {
            if let known, known.rawChannelID != 0, known.rawChannelID != id {
                throw ImportError.identityConflict(
                    "@\(channel) is stored as chat \(known.rawChannelID), but t.me says this export is chat \(id)")
            }
            let others = try store.channels(withRawChannelID: id).filter { $0 != channel }
            if !others.isEmpty {
                throw ImportError.identityConflict(
                    "chat \(id) is already stored as @\(others.joined(separator: ", @")) — renamed? "
                  + "Until S7 one chat can have only one row")
            }
        }

        try store.ensureChannel(username: channel, reachability: .group)
        if let id = outcome.rawChannelID {
            try store.updateIdentity(channel: channel, rawChannelID: id, reachability: .group)
        }
        let stored = try store.storedMessageIDs(forChannel: channel)
        var state = try store.crawlState(forChannel: channel)
        for start in stride(from: 0, to: export.posts.count, by: batchSize) {
            let batch = Array(export.posts[start..<min(start + batchSize, export.posts.count)])
            let ids = batch.map(\.id.messageID)
            state.lowest = min(state.lowest ?? .max, ids.min()!)
            state.highest = max(state.highest ?? .min, ids.max()!)
            try store.commitPage(batch, channel: channel, lowest: state.lowest, highest: state.highest,
                                 backfillComplete: false, policy: policy)
        }
        outcome.lowest = state.lowest
        outcome.highest = state.highest
        outcome.kept = policy == .keepExisting ? export.posts.filter { stored.contains($0.id.messageID) }.count : 0
        outcome.written = export.posts.count - outcome.kept
        return outcome
    }

    /// Confirms the export against `t.me`, newest message with text first. A message deleted since
    /// the export was taken is skipped; a failed request is not — it is an error, not an answer.
    func verify(_ posts: [Post], channel: String,
                fetcher: PageFetcher) async throws -> (messageID: Int, rawChannelID: Int64?) {
        let newest = posts.reversed().filter { !$0.text.isEmpty }.prefix(Self.candidates)
        for post in newest {
            let url = MessageEmbed.url(chat: channel, messageID: post.id.messageID)
            let page = try await fetcher.fetch(url)
            guard (200..<300).contains(page.statusCode) else {
                throw ImportError.embedFailed(url, status: page.statusCode)
            }
            guard let online = try MessageEmbed.post(html: page.body),
                  online.id == post.id else { continue }
            guard Self.sameText(online.text, post.text) else {
                throw ImportError.notThisChat(channel: channel, messageID: post.id.messageID)
            }
            let offset = post.date.timeIntervalSince(online.date)
            guard offset == 0 else {
                throw ImportError.wrongZone(channel: channel, messageID: post.id.messageID, offset: offset)
            }
            return (post.id.messageID, try MessageEmbed.rawChannelID(html: page.body))
        }
        throw ImportError.notFound(channel: channel, tried: newest.map(\.id.messageID))
    }

    /// The same message, rendered twice: by the exporting client and by `t.me`. Whitespace, and
    /// what each renders around a link or an emoji, may differ; the words may not.
    static func sameText(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [Substring] {
            s.lowercased().split { !$0.isLetter && !$0.isNumber }
        }
        let wa = words(a), wb = words(b)
        if wa == wb { return true }
        let sa = Set(wa), sb = Set(wb)
        guard !sa.isEmpty, !sb.isEmpty else { return false }
        return Double(sa.intersection(sb).count) / Double(max(sa.count, sb.count)) >= 0.9
    }
}
