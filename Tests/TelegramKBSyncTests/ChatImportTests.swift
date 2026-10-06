import Foundation
import Testing
import TelegramKBIngest
import TelegramKBModel
import TelegramKBStore
@testable import TelegramKBSync

/// A chat export into a real store, verified against a stub `t.me`.
///
/// The parser is tested on its own; these pin the SEQUENCE — what is refused before anything is
/// written, what one embed proves, and what an import leaves behind in the crawl state.
struct ChatImportTests {

    typealias Stub = SyncTests.StubFetcher
    static let moscow = TimeZone(identifier: "Europe/Moscow")!
    static let chatID: Int64 = 1_234_567_890

    struct Message {
        var id: Int
        var title: String          // the export's date title, in the exporting Mac's zone
        var text: String
        var sender: String? = "Alice Example"
        /// A photo with no caption: media markup instead of a `text` div.
        var media = false
        /// The export labels an edited message's time `edited HH:MM`; its title keeps the send time.
        var edited = false
    }

    static let messages = [
        Message(id: 10, title: "3 April 2023, 12:00:00", text: "Первая строка про анализ"),
        Message(id: 11, title: "3 April 2023, 12:10:00", text: "Лог сборки: make failed"),
        Message(id: 12, title: "3 April 2023, 12:34:07", text: "Два снимка проверены разными версиями анализатора"),
    ]

    /// One export page in the markup a real export uses.
    static func page(_ messages: [Message]) -> String {
        let blocks = messages.map { m in
            """
            <div class="message default clearfix" id="message\(m.id)">
            <div class="body">
            <div class="pull_right date details" title="\(m.title)">\(m.edited ? "edited 00:00" : "00:00")</div>
            \(m.sender.map { "<div class=\"from_name\">\($0)</div>" } ?? "")
            \(m.media ? "<div class=\"media_wrap\"><a class=\"photo_wrap clearfix pull_left\"></a></div>"
                      : "<div class=\"text\">\(m.text)</div>")
            </div>
            </div>
            """
        }
        return """
            <html><body><div class="page_wrap">
            <div class="page_header chat_header"><div class="content bubble"><div class="body">
            <div class="name bold">Test Group</div></div></div></div>
            <div class="page_body chat_page"><div class="history">
            <div class="message service" id="message2"><div class="body details">Alice joined the group</div></div>
            \(blocks.joined(separator: "\n"))
            </div></div></div></body></html>
            """
    }

    static func exportDirectory(_ messages: [Message] = messages) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try page(messages).write(to: dir.appendingPathComponent("messages.html"), atomically: true, encoding: .utf8)
        return dir
    }

    /// `t.me/<chat>/<id>?embed=1` as Telegram renders a public group's message.
    static func embed(_ chat: String, _ id: Int, text: String, utc: String,
                      peer: Int64? = chatID) -> String {
        let dataPeer = peer.map { " data-peer=\"c\($0)_-1111111111111111111\"" } ?? ""
        return """
        <html><body>
        <div class="tgme_widget_message js-widget_message" data-post="\(chat)/\(id)"\(dataPeer)>
        <div class="tgme_widget_message_bubble">
        <div class="tgme_widget_message_text js-message_text" dir="auto">\(text)</div>
        <span class="tgme_widget_message_meta"><a class="tgme_widget_message_date" href="https://t.me/\(chat)/\(id)"><time datetime="\(utc)" class="time">12:34</time></a></span>
        </div></div></body></html>
        """
    }

    /// A media message's embed: no `js-message_text`, but `<time>` and `data-peer` still present —
    /// checked against `t.me/beautifulpictures/3?embed=1`, 2026-09-24.
    static func embedMedia(_ chat: String, _ id: Int, utc: String, peer: Int64? = chatID) -> String {
        let dataPeer = peer.map { " data-peer=\"c\($0)_-1111111111111111111\"" } ?? ""
        return """
        <html><body>
        <div class="tgme_widget_message js-widget_message" data-post="\(chat)/\(id)"\(dataPeer)>
        <div class="tgme_widget_message_bubble">
        <a class="tgme_widget_message_photo" href="https://t.me/\(chat)/\(id)"></a>
        <span class="tgme_widget_message_meta"><a class="tgme_widget_message_date" href="https://t.me/\(chat)/\(id)"><time datetime="\(utc)" class="time">12:34</time></a></span>
        </div></div></body></html>
        """
    }

    static func route(_ id: Int, _ body: String, status: Int = 200) -> (String, FetchResult) {
        let url = "https://t.me/testgroup/\(id)?embed=1"
        return (url, FetchResult(body: body, statusCode: status, finalURL: URL(string: url)!))
    }

    /// The newest message embedded as Telegram has it: same words, 12:34:07 Moscow is 09:34:07 UTC.
    static func telegram() -> Stub {
        Stub(Dictionary(uniqueKeysWithValues: [
            route(12, embed("testgroup", 12, text: messages[2].text, utc: "2023-04-03T09:34:07+00:00")),
        ]))
    }

    static func store() throws -> Store { try SyncTests.store() }

    @Test("an export lands as a group: verified, its id learned, its posts searchable")
    func importsAGroup() async throws {
        let store = try Self.store()
        let outcome = try await ChatImport(store: store, fetcher: Self.telegram())
            .run(export: try Self.exportDirectory(), channel: "TestGroup", timeZone: Self.moscow)

        #expect(outcome.channel == "testgroup", "usernames reach the store lower-cased")
        #expect(outcome.posts == 3 && outcome.written == 3 && outcome.kept == 0)
        #expect(outcome.serviceMessages == 1)
        #expect(outcome.verifiedMessageID == 12)
        #expect(outcome.rawChannelID == Self.chatID)
        let identity = try store.identity(forChannel: "testgroup")
        #expect(identity?.rawChannelID == Self.chatID && identity?.reachability == .group)
        #expect(try store.search("снимка", mode: .both, limit: 10).hits.map(\.id.messageID) == [12])
    }

    /// TD-22: an import is a write session — thousands of posts in batches — and ends like a sync,
    /// by giving the WAL's space back.
    @Test("a finished import hands the WAL's space back")
    func importLeavesWALTruncated() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgkb-import-\(UUID().uuidString).sqlite").path
        let store = try Store.openForWriting(at: path)
        let outcome = try await ChatImport(store: store, fetcher: nil)
            .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)

        #expect(outcome.written == 3 && !outcome.walCleanupFailed)
        let wal = (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? Int) ?? 0
        #expect(wal == 0, "the file stays (PERSIST_WAL); its contents are given back")
    }

    @Test("an import never claims a complete backfill, and widens the id bounds of the one before")
    func crawlState() async throws {
        let store = try Self.store()
        let importer = ChatImport(store: store, fetcher: nil)
        _ = try await importer.run(export: try Self.exportDirectory(Array(Self.messages.prefix(2))),
                                   channel: "testgroup", timeZone: Self.moscow)
        _ = try await importer.run(export: try Self.exportDirectory([Self.messages[1], Self.messages[2]]),
                                   channel: "testgroup", timeZone: Self.moscow)
        let state = try store.crawlState(forChannel: "testgroup")
        #expect(state.lowest == 10 && state.highest == 12)
        #expect(!state.backfillComplete)
    }

    @Test("keepExisting leaves a stored post as it was; replace refreshes it")
    func writePolicy() async throws {
        let store = try Self.store()
        let importer = ChatImport(store: store, fetcher: nil, batchSize: 1)
        _ = try await importer.run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)

        var edited = Self.messages
        edited[0].text = "Исправленная строка"
        let kept = try await importer.run(export: try Self.exportDirectory(edited), channel: "testgroup",
                                          timeZone: Self.moscow)
        #expect(kept.kept == 3 && kept.written == 0)
        #expect(try store.search("исправленная", mode: .both, limit: 10).hits.isEmpty)

        let replaced = try await importer.run(export: try Self.exportDirectory(edited), channel: "testgroup",
                                              timeZone: Self.moscow, policy: .replace)
        #expect(replaced.written == 3 && replaced.kept == 0)
        #expect(try store.search("исправленная", mode: .both, limit: 10).hits.map(\.id.messageID) == [10])
    }

    @Test("a message that reads differently on t.me stops the import before anything is written")
    func notThisChat() async throws {
        let store = try Self.store()
        let other = Stub(Dictionary(uniqueKeysWithValues: [
            Self.route(12, Self.embed("testgroup", 12, text: "Совсем другое сообщение из другого чата",
                                      utc: "2023-04-03T09:34:07+00:00")),
        ]))
        await #expect(throws: ChatImport.ImportError.notThisChat(channel: "testgroup", messageID: 12)) {
            try await ChatImport(store: store, fetcher: other)
                .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        }
        #expect(try store.identity(forChannel: "testgroup") == nil)
    }

    /// The export's dates carry no offset. Read in the wrong zone, they are wrong by the difference
    /// — silently, for every post — unless one embed says when the message really was.
    @Test("dates written in another zone stop the import, naming the offset")
    func wrongZone() async throws {
        let store = try Self.store()
        await #expect(throws: ChatImport.ImportError.wrongZone(channel: "testgroup", messageID: 12, offset: 3 * 3600)) {
            try await ChatImport(store: store, fetcher: Self.telegram())
                .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: .gmt)
        }
        #expect(try store.storedMessageIDs(forChannel: "testgroup").isEmpty)
    }

    @Test("a username crawled from the web is not a group, and is refused")
    func crawledChannel() async throws {
        let store = try Self.store()
        try store.upsert(channel: Channel(username: "testgroup", rawChannelID: 0,
                                        reachability: .webPreview))
        await #expect(throws: ChatImport.ImportError.crawledChannel("testgroup")) {
            try await ChatImport(store: store, fetcher: nil)
                .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        }
        #expect(try store.storedMessageIDs(forChannel: "testgroup").isEmpty)
    }

    @Test("the chat's id already stored under another username is refused")
    func idUnderAnotherName() async throws {
        let store = try Self.store()
        try store.upsert(channel: Channel(username: "oldname", rawChannelID: Self.chatID, reachability: .group))
        await #expect(throws: ChatImport.ImportError.self) {
            try await ChatImport(store: store, fetcher: Self.telegram())
                .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        }
        #expect(try store.identity(forChannel: "testgroup") == nil)
    }

    @Test("a username stored as another chat is refused")
    func usernameIsAnotherChat() async throws {
        let store = try Self.store()
        try store.upsert(channel: Channel(username: "testgroup", rawChannelID: 42,
                                        reachability: .group))
        await #expect(throws: ChatImport.ImportError.self) {
            try await ChatImport(store: store, fetcher: Self.telegram())
                .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        }
        #expect(try store.identity(forChannel: "testgroup")?.rawChannelID == 42)
        #expect(try store.storedMessageIDs(forChannel: "testgroup").isEmpty)
    }

    @Test("a newest message deleted since the export falls back to the one before")
    func deletedNewest() async throws {
        let store = try Self.store()
        let telegram = Stub(Dictionary(uniqueKeysWithValues: [
            // No route for 12: the stub answers an empty page, as t.me does for a deleted message.
            Self.route(11, Self.embed("testgroup", 11, text: Self.messages[1].text, utc: "2023-04-03T09:10:00+00:00")),
        ]))
        let outcome = try await ChatImport(store: store, fetcher: telegram)
            .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        #expect(outcome.verifiedMessageID == 11)
    }

    @Test("a failed request is an error, never read as a missing message")
    func failedRequest() async throws {
        let store = try Self.store()
        let broken = Stub(Dictionary(uniqueKeysWithValues: [Self.route(12, "<html>error</html>", status: 500)]))
        // Exactly this error: read as an empty page, the 500 would fall through to `notFound` — also an
        // ImportError, so a looser expectation would pass with the guard deleted.
        await #expect(throws: ChatImport.ImportError.embedFailed(URL(string: "https://t.me/testgroup/12?embed=1")!, status: 500)) {
            try await ChatImport(store: store, fetcher: broken)
                .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        }
        #expect(try store.identity(forChannel: "testgroup") == nil)
    }

    @Test("an export no message of which exists on t.me is refused, naming what was tried")
    func notFound() async throws {
        let store = try Self.store()
        await #expect(throws: ChatImport.ImportError.notFound(channel: "testgroup", tried: [12, 11, 10])) {
            try await ChatImport(store: store, fetcher: Stub([:]))
                .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        }
    }

    @Test("a verified page that names no chat stops the import — the format changed, not the check")
    func embedWithoutPeer() async throws {
        let store = try Self.store()
        let peerless = Stub(Dictionary(uniqueKeysWithValues: [
            Self.route(12, Self.embed("testgroup", 12, text: Self.messages[2].text,
                                      utc: "2023-04-03T09:34:07+00:00", peer: nil)),
        ]))
        // Read as a missing id, the import would skip the uniqueness checks and still record
        // itself verified — a nil id is only honest when nothing was fetched at all.
        await #expect(throws: ChatImport.ImportError.malformedEmbed(
                        URL(string: "https://t.me/testgroup/12?embed=1")!)) {
            try await ChatImport(store: store, fetcher: peerless)
                .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        }
        #expect(try store.identity(forChannel: "testgroup") == nil)
    }

    /// � A zone can share the claimed offset at the newest message and diverge before it —
    /// claimed `UTC-5` vs real New York is right all winter and an hour off all summer. One
    /// verified instant then misdates every post in the diverging span, silently, so probes
    /// must reach beyond the candidate that passed (PR #3, review round 4).
    @Test("a zone right at the newest message but wrong earlier is refused")
    func seasonalZoneIsCaught() async throws {
        let store = try Self.store()
        let fixedMinus5 = TimeZone(secondsFromGMT: -5 * 3600)!
        let msgs = [
            // July noon under the claimed -5 stores as 17:00Z; under New York it was 16:00Z.
            Message(id: 1, title: "15 July 2023, 12:00:00", text: "летний пост"),
            // January noon: -5 either way — the newest message verifies and hides the error.
            Message(id: 2, title: "15 January 2024, 12:00:00", text: "зимний пост"),
        ]
        let telegram = Stub(Dictionary(uniqueKeysWithValues: [
            Self.route(2, Self.embed("testgroup", 2, text: "зимний пост",
                                     utc: "2024-01-15T17:00:00+00:00")),
            Self.route(1, Self.embed("testgroup", 1, text: "летний пост",
                                     utc: "2023-07-15T16:00:00+00:00")),
        ]))
        await #expect(throws: ChatImport.ImportError.wrongZone(
                        channel: "testgroup", messageID: 1, offset: 3600)) {
            try await ChatImport(store: store, fetcher: telegram)
                .run(export: try Self.exportDirectory(msgs), channel: "testgroup",
                     timeZone: fixedMinus5)
        }
        #expect(try store.storedMessageIDs(forChannel: "testgroup").isEmpty)
    }

    /// 🟡 The candidate budget used to be one `prefix(3)` over newest-first posts: three text
    /// posts deleted since the export spent it all and the media posts behind them were never
    /// asked — a media-heavy export read as `notFound`. Text and media now budget separately
    /// (PR #3, review round 4).
    @Test("deleted text posts do not spend the media candidates' chances")
    func deletedTextPostsFallThroughToMedia() async throws {
        let store = try Self.store()
        let msgs = [
            Message(id: 7, title: "3 April 2023, 11:00:00", text: "", media: true),
            // All three text posts are gone from t.me: no routes, and the stub answers an
            // empty page — as it does for a deleted message.
            Message(id: 10, title: "3 April 2023, 12:00:00", text: "ушёл"),
            Message(id: 11, title: "3 April 2023, 12:10:00", text: "потом этот"),
            Message(id: 12, title: "3 April 2023, 12:34:07", text: "и этот тоже"),
        ]
        let telegram = Stub(Dictionary(uniqueKeysWithValues: [
            Self.route(7, Self.embedMedia("testgroup", 7, utc: "2023-04-03T08:00:00+00:00")),
        ]))
        let outcome = try await ChatImport(store: store, fetcher: telegram)
            .run(export: try Self.exportDirectory(msgs), channel: "testgroup", timeZone: Self.moscow)
        #expect(outcome.verifiedMessageID == 7)
    }

    /// �🟡 An export whose posts carry no text used to find zero candidates and throw `notFound`
    /// without ever asking t.me. A media-only group still verifies — on the post's id, its date
    /// to the second, and `data-peer`, all of which a media embed carries (PR #3, round 2).
    @Test("a media-only export verifies on id, date and the chat's bare id")
    func mediaOnlyExportVerifies() async throws {
        let store = try Self.store()
        let media = [Message(id: 12, title: "3 April 2023, 12:34:07", text: "", media: true)]
        let telegram = Stub(Dictionary(uniqueKeysWithValues: [
            Self.route(12, Self.embedMedia("testgroup", 12, utc: "2023-04-03T09:34:07+00:00")),
        ]))
        let outcome = try await ChatImport(store: store, fetcher: telegram)
            .run(export: try Self.exportDirectory(media), channel: "testgroup", timeZone: Self.moscow)
        #expect(outcome.verifiedMessageID == 12 && outcome.rawChannelID == Self.chatID)
        #expect(outcome.posts == 1 && outcome.written == 1)
    }

    /// 🟨 A name with a URL delimiter (`/`, `?`, a space) would fetch a different page than the
    /// name the posts are stored under — or crash `URL(string:)`. Refused before any fetch
    /// (PR #3, review round 2).
    @Test("a channel name that cannot be a t.me path segment is refused before anything runs")
    func invalidUsernameImportRefused() async throws {
        await #expect(throws: Channel.InvalidUsername(name: "bad/name")) {
            try await ChatImport(store: Self.store(), fetcher: Self.telegram())
                .run(export: URL(fileURLWithPath: "/nonexistent"), channel: "bad/name",
                     timeZone: Self.moscow)
        }
    }

    @Test("a second writer for the same channel is refused while the lease is held")
    func concurrentImportRefused() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgkb-import-\(UUID().uuidString).sqlite").path
        let holder = try Store.openForWriting(at: path)
        let store = try Store.openForWriting(at: path)
        try holder.acquireChannelLease(for: "testgroup")
        defer { try? holder.releaseChannelLease(for: "testgroup") }

        await #expect(throws: Store.StoreError.channelLeaseHeld(
                        channel: "testgroup", pid: ProcessInfo.processInfo.processIdentifier)) {
            try await ChatImport(store: store, fetcher: nil)
                .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        }
        #expect(try store.identity(forChannel: "testgroup") == nil)

        try holder.releaseChannelLease(for: "testgroup")
        let outcome = try await ChatImport(store: store, fetcher: nil)
            .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        #expect(outcome.written == 3)
    }

    /// 🔴 The import released its lease with `defer { try? … }`: a release that failed left the
    /// row behind and said nothing. An import whose batches landed now reports it…
    @Test("an import whose lease release fails completes, and says so")
    func importReportsFailedRelease() async throws {
        let store = try Self.store()
        try SyncTests.refuseLeaseRelease(in: store)
        let outcome = try await ChatImport(store: store, fetcher: nil)
            .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        #expect(outcome.written == 3 && !outcome.walCleanupFailed)
        #expect(outcome.leaseReleaseFailed, "the release error is reported, not swallowed")
    }

    /// …and one that was refused carries it alongside the refusal, which still leads.
    @Test("a refused import whose lease release fails carries both, the refusal first")
    func failedImportCarriesFailedRelease() async throws {
        let store = try Self.store()
        try SyncTests.refuseLeaseRelease(in: store)
        let other = Stub(Dictionary(uniqueKeysWithValues: [
            Self.route(12, Self.embed("testgroup", 12, text: "Совсем другое сообщение из другого чата",
                                      utc: "2023-04-03T09:34:07+00:00")),
        ]))
        let error = await #expect(throws: Store.CleanupAlsoFailed.self) {
            try await ChatImport(store: store, fetcher: other)
                .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        }
        #expect(error?.session as? ChatImport.ImportError
                == .notThisChat(channel: "testgroup", messageID: 12))
        #expect(error?.failures.map { $0.cleanup } == [.leaseRelease(channel: "testgroup")])
    }

    // MARK: - A verified import over an unverified history (TD-19)

    /// A verified import of `messages`, newest first, from a stub `t.me` that renders only the
    /// newest — enough to verify; the oldest and midpoint probes read as deleted and are skipped.
    func importVerified(_ messages: [Message], newestUTC: String, into store: Store,
                        policy: Store.WritePolicy = .keepExisting) async throws -> ChatImport.Outcome {
        let newest = try #require(messages.last)
        let telegram = Stub(Dictionary(uniqueKeysWithValues: [
            Self.route(newest.id, Self.embed("testgroup", newest.id, text: newest.text, utc: newestUTC)),
        ]))
        return try await ChatImport(store: store, fetcher: telegram)
            .run(export: try Self.exportDirectory(messages), channel: "testgroup", timeZone: Self.moscow,
                 policy: policy)
    }

    func importOffline(_ messages: [Message] = messages, into store: Store) async throws {
        _ = try await ChatImport(store: store, fetcher: nil)
            .run(export: try Self.exportDirectory(messages), channel: "testgroup", timeZone: Self.moscow)
    }

    /// Another chat's message at a stored id: what a username reassigned between two exports
    /// looks like from here.
    static let foreignNewest = Message(id: 13, title: "4 April 2023, 09:00:00", text: "Новое сообщение другого чата")
    static let foreignNewestUTC = "2023-04-04T06:00:00+00:00"

    /// 🔴 An `--no-verify` import leaves its row at id 0, which matched any claim: a verified
    /// import of ANOTHER chat under the same name set its id on the row and merged both
    /// histories. Message 11 here is edited, and still refused — an edit keeps the send time,
    /// so a date that differs is another message.
    @Test("an unverified history sent at other moments is refused, edited or not")
    func foreignHistoryDatedOtherwiseRefused() async throws {
        let store = try Self.store()
        try await importOffline(into: store)
        let other = [Message(id: 11, title: "3 April 2023, 13:10:00", text: Self.messages[1].text, edited: true),
                     Self.foreignNewest]
        await #expect(throws: ChatImport.ImportError.storedDateDiffers(
                        channel: "testgroup", messageID: 11, offset: 3600)) {
            try await importVerified(other, newestUTC: Self.foreignNewestUTC, into: store)
        }
        #expect(try store.identity(forChannel: "testgroup")?.rawChannelID == 0, "the row stays unverified")
        #expect(try store.storedMessageIDs(forChannel: "testgroup") == [10, 11, 12], "and holds one chat")
    }

    @Test("an unverified history whose words differ at the same moment is refused")
    func foreignHistoryWordedOtherwiseRefused() async throws {
        let store = try Self.store()
        try await importOffline(into: store)
        let other = [Message(id: 11, title: Self.messages[1].title, text: "Совсем другие слова другого чата"),
                     Self.foreignNewest]
        await #expect(throws: ChatImport.ImportError.storedTextDiffers(channel: "testgroup", messageID: 11)) {
            try await importVerified(other, newestUTC: Self.foreignNewestUTC, into: store)
        }
        #expect(try store.identity(forChannel: "testgroup")?.rawChannelID == 0)
        #expect(try store.storedMessageIDs(forChannel: "testgroup") == [10, 11, 12])
    }

    /// The normal path the check must not block: an offline import, then a newer export of the
    /// same chat, verified.
    @Test("a newer export of the same chat claims the history an offline import left")
    func sameChatClaimsItsUnverifiedHistory() async throws {
        let store = try Self.store()
        try await importOffline(Array(Self.messages.prefix(2)), into: store)
        let outcome = try await importVerified(Array(Self.messages.suffix(2)),
                                               newestUTC: "2023-04-03T09:34:07+00:00", into: store)
        #expect(outcome.verifiedMessageID == 12 && outcome.kept == 1 && outcome.written == 1)
        #expect(try store.identity(forChannel: "testgroup")?.rawChannelID == Self.chatID)
        #expect(try store.storedMessageIDs(forChannel: "testgroup") == [10, 11, 12])
    }

    /// An edited message's words changed on purpose, so a pair with an edited side neither
    /// confirms nor refutes — here the export's 12 was edited since, and 10 and 11 agree.
    @Test("an edited message is neutral evidence: its new words refuse nothing")
    func editedPostIsNeutralEvidence() async throws {
        let store = try Self.store()
        try await importOffline(into: store)
        var newer = Self.messages
        newer[2].text = "Два снимка проверены, вывод исправлен"
        newer[2].edited = true
        let outcome = try await importVerified(newer, newestUTC: "2023-04-03T09:34:07+00:00", into: store)
        #expect(outcome.rawChannelID == Self.chatID)
        #expect(try store.identity(forChannel: "testgroup")?.rawChannelID == Self.chatID)
    }

    /// Nothing in common, or only edited messages in common, shows nothing either way: refused,
    /// unless `--replace` says to claim the stored posts anyway.
    @Test("an unverified history nothing confirms is claimed only with --replace")
    func unconfirmedHistoryNeedsReplace() async throws {
        let store = try Self.store()
        try await importOffline(Array(Self.messages.prefix(1)), into: store)
        let disjoint = [Self.messages[2]]
        await #expect(throws: ChatImport.ImportError.storedHistoryUnconfirmed(channel: "testgroup")) {
            try await importVerified(disjoint, newestUTC: "2023-04-03T09:34:07+00:00", into: store)
        }
        var onlyEdited = [Self.messages[0], Self.messages[2]]
        onlyEdited[0].text = "Первая строка, исправленная"
        onlyEdited[0].edited = true
        await #expect(throws: ChatImport.ImportError.storedHistoryUnconfirmed(channel: "testgroup")) {
            try await importVerified(onlyEdited, newestUTC: "2023-04-03T09:34:07+00:00", into: store)
        }
        #expect(try store.identity(forChannel: "testgroup")?.rawChannelID == 0)

        let outcome = try await importVerified(disjoint, newestUTC: "2023-04-03T09:34:07+00:00",
                                               into: store, policy: .replace)
        #expect(outcome.rawChannelID == Self.chatID)
        #expect(try store.storedMessageIDs(forChannel: "testgroup") == [10, 12])
    }

    @Test("an unverified row with no posts is claimed without a comparison")
    func emptyUnverifiedRowIsClaimedFreely() async throws {
        let store = try Self.store()
        try store.upsert(channel: Channel(username: "testgroup", rawChannelID: 0, reachability: .group))
        let outcome = try await ChatImport(store: store, fetcher: Self.telegram())
            .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        #expect(outcome.rawChannelID == Self.chatID && outcome.written == 3)
    }

    @Test("offline, nothing is verified and no id is learned")
    func offline() async throws {
        let store = try Self.store()
        let outcome = try await ChatImport(store: store, fetcher: nil)
            .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        #expect(outcome.verifiedMessageID == nil && outcome.rawChannelID == nil)
        let identity = try store.identity(forChannel: "testgroup")
        #expect(identity?.rawChannelID == 0 && identity?.reachability == .group)
    }

    /// 🟡 Round-5 review: an offline import into a row classified `previewDisabled` (or
    /// `unresolvable`) used to keep that class — doctor then described a crawl that never ran
    /// instead of the imported group the posts make it. The claim corrects reachability even
    /// without a learned id, and leaves the stored id alone.
    @Test("an offline import reclassifies a preview-disabled row as the group it now is")
    func offlineImportReclassifies() async throws {
        let store = try Self.store()
        try store.upsert(channel: Channel(username: "testgroup", rawChannelID: 42,
                                        reachability: .previewDisabled))
        let outcome = try await ChatImport(store: store, fetcher: nil)
            .run(export: try Self.exportDirectory(), channel: "testgroup", timeZone: Self.moscow)
        #expect(outcome.written == 3)
        let identity = try store.identity(forChannel: "testgroup")
        #expect(identity?.reachability == .group, "imported posts make it a group")
        #expect(identity?.rawChannelID == 42, "a learned id is never overwritten by nil")
    }

    @Test("unreadable blocks are counted, and the rest still lands")
    func unreadableCounted() async throws {
        let store = try Self.store()
        var messages = Self.messages
        messages.append(Message(id: 13, title: "not a date", text: "unreadable"))
        let outcome = try await ChatImport(store: store, fetcher: nil)
            .run(export: try Self.exportDirectory(messages), channel: "testgroup", timeZone: Self.moscow)
        #expect(outcome.unreadable == 1 && outcome.posts == 3)
    }

    @Test("an export with nothing readable writes nothing")
    func nothingReadable() async throws {
        let store = try Self.store()
        let broken = Self.messages.map { Message(id: $0.id, title: "never", text: $0.text) }
        await #expect(throws: ChatImport.ImportError.nothingReadable(unreadable: 3)) {
            try await ChatImport(store: store, fetcher: nil)
                .run(export: try Self.exportDirectory(broken), channel: "testgroup", timeZone: Self.moscow)
        }
        #expect(try store.identity(forChannel: "testgroup") == nil)
    }

    @Test("a folder with no messages*.html is not an export")
    func notAnExport() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await #expect(throws: ChatImport.ImportError.notAnExport(dir)) {
            try await ChatImport(store: try Self.store(), fetcher: nil).run(export: dir, channel: "testgroup",
                                                                            timeZone: Self.moscow)
        }
    }

    @Test("the same words rendered twice compare equal; reordered or recounted ones do not")
    func sameText() {
        #expect(ChatImport.sameText("Первая  строка\nпро @someone", "Первая строка про @someone"))
        #expect(!ChatImport.sameText("Первая строка", "Совсем другое сообщение"))
        // A Set-based overlap passed both of these: order and repetition are now checked.
        #expect(!ChatImport.sameText("Alice paid Bob today", "Bob paid Alice today"))
        #expect(!ChatImport.sameText("a a b", "a b b"))
        // The bound: one different token in ten still compares equal, two do not.
        #expect(ChatImport.sameText("one two three four five six seven eight nine ten",
                                    "one two three four five six seven eight nine tenX"))
        #expect(!ChatImport.sameText("one two three four five six seven eight nine ten",
                                     "one two three four five six seven eight nineX tenX"))
    }
}
