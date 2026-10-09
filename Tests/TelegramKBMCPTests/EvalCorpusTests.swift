import Foundation
#if canImport(FoundationXML)
    import FoundationXML
#endif
import MCP
import Testing
import TelegramKBModel
import TelegramKBStore
@testable import TelegramKBMCP

/// The `mcp-builder` evaluation set — `evals/tgkb-mcp/` — kept honest.
///
/// `eval.xml` holds ten questions a model should answer with only the three tools, over the
/// synthetic corpus in `corpus.json`. This suite answers every one of them through the real server,
/// by a route a model could take, and compares with the committed answer: an answer the tools cannot
/// reach, or a corpus edit that moves one, fails here rather than in a model's grade. Grading a model
/// is `Scripts/run_mcp_eval.py`'s job; it reads the store this suite writes when `TGKB_EVAL_STORE`
/// names a path.
struct EvalCorpusTests {

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("evals/tgkb-mcp")

    /// `corpus.json`, as written: invented channels, people and posts.
    struct Corpus: Decodable {
        struct Link: Decodable { var url: String; var title: String?; var site: String? }
        struct PollEntry: Decodable { var question: String; var options: [String]; var votes: Int? }
        struct Ref: Decodable { var channel: String; var id: Int }
        struct ReactionEntry: Decodable { var emoji: String; var count: Int }
        struct Entry: Decodable {
            var channel: String
            var id: Int
            var date: Date
            var kind: String
            var text: String?
            var author: String?
            var links: [Link]?
            var poll: PollEntry?
            var forward: Ref?
            var reactions: [ReactionEntry]?
            var views: Int?
            var hashtags: [String]?
        }
        struct Resolution: Decodable { var url: String; var resolved: String }

        var channels: [String]
        var resolutions: [Resolution]
        var posts: [Entry]

        static func load() throws -> Corpus {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Corpus.self,
                                      from: Data(contentsOf: directory.appendingPathComponent("corpus.json")))
        }
    }

    /// Writes the corpus into a store at `path`, the way a sync would leave it.
    static func seed(at path: String) throws -> Store {
        let corpus = try Corpus.load()
        let store = try Store.openForWriting(at: path)
        for (index, username) in corpus.channels.enumerated() {
            // Invented ids, distinct and non-zero: a 0 reads as an unverified import.
            try store.upsert(channel: Channel(username: username, rawChannelID: 1_000_000_001 + Int64(index)))
        }
        try store.upsert(posts: try corpus.posts.map { entry in
            let kind = try #require(PostKind(rawValue: entry.kind), "\(entry.kind) is not a PostKind")
            return Post(
                id: .init(channelUsername: entry.channel, messageID: entry.id),
                date: entry.date, kind: kind, formatSource: .web,
                mediaCount: kind == .poll ? 0 : 1, text: entry.text ?? "", authorName: entry.author,
                forward: entry.forward.map { ForwardOrigin(channelUsername: $0.channel, messageID: $0.id) },
                hashtags: entry.hashtags ?? [],
                links: (entry.links ?? []).map { link in
                    LinkRef(urlRaw: link.url, preview: link.title.map {
                        LinkPreview(siteName: link.site, title: $0, observedAt: entry.date)
                    })
                },
                reactions: (entry.reactions ?? []).map { Reaction(emoji: $0.emoji, count: $0.count) },
                poll: entry.poll.map { Poll(question: $0.question, options: $0.options, totalVotes: $0.votes) },
                views: entry.views.map { ViewCount(value: $0, isApproximate: false) })
        })
        try store.upsert(resolutions: try corpus.resolutions.map {
            URLResolution(urlCanonical: try #require(URLCanonicaliser.canonicalise($0.url)),
                          resolvedCanonical: $0.resolved, httpStatus: "301", hops: 1,
                          resolvedAt: Date(timeIntervalSince1970: 1_700_000_000))
        })
        return store
    }

    /// The `<answer>` of every `<qa_pair>`, in order — read with a parser, not a pattern.
    static func committedAnswers() throws -> [String] {
        final class Answers: NSObject, XMLParserDelegate {
            var answers: [String] = []
            var current: String?
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                if name == "answer" { current = "" }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { current? += string }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName: String?) {
                if name == "answer", let text = current { answers.append(text); current = nil }
            }
        }
        let parser = try #require(XMLParser(contentsOf: directory.appendingPathComponent("eval.xml")))
        let delegate = Answers()
        parser.delegate = delegate
        #expect(parser.parse(), "eval.xml must parse: \(String(describing: parser.parserError))")
        return delegate.answers
    }

    /// One tool call, failing the test on a tool error — every route below is a successful one.
    static func call(_ client: Client, _ tool: String, _ arguments: [String: Value]) async throws
        -> CallTool.Result {
        let result = try await client.callTool(name: tool, arguments: arguments).value
        #expect(result.isError != true, "\(tool) \(arguments): \(result.content)")
        return result
    }

    static func search(_ client: Client, _ arguments: [String: Value]) async throws -> SearchPostsOutput {
        try MCPServerTests.decode(try await call(client, "tgkb_search_posts", arguments), as: SearchPostsOutput.self)
    }

    static func post(_ client: Client, _ ref: String) async throws -> PostDetail {
        try MCPServerTests.decode(try await call(client, "tgkb_get_post", ["post": .string(ref)]), as: PostDetail.self)
    }

    @Test("every committed answer in evals/tgkb-mcp/eval.xml is what the tools give")
    func answersAreReachable() async throws {
        let store = try Self.seed(at: MCPServerTests.tempPath())
        let (client, _) = try await MCPServerTests.connected(store)
        let committed = try Self.committedAnswers()
        try #require(committed.count == 10, "the skill's set is ten questions")
        var derived: [String] = []

        // 1. One article, three spellings: direct, a shortener resolved to it, and a utm_ variant.
        let launch = try MCPServerTests.decode(try await Self.call(
            client, "tgkb_find_links", ["url": "https://perf.example.com/blog/cold-launch-budget"]),
                                              as: FindLinksOutput.self)
        derived.append("\(Set(launch.links.map(\.channel)).count)")

        // 2. A poll has no body: its question is what the index holds.
        let polls = try await Self.search(client, ["query": "состоянием", "kind": "poll",
                                                   "channel": "iosarch_demo", "from": "2023-03-01", "to": "2023-05-31"])
        let pollHit = try #require(polls.posts.first)
        let poll = try #require(try await Self.post(client, pollHit.post).poll)
        derived.append(poll.options[2])

        // 3. The Russian post came first; an English-only search finds a later one.
        var macros: [PostSummary] = []
        for query in ["макросы", "macros"] {
            macros += try await Self.search(client, ["query": .string(query), "from": "2023-06-05"]).posts
        }
        derived.append(try #require(macros.min { $0.date < $1.date }).channel)

        // 4. The repost names its origin; only tgkb_get_post carries it.
        let repost = try #require(try await Self.search(
            client, ["query": "пакетов", "channel": "iosarch_demo"]).posts.first)
        let origin = try #require(try await Self.post(client, repost.post).forward?.post)
        derived.append("https://t.me/" + origin.dropFirst())

        // 5. Author names are indexed; `total` counts each one's posts in the window.
        var signed: [(String, Int)] = []
        for author in Set(try Corpus.load().posts.compactMap(\.author)) {
            let page = try await Self.search(client, ["query": .string(author), "channel": "swiftdigest_demo",
                                                      "from": "2022-01-01", "to": "2022-12-31", "limit": 0])
            signed.append((author, page.total))
        }
        derived.append(try #require(signed.max { $0.1 < $1.1 }).0)

        // 6. Reactions are a total across emojis.
        let combine = try await Self.search(client, ["query": "Combine", "from": "2022-01-01", "to": "2022-12-31"])
        derived.append(try #require(combine.posts.max { $0.reactions < $1.reactions }).link)

        // 7. No answer is an answer.
        var matches = 0
        for query in ["гравитационные волны", "gravitational waves"] {
            matches += try await Self.search(client, ["query": .string(query)]).total
        }
        derived.append(matches == 0 ? "No" : "Yes")

        // 8. A word inside an identifier: only the substring index sees it.
        let coordinators = try await Self.search(client, ["query": "Coordinator", "mode": "substring"])
        var identifiers: [String] = []
        for hit in coordinators.posts {
            let text = try await Self.post(client, hit.post).text
            identifiers += text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { $0.hasPrefix("Onboarding") && $0.hasSuffix("Coordinator") }
        }
        derived.append(try #require(identifiers.first))

        // 9. Find one sharing, then every sharing of its link.
        let throwsHit = try #require(try await Self.search(client, ["query": "throws"]).posts.first)
        let proposal = try #require(try await Self.post(client, throwsHit.post).links.first?.url_raw)
        let sharings = try MCPServerTests.decode(try await Self.call(
            client, "tgkb_find_links", ["url": .string(proposal)]), as: FindLinksOutput.self)
        derived.append(String(try #require(sharings.links.map(\.date).min()).prefix(10)))

        // 10. More matches than one page holds: walk the cursor.
        var dates: [String] = [], cursor: String?, pages = 0
        repeat {
            var arguments: [String: Value] = ["query": "SwiftUI", "channel": "swiftdigest_demo"]
            if let cursor { arguments["cursor"] = .string(cursor) }
            let page = try await Self.search(client, arguments)
            dates += page.posts.map(\.date)
            cursor = page.next_cursor
            pages += 1
        } while cursor != nil
        #expect(pages > 1, "question 10 exists to make a model page; keep it past one default page")
        derived.append(String(try #require(dates.min()).prefix(10)))

        try #require(derived.count == committed.count, "one derived answer per question")
        for (index, (got, want)) in zip(derived, committed).enumerated() {
            #expect(got == want, "question \(index + 1): the tools give \(got.debugDescription)")
        }
    }

    /// The corpus is invented and must stay so: the repository is public, and real messages or
    /// links would be someone else's content. Ids also rise with dates, as Telegram's do.
    @Test("the eval corpus is synthetic, and its ids rise with its dates")
    func corpusIsSynthetic() throws {
        let corpus = try Corpus.load()
        for channel in corpus.channels { #expect(channel.hasSuffix("_demo"), "\(channel) is not an invented name") }
        let urls = corpus.posts.flatMap { $0.links ?? [] }.map(\.url) + corpus.resolutions.flatMap { [$0.url, $0.resolved] }
        for url in urls {
            let host = try #require(URL(string: url)?.host)
            // RFC 2606 reserves these: no real site can be behind them.
            #expect(host.hasSuffix(".example") || ["example.com", "example.org", "example.net"]
                .contains { host == $0 || host.hasSuffix("." + $0) }, "\(url) is not on a reserved domain")
        }
        for channel in corpus.channels {
            let posts = corpus.posts.filter { $0.channel == channel }.sorted { $0.id < $1.id }
            #expect(posts.map(\.date) == posts.map(\.date).sorted(), "@\(channel): ids must rise with dates")
        }
    }

    /// Writes the eval store where `Scripts/run_mcp_eval.py` asks for it — the one way to get a
    /// `tgkb-mcp` store from the corpus without a crawl.
    @Test("writes the eval store to TGKB_EVAL_STORE",
          .enabled(if: ProcessInfo.processInfo.environment["TGKB_EVAL_STORE"] != nil))
    func writesTheEvalStore() throws {
        let path = try #require(ProcessInfo.processInfo.environment["TGKB_EVAL_STORE"])
        try #require(!FileManager.default.fileExists(atPath: path), "refusing to write over \(path)")
        _ = try Self.seed(at: path)
    }
}
