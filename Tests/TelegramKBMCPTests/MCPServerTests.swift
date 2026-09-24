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
        await #expect(throws: MCPError.self) {
            // A cursor minted by "и" must not page through "вёрстка".
            _ = try await client.callTool(
                name: "search_posts", arguments: ["query": "вёрстка", "cursor": .string(cursor)]).value
        }
    }

    @Test("malformed calls are invalidParams — missing arg, wrong type, unknown key, bad kind")
    func invalidArgsRejected() async throws {
        let (client, _) = try await Self.connected(try Self.seededStore())
        await #expect(throws: MCPError.self) {
            _ = try await client.callTool(name: "search_posts", arguments: [:]).value
        }
        await #expect(throws: MCPError.self) {
            _ = try await client.callTool(
                name: "search_posts", arguments: ["query": .int(3)]).value
        }
        await #expect(throws: MCPError.self) {
            _ = try await client.callTool(
                name: "search_posts", arguments: ["query": "x", "chanel": "iosgr"]).value
        }
        await #expect(throws: MCPError.self) {
            _ = try await client.callTool(
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
        await #expect(throws: MCPError.self) {
            _ = try await client.callTool(name: "get_post",
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
