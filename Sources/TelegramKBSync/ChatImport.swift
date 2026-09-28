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
/// 1. **Parse.** Nothing is written from an export with no readable post, or from one with a
///    hole in its page sequence — the exporter numbers pages contiguously, so a missing
///    `messagesN.html` is a lost file, not a page it skipped.
/// 2. **Never mix sources.** A username the store crawls from the web is a channel, not this
///    group, and the two sources disagree on albums.
/// 3. **Verify against one embed**, when a fetcher is given: the newest message with text is fetched
///    from `t.me/<chat>/<id>?embed=1`. Different words mean the export is not this chat; a
///    different moment means the export's zone is wrong — its dates carry no offset. With no
///    text-bearing message at all (a media-only group) the check falls back to id, date and
///    `data-peer`, which a media embed still carries. The embed also names the chat's bare id,
///    so the import learns `rawChannelID`. A page that verifies
///    but names no chat is a format change, not an offline import — it throws, because the
///    identity checks below would otherwise be skipped while "verified" is recorded.
/// 4. **One chat, one row — and one writer at a time.** The channel's lease is taken before the
///    embed is fetched and held until the last batch commits, so two `tgkb import` processes
///    cannot interleave under one username (TD-21). The identity checks and the write then share
///    `claimChannelIdentity`'s single transaction, so no claimant can pass them against state a
///    rival has already replaced (PR #3, review round 1).
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
        /// The page verified the message but carries no readable `data-peer`.
        case malformedEmbed(URL)

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
            case .malformedEmbed(let url):
                return "\(url.absoluteString) verified the message but names no chat — the "
                     + "embed's data-peer is missing or changed; pass --no-verify to import unchecked"
            }
        }
    }

    /// How many of the newest messages with text to try, when the newest have been deleted since.
    static let candidates = 3

    public func run(export directory: URL, channel name: String, timeZone: TimeZone,
                    policy: Store.WritePolicy = .keepExisting) async throws -> Outcome {
        let channel = name.lowercased()
        // Before it reaches `MessageEmbed.url`: a delimiter would fetch a different page than
        // the name under which the posts are stored (PR #3, review round 2).
        guard Channel.isUsername(channel) else { throw Channel.InvalidUsername(name: channel) }

        let files = try ChatExportParser.pageFiles(in: directory)
        guard !files.isEmpty else { throw ImportError.notAnExport(directory) }
        let export = try ChatExportParser.parse(
            pages: try files.map { try String(contentsOf: $0, encoding: .utf8) },
            channel: channel, timeZone: timeZone)
        guard !export.posts.isEmpty else { throw ImportError.nothingReadable(unreadable: export.unreadable) }

        let known = try store.identity(forChannel: channel)
        if known?.reachability == .webPreview { throw ImportError.crawledChannel(channel) }

        // Held from here to the last batch: a second tgkb writing this channel fails fast
        // instead of interleaving its checks and rows with ours.
        try store.acquireChannelLease(for: channel)
        defer { try? store.releaseChannelLease(for: channel) }

        var outcome = Outcome(channel: channel, title: export.title, posts: export.posts.count,
                              serviceMessages: export.serviceMessages, unreadable: export.unreadable)
        if let fetcher {
            let verified = try await verify(export.posts, channel: channel, timeZone: timeZone,
                                            fetcher: fetcher)
            outcome.verifiedMessageID = verified.messageID
            outcome.rawChannelID = verified.rawChannelID
        }
        do {
            try store.claimChannelIdentity(username: channel, rawChannelID: outcome.rawChannelID,
                                           reachability: .group)
        } catch Store.StoreError.channelCrawled(let c) {
            throw ImportError.crawledChannel(c)
        } catch Store.StoreError.channelIDConflict(let why) {
            throw ImportError.identityConflict(why)
        }

        let stored = try store.storedMessageIDs(forChannel: channel)
        var state = try store.crawlState(forChannel: channel)
        for start in stride(from: 0, to: export.posts.count, by: batchSize) {
            let batch = Array(export.posts[start..<min(start + batchSize, export.posts.count)])
            let ids = batch.map(\.id.messageID)
            state.lowest = min(state.lowest ?? .max, ids.min()!)
            state.highest = max(state.highest ?? .min, ids.max()!)
            try store.commitPage(batch, channel: channel, lowest: state.lowest, highest: state.highest,
                                 backfillComplete: false, policy: policy,
                                 rawChannelID: outcome.rawChannelID)
        }
        outcome.lowest = state.lowest
        outcome.highest = state.highest
        outcome.kept = policy == .keepExisting ? export.posts.filter { stored.contains($0.id.messageID) }.count : 0
        outcome.written = export.posts.count - outcome.kept
        return outcome
    }

    /// Confirms the export against `t.me`. A message deleted since the export was taken is
    /// skipped; a failed request is not — it is an error, not an answer.
    ///
    /// Text-bearing candidates come first because `sameText` is the strong check; media-only
    /// posts follow with a budget of their own, verifying on **id + date to the second +
    /// `data-peer`** (a media message's embed carries all three; verified on `@beautifulpictures`,
    /// 2026-09-24) — so newest text posts deleted since the export cannot spend the media posts'
    /// chances (PR #3, review rounds 2 and 4). Weaker evidence than a text match, but a foreign
    /// chat hosting the same id at the same second under the same peer is not a plausible
    /// collision.
    ///
    /// One verified instant pins the zone only AT that instant: a wrong zone can share the offset
    /// there and diverge elsewhere in the export's range — a DST transition the claimed zone
    /// lacks, or keeps on different dates — leaving older posts silently misdated. So probes then
    /// sample the rest of the range: one post per distinct offset the claimed zone assigns it,
    /// plus the oldest and midpoint posts (round 4). The residual: a wrong zone whose divergence
    /// windows contain no probed post still verifies — the check bounds the risk, not closes it.
    func verify(_ posts: [Post], channel: String, timeZone: TimeZone,
                fetcher: PageFetcher) async throws -> (messageID: Int, rawChannelID: Int64) {
        let newest = posts.reversed()
        let candidates = newest.filter { !$0.text.isEmpty }.prefix(Self.candidates)
                       + newest.filter { $0.text.isEmpty }.prefix(Self.candidates)
        var verified: (post: Post, rawID: Int64)?
        for post in candidates {
            if let rawID = try await probe(post, channel: channel, fetcher: fetcher) {
                verified = (post, rawID)
                break
            }
        }
        guard let verified else {
            throw ImportError.notFound(channel: channel, tried: candidates.map(\.id.messageID))
        }

        var probed: Set<Int> = [verified.post.id.messageID]
        var probes: [Post] = []
        var seenOffsets: Set<Int> = [timeZone.secondsFromGMT(for: verified.post.date)]
        for post in posts where seenOffsets.insert(timeZone.secondsFromGMT(for: post.date)).inserted {
            probes.append(post); probed.insert(post.id.messageID)
        }
        for post in [posts[0], posts[posts.count / 2]] where probed.insert(post.id.messageID).inserted {
            probes.append(post)
        }
        for post in probes {
            // A probe deleted from t.me cannot date-check its regime — skipped, like any
            // deletion; a live one that disagrees fails the import like any verified post.
            _ = try await probe(post, channel: channel, fetcher: fetcher)
        }
        return (verified.post.id.messageID, verified.rawID)
    }

    /// Fetches one candidate's embed and checks it against the export's record. `nil` means the
    /// message is gone from `t.me` — skipped, not an error; a live embed that disagrees throws.
    /// Returns the page's `data-peer` bare id.
    func probe(_ post: Post, channel: String, fetcher: PageFetcher) async throws -> Int64? {
        let url = MessageEmbed.url(chat: channel, messageID: post.id.messageID)
        let page = try await fetcher.fetch(url)
        guard (200..<300).contains(page.statusCode) else {
            throw ImportError.embedFailed(url, status: page.statusCode)
        }
        guard let online = try MessageEmbed.post(html: page.body),
              online.id == post.id else { return nil }
        // An embed without a text div — a media-only message — has no words to compare, and
        // comparing would put the file name the parser recorded for search against nothing.
        if !online.text.isEmpty {
            guard Self.sameText(online.text, post.text) else {
                throw ImportError.notThisChat(channel: channel, messageID: post.id.messageID)
            }
        }
        let offset = post.date.timeIntervalSince(online.date)
        guard offset == 0 else {
            throw ImportError.wrongZone(channel: channel, messageID: post.id.messageID, offset: offset)
        }
        // A verified page that names no chat cannot feed the identity checks — returning nil
        // here once let a marked-verified import skip them and store identity 0 (PR #3).
        guard let rawID = try MessageEmbed.rawChannelID(html: page.body) else {
            throw ImportError.malformedEmbed(url)
        }
        return rawID
    }

    /// The same message, rendered twice: by the exporting client and by `t.me`. Whitespace, and
    /// what each renders around a link or an emoji, may differ; the words may not — and neither
    /// may their ORDER or repetition. The earlier Set-based overlap accepted "Bob paid Alice" for
    /// "Alice paid Bob" (PR #3, review round 1); the diff below keeps order and counts repeats.
    ///
    /// Whether the 0.9 tolerance is needed at all is UNVERIFIED — on the reference export every
    /// checked message matched token-for-token. It stays for a message edited between the export
    /// and the import; if a real divergence ever asks for more, name it here.
    static func sameText(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [Substring] {
            s.lowercased().split { !$0.isLetter && !$0.isNumber }
        }
        let wa = words(a), wb = words(b)
        if wa == wb { return true }
        let common = wa.count - wb.difference(from: wa).removals.count
        return Double(common) / Double(max(wa.count, wb.count)) >= 0.9
    }
}
