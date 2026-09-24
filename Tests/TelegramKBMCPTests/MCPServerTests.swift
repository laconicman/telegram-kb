import Foundation
import MCP
import Testing
import TelegramKBModel
import TelegramKBStore
@testable import TelegramKBMCP

/// End-to-end: a real `Client` talks JSON-RPC to a real `Server` over
/// `InMemoryTransport.createConnectedPair()`, against a real seeded store.
struct MCPServerTests {

    static func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tgkb-mcp-\(UUID().uuidString).sqlite").path
    }

    /// Two posts: one linking the shortener, one plain text — enough for all three tools.
    static func seededStore() throws -> Store {
        let store = try Store.openForWriting(at: tempPath())
        try store.upsert(channel: Channel(username: "iosgr", rawChannelID: 1_492_664_793))
        try store.upsert(posts: [
            Post(id: .init(channelUsername: "iosgr", messageID: 1),
                 date: Date(timeIntervalSince1970: 1_700_000_001),
                 kind: .text, formatSource: .web, mediaCount: 1,
                 text: "Вёрстка в SwiftUI и немного про clck",
                 links: [LinkRef(urlRaw: "https://clck.ru/33ABCD")],
                 reactions: [Reaction(emoji: "👍", count: 5)]),
            Post(id: .init(channelUsername: "iosgr", messageID: 2),
                 date: Date(timeIntervalSince1970: 1_700_000_002),
                 kind: .text, formatSource: .web, mediaCount: 1,
                 text: "Совсем про другое — моки и сетевой слой"),
        ])
        return store
    }

    /// Server + client on the in-memory pair. The serve task is scoped to the test process —
    /// the transports die with the suite, which is all the teardown this needs.
    static func connected(_ store: Store) async throws -> (Client, Server) {
        let server = await TGKBServer.makeServer(store: store)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "test", version: "0")
        Task { try await server.start(transport: serverTransport) }
        _ = try await client.connect(transport: clientTransport)
        return (client, server)
    }

    /// `structuredContent` decoded back to the declared output type.
    static func decode<Output: Decodable>(_ result: CallTool.Result, as: Output.Type) throws
        -> Output {
        let structured = try #require(result.structuredContent)
        let data = try JSONEncoder().encode(structured)
        return try JSONDecoder().decode(Output.self, from: data)
    }

    /// -32602 specifically — not just "some error surfaced". A misspelled param reported as
    /// an internal error would pass a looser assertion while telling the client the wrong thing.
    static func expectInvalidParams(
        _ comment: String,
        _ body: () async throws -> CallTool.Result
    ) async {
        do {
            _ = try await body()
            Issue.record("\(comment): expected invalidParams, got a result")
        } catch let e as MCPError {
            guard case .invalidParams = e else {
                Issue.record("\(comment): expected -32602, got \(e)")
                return
            }
        } catch {
            Issue.record("\(comment): expected MCPError, got \(error)")
        }
    }

    @Test("tools/list serves the three tools with all four annotations set")
    func listsTools() async throws {
        let (client, _) = try await Self.connected(try Self.seededStore())
        let (tools, _) = try await client.listTools()
        #expect(tools.map(\.name).sorted() == ["find_links", "get_post", "search_posts"])
        for tool in tools {
            #expect(tool.annotations.readOnlyHint == true)
            #expect(tool.annotations.destructiveHint == false)
            #expect(tool.annotations.idempotentHint == true)
            #expect(tool.annotations.openWorldHint == false,
                    "the SDK default is true — omitting it would misdescribe the archive")
        }
    }

    @Test("search_posts returns compact records with permalinks and an honest total")
    func searchPosts() async throws {
        let (client, _) = try await Self.connected(try Self.seededStore())
        let result = try await client.callTool(
            name: "search_posts", arguments: ["query": "вёрстка"]).value
        #expect(result.isError != true)
        let out = try Self.decode(result, as: SearchPostsOutput.self)
        #expect(out.total == 1)
        #expect(out.posts.count == 1)
        let hit = out.posts[0]
        #expect(hit.post == "@iosgr/1", "the literal get_post accepts")
        #expect(hit.link == "https://t.me/iosgr/1", "every record must be citable")
        #expect(hit.channel == "iosgr")
        #expect(hit.reactions == 5)
        #expect(hit.snippet.contains("Вёрстка"))
        #expect(out.next_cursor == nil)
        #expect(out.index_moved_since_cursor == false)
        // The text channel mirrors the structured one for clients that render only text.
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("expected a text content block"); return
        }
        #expect(text.contains("https://t.me/iosgr/1"))
    }

    @Test("search_posts pages through an opaque cursor")
    func searchPostsPages() async throws {
        let (client, _) = try await Self.connected(try Self.seededStore())
        let page1 = try await client.callTool(
            name: "search_posts", arguments: ["query": "про", "limit": .int(1)]).value
        let out1 = try Self.decode(page1, as: SearchPostsOutput.self)
        #expect(out1.posts.count == 1 && out1.total > 1)
        let cursor = try #require(out1.next_cursor)
        let page2 = try await client.callTool(
            name: "search_posts", arguments: ["query": "про", "limit": .int(1),
                                              "cursor": .string(cursor)]).value
        let out2 = try Self.decode(page2, as: SearchPostsOutput.self)
        #expect(out2.posts.count == 1)
        #expect(out2.posts[0].post != out1.posts[0].post, "the second page must not repeat")
    }

    @Test("search_posts with a foreign cursor is an invalidParams error, not a wrong page")
    func foreignCursorRejected() async throws {
        let (client, _) = try await Self.connected(try Self.seededStore())
        let page1 = try await client.callTool(
            name: "search_posts", arguments: ["query": "про", "limit": .int(1)]).value
        let cursor = try #require(try Self.decode(page1, as: SearchPostsOutput.self).next_cursor)
        // A cursor minted by "и" must not page through "вёрстка".
        await Self.expectInvalidParams("foreign cursor") {
            try await client.callTool(
                name: "search_posts", arguments: ["query": "вёрстка", "cursor": .string(cursor)]).value
        }
    }

    @Test("malformed calls are invalidParams — missing arg, wrong type, unknown key, bad kind")
    func invalidArgsRejected() async throws {
        let (client, _) = try await Self.connected(try Self.seededStore())
        await Self.expectInvalidParams("missing query") {
            try await client.callTool(name: "search_posts", arguments: [:]).value
        }
        await Self.expectInvalidParams("query of wrong type") {
            try await client.callTool(
                name: "search_posts", arguments: ["query": .int(3)]).value
        }
        await Self.expectInvalidParams("misspelled key") {
            try await client.callTool(
                name: "search_posts", arguments: ["query": "x", "chanel": "iosgr"]).value
        }
        await Self.expectInvalidParams("undeclared kind") {
            try await client.callTool(
                name: "search_posts", arguments: ["query": "x", "kind": "tesseract"]).value
        }
    }

    @Test("search_posts honours the @channel filter")
    func searchFiltersChannel() async throws {
        let (client, _) = try await Self.connected(try Self.seededStore())
        let result = try await client.callTool(
            name: "search_posts",
            arguments: ["query": "вёрстка", "channel": "@nobody"]).value
        let out = try Self.decode(result, as: SearchPostsOutput.self)
        #expect(out.posts.isEmpty && out.total == 0)
    }

    @Test("find_links returns the canonical key with the resolved target beside it")
    func findLinks() async throws {
        let store = try Self.seededStore()
        let canonical = try #require(URLCanonicaliser.canonicalise("https://clck.ru/33ABCD"))
        try store.upsert(resolutions: [URLResolution(
            urlCanonical: canonical, resolvedCanonical: "https://habr.com/ru/post/1",
            httpStatus: "200", hops: 1, resolvedAt: Date())])
        let (client, _) = try await Self.connected(store)
        let result = try await client.callTool(
            name: "find_links", arguments: ["url": "https://habr.com/ru/post/1"]).value
        #expect(result.isError != true)
        let out = try Self.decode(result, as: FindLinksOutput.self)
        #expect(out.total == 1)
        let link = out.links[0]
        #expect(link.post == "@iosgr/1")
        #expect(link.url_raw == "https://clck.ru/33ABCD")
        #expect(link.url_canonical == canonical)
        #expect(link.resolved_url == "https://habr.com/ru/post/1")
    }

    /// 🔴 `find_links` clamped `limit` to 100 and had no cursor, so the 101st match was unreachable
    /// while `total` advertised it.
    @Test("find_links pages through an opaque cursor")
    func findLinksPages() async throws {
        let store = try Self.seededStore()
        try store.upsert(posts: [
            Post(id: .init(channelUsername: "iosgr", messageID: 3),
                 date: Date(timeIntervalSince1970: 1_700_000_003),
                 kind: .text, formatSource: .web, mediaCount: 1, text: "тот же сократитель",
                 links: [LinkRef(urlRaw: "https://clck.ru/33ABCD")]),
        ])
        let (client, _) = try await Self.connected(store)
        let page1 = try await client.callTool(
            name: "find_links", arguments: ["url": "https://clck.ru/33ABCD", "limit": .int(1)]).value
        let out1 = try Self.decode(page1, as: FindLinksOutput.self)
        #expect(out1.links.count == 1 && out1.total == 2)
        #expect(out1.index_moved_since_cursor == false)
        let cursor = try #require(out1.next_cursor)
        guard case .text(let text, _, _) = page1.content.first else {
            Issue.record("expected a text content block"); return
        }
        #expect(text.contains("next_cursor"), "the text rendering tells a model how to continue")

        let page2 = try await client.callTool(
            name: "find_links", arguments: ["url": "https://clck.ru/33ABCD", "limit": .int(1),
                                            "cursor": .string(cursor)]).value
        let out2 = try Self.decode(page2, as: FindLinksOutput.self)
        #expect(out2.links.map(\.post) == ["@iosgr/3"], "the second page must not repeat")
        #expect(out2.next_cursor == nil)
        #expect(page2.structuredContent?.objectValue?["next_cursor"] == nil,
                "a final page omits next_cursor rather than sending null against a string schema")

        // A link cursor is bound to its URL, and to find_links: neither misuse pages silently.
        await Self.expectInvalidParams("cursor for another URL") {
            try await client.callTool(
                name: "find_links", arguments: ["url": "https://example.com", "cursor": .string(cursor)]).value
        }
        await Self.expectInvalidParams("link cursor passed to search_posts") {
            try await client.callTool(
                name: "search_posts", arguments: ["query": "про", "cursor": .string(cursor)]).value
        }
    }

    /// 🟡 The text footer decided "more to fetch" by `page.count < total`, which is true on every
    /// page of a multi-page walk — including the last, which then told the model to pass a
    /// `next_cursor` that did not exist. With `limit: 0` it said no posts linked at all.
    @Test("the text footer follows next_cursor: a final page is the end, a count is a count")
    func footerFollowsNextCursor() async throws {
        let store = try Self.seededStore()
        try store.upsert(posts: [
            Post(id: .init(channelUsername: "iosgr", messageID: 3),
                 date: Date(timeIntervalSince1970: 1_700_000_003),
                 kind: .text, formatSource: .web, mediaCount: 1, text: "тот же сократитель",
                 links: [LinkRef(urlRaw: "https://clck.ru/33ABCD")]),
        ])
        let (client, _) = try await Self.connected(store)
        func text(_ r: CallTool.Result) throws -> String {
            guard case .text(let s, _, _) = r.content.first else {
                throw MCPError.internalError("expected a text content block")
            }
            return s
        }
        let url: Value = "https://clck.ru/33ABCD"
        let first = try await client.callTool(
            name: "find_links", arguments: ["url": url, "limit": .int(1)]).value
        let cursor = try #require(try Self.decode(first, as: FindLinksOutput.self).next_cursor)
        #expect(try text(first).hasSuffix("1 of 2 post(s) — pass next_cursor for the rest"))

        let last = try await client.callTool(
            name: "find_links", arguments: ["url": url, "limit": .int(1), "cursor": .string(cursor)]).value
        #expect(try text(last).hasSuffix("1 of 2 post(s)"),
                "a final page smaller than total is the end of the walk, not a page to continue")

        let count = try await client.callTool(
            name: "find_links", arguments: ["url": url, "limit": .int(0)]).value
        #expect(try Self.decode(count, as: FindLinksOutput.self).total == 2)
        #expect(try text(count) == "0 of 2 post(s)", "a count is not an empty result set")

        let search = try await client.callTool(
            name: "search_posts", arguments: ["query": "про", "limit": .int(1)]).value
        let more = try #require(try Self.decode(search, as: SearchPostsOutput.self).next_cursor)
        let end = try await client.callTool(
            name: "search_posts", arguments: ["query": "про", "limit": .int(1), "cursor": .string(more)]).value
        #expect(try text(end).hasSuffix("1 of 2 result(s)"))
    }

    /// 🔴 `Args.int` converted a whole-valued double with `Int(_:)`, which traps past ±2^63 — so
    /// `"limit": 1e20` killed the server instead of being clamped as the schema promises.
    @Test("a limit past Int.max is clamped, not a crash")
    func hugeLimitIsClampedNotFatal() async throws {
        let (client, _) = try await Self.connected(try Self.seededStore())
        let out = try await client.callTool(
            name: "search_posts", arguments: ["query": "про", "limit": .double(1e20)]).value
        #expect(try Self.decode(out, as: SearchPostsOutput.self).posts.count == 2)
        await Self.expectInvalidParams("a hugely negative limit is still a negative limit") {
            try await client.callTool(
                name: "search_posts", arguments: ["query": "про", "limit": .double(-1e20)]).value
        }
        await Self.expectInvalidParams("a fractional limit is not an integer") {
            try await client.callTool(
                name: "search_posts", arguments: ["query": "про", "limit": .double(1.5)]).value
        }
    }

    /// 🔴 A date-only `to` became `T23:59:59Z`, so a post stamped inside the day's final second was
    /// outside an "inclusive" bound on the day it belongs to.
    @Test("a date-only `to` includes the whole day it names, and nothing after it")
    func dateOnlyToCoversTheWholeDay() async throws {
        let store = try Self.seededStore()
        // 1_700_006_400 is 2023-11-15T00:00:00Z.
        try store.upsert(posts: [
            Post(id: .init(channelUsername: "iosgr", messageID: 3),
                 date: Date(timeIntervalSince1970: 1_700_006_399.5),
                 kind: .text, formatSource: .web, mediaCount: 1, text: "дедлайн перед полуночью"),
            Post(id: .init(channelUsername: "iosgr", messageID: 4),
                 date: Date(timeIntervalSince1970: 1_700_006_400),
                 kind: .text, formatSource: .web, mediaCount: 1, text: "дедлайн в полночь"),
        ])
        let (client, _) = try await Self.connected(store)
        let result = try await client.callTool(
            name: "search_posts", arguments: ["query": "дедлайн", "to": "2023-11-14"]).value
        let out = try Self.decode(result, as: SearchPostsOutput.self)
        #expect(out.posts.map(\.post) == ["@iosgr/3"] && out.total == 1,
                "23:59:59.5 is still the 14th; 00:00:00 of the 15th is not")

        let from = try await client.callTool(
            name: "search_posts", arguments: ["query": "дедлайн", "from": "2023-11-15"]).value
        #expect(try Self.decode(from, as: SearchPostsOutput.self).posts.map(\.post) == ["@iosgr/4"])
    }

    /// 🔴 A poll post has no body, so its text rendering was `[poll, no text]` — a client that shows
    /// only `content` could not read the one thing the post says.
    @Test("get_post renders a poll's question and options for text-only clients")
    func pollRendersAsText() async throws {
        let store = try Self.seededStore()
        try store.upsert(posts: [
            Post(id: .init(channelUsername: "iosgr", messageID: 5),
                 date: Date(timeIntervalSince1970: 1_700_000_005),
                 kind: .poll, formatSource: .web, mediaCount: 0, text: "",
                 poll: Poll(question: "Какой архитектурный паттерн?",
                            options: ["MVVM", "TCA", "VIPER"], totalVotes: 42)),
        ])
        let (client, _) = try await Self.connected(store)
        let result = try await client.callTool(
            name: "get_post", arguments: ["post": "@iosgr/5"]).value
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("expected a text content block"); return
        }
        #expect(text.contains("Какой архитектурный паттерн?"))
        for option in ["MVVM", "TCA", "VIPER"] { #expect(text.contains(option)) }
        #expect(text.contains("42"))
        #expect(!text.contains("no text"), "a poll is not an empty post")
    }

    @Test("get_post returns the full record; a missing post is a tool error, not silence")
    func getPost() async throws {
        let (client, _) = try await Self.connected(try Self.seededStore())
        let result = try await client.callTool(
            name: "get_post", arguments: ["post": "@iosgr/1"]).value
        let detail = try Self.decode(result, as: PostDetail.self)
        #expect(detail.text.contains("Вёрстка"))
        #expect(detail.reactions == [.init(emoji: "👍", count: 5, is_paid: false)])
        #expect(detail.links.first?.url_canonical == URLCanonicaliser.canonicalise("https://clck.ru/33ABCD"))
        #expect(detail.link == "https://t.me/iosgr/1")

        // The t.me form parses to the same post.
        let viaLink = try await client.callTool(
            name: "get_post", arguments: ["post": "https://t.me/iosgr/1"]).value
        #expect(try Self.decode(viaLink, as: PostDetail.self).message_id == 1)

        let missing = try await client.callTool(
            name: "get_post", arguments: ["post": "@iosgr/404"]).value
        #expect(missing.isError == true)
        await Self.expectInvalidParams("unparseable post ref") {
            try await client.callTool(name: "get_post",
                                      arguments: ["post": "not a ref"]).value
        }
    }

    @Test("an unknown tool name is a tool error, the conformance server's convention")
    func unknownTool() async throws {
        let (client, _) = try await Self.connected(try Self.seededStore())
        let result = try await client.callTool(name: "rm_everything").value
        #expect(result.isError == true)
    }

    /// The post-ref parser is the surface a model types against most — pin its accepted forms.
    @Test("parsePostRef accepts the emitted literal and the pasteable forms")
    func postRefParsing() throws {
        let expected = Post.ID(channelUsername: "iosgr", messageID: 123)
        #expect(TGKBServer.parsePostRef("@iosgr/123") == expected)
        #expect(TGKBServer.parsePostRef("iosgr/123") == expected)
        #expect(TGKBServer.parsePostRef("https://t.me/iosgr/123") == expected)
        #expect(TGKBServer.parsePostRef("t.me/IOSGR/123") == expected,
                "usernames fold — the store key is lowercased")
        #expect(TGKBServer.parsePostRef("iosgr") == nil)
        #expect(TGKBServer.parsePostRef("iosgr/-3") == nil)
        #expect(TGKBServer.parsePostRef("@/123") == nil)
    }
}
