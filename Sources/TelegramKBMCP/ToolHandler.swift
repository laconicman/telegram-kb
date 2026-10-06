import Darwin
import Foundation
import Logging
import MCP
import TelegramKBModel
import TelegramKBStore

// `FileDescriptor` is `System` on newer toolchains, `SystemPackage` on older — the same
// conditional the SDK itself uses, and required to agree with `StdioTransport`'s signature.
#if canImport(System)
    import System
#else
    import SystemPackage
#endif

/// The tool-call surface: argument decoding, dispatch, and server assembly.
///
/// The SDK does not validate arguments against `inputSchema`, so this file decodes and rejects
/// by hand. Where a failure goes follows the 2025-11-25 spec's split (SEP-1303): an argument the
/// tool cannot use is a **tool execution error** — a result with `isError: true`, whose text the
/// model reads and corrects itself from — while an unknown tool is a **protocol error**, because
/// no tool ran at all.
///
/// Lives in the library so tests drive the real `Server` over `InMemoryTransport` rather than
/// a re-implementation.
public enum TGKBServer {

    /// The server identity clients see at `initialize`.
    public static let version = "0.1.0"

    /// Builds the `Server` with `tools/list` and `tools/call` wired to this store.
    public static func makeServer(store: Store) async -> Server {
        let server = Server(
            name: "tgkb-mcp",
            version: version,
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: TGKBTools.all, nextCursor: nil)
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await call(params.name, arguments: params.arguments, store: store)
        }
        return server
    }

    /// A `StdioTransport` that a stray `print()` cannot poison.
    ///
    /// Stdio frames JSON-RPC on stdout delimited by newlines, so any non-JSON line written to
    /// fd 1 — ours, or a dependency's — corrupts the session silently. The SDK protects only
    /// itself (a no-op logger when none is passed). So: `dup` the real stdout to a spare
    /// descriptor for the transport's exclusive use, then repoint fd 1 at stderr, where the
    /// spec says free-form diagnostics belong. After that a `print()` is harmless noise rather
    /// than a hung client. (`research/mcp-swift-sdk.md` § Logging 5.)
    public static func guardedStdioTransport(logger: Logger? = nil) -> StdioTransport {
        let realStdout = dup(STDOUT_FILENO)
        guard realStdout >= 0 else {
            // A failed dup means stdout was already odd; fall back to the SDK default rather
            // than serve a client we cannot answer.
            return StdioTransport(logger: logger)
        }
        dup2(STDERR_FILENO, STDOUT_FILENO)
        return StdioTransport(output: FileDescriptor(rawValue: realStdout), logger: logger)
    }

    // MARK: - Dispatch

    static func call(_ name: String, arguments: [String: Value]?, store: Store) async throws
        -> CallTool.Result {
        let args = Args(arguments)
        do {
            switch name {
            case TGKBTools.searchPosts.name: return try await searchPosts(args, store: store)
            case TGKBTools.findLinks.name: return try findLinks(args, store: store)
            case TGKBTools.getPost.name: return try getPost(args, store: store)
            // Both spec revisions list an unknown tool as a protocol error, and 2025-06-18's own
            // example answers it with -32602: nothing ran, so there is no tool result to report.
            default: throw MCPError.invalidParams("Unknown tool: \(name)")
            }
        } catch let error as ToolInputError {
            return failure(error.message)
        } catch let error as Store.SearchError {
            // A stale or foreign cursor is an argument the tool cannot use, like any other.
            return failure(error.description)
        }
    }

    /// A tool execution error: the call reached a tool, which could not do what was asked. The
    /// text is all the model sees of it, so it says what to do instead.
    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    // MARK: - tgkb_search_posts

    static func searchPosts(_ args: Args, store: Store) async throws -> CallTool.Result {
        try args.expecting(["query", "channel", "kind", "from", "to", "mode", "limit", "cursor"])
        try Task.checkCancellation()
        let query = try args.require("query")
        var filter = Store.SearchFilter()
        if let channel = try args.string("channel") {
            // The record emits `@username`; accept the bare form too — a model that drops the
            // sigil means the same channel, and refusing would only force a retry.
            filter.channel = String(channel.drop(while: { $0 == "@" })).lowercased()
        }
        if let kind = try args.string("kind") {
            guard let k = PostKind(rawValue: kind) else {
                throw ToolInputError("kind must be one of \(TGKBTools.postKinds.joined(separator: ", "))")
            }
            filter.kind = k
        }
        switch try args.date("from") {
        case .instant(let d)?, .day(start: let d)?: filter.from = d
        case nil: break
        }
        switch try args.date("to") {
        case .instant(let d)?: filter.to = d
        case .day(start: let d)?: filter.before = d.addingTimeInterval(86_400)
        case nil: break
        }
        let mode = try args.enumerated("mode", as: Store.SearchMode.self) ?? .both
        let limit = try args.int("limit", default: TGKBTools.defaultLimit, clampedTo: TGKBTools.maxLimit)
        let cursor = try args.string("cursor")

        // Hits and their posts from ONE read: a sync committing between two would pair this
        // page's total and cursor with bodies from a corpus they were not computed against.
        let page = try store.searchPosts(query, mode: mode, filter: filter, limit: limit, cursor: cursor)
        let results = page.results
        let posts = page.posts.map(PostSummary.init)
        let output = SearchPostsOutput(
            posts: posts, total: results.total,
            next_cursor: results.nextCursor,
            index_moved_since_cursor: results.indexMovedSinceCursor)
        return try CallTool.Result(
            content: [.text(text: render(posts, total: results.total, nextCursor: results.nextCursor),
                            annotations: nil, _meta: nil)],
            structuredContent: output)
    }

    // MARK: - tgkb_find_links

    static func findLinks(_ args: Args, store: Store) throws -> CallTool.Result {
        try args.expecting(["url", "limit", "cursor"])
        try Task.checkCancellation()
        let url = try args.require("url")
        let limit = try args.int("limit", default: TGKBTools.defaultLimit, clampedTo: TGKBTools.maxLimit)
        let cursor = try args.string("cursor")
        let page = try store.linkedPosts(to: url, limit: limit, cursor: cursor)
        let results = page.results
        let byID = page.posts.reduce(into: [:]) { $0[$1.id] = $1 }
        let links = results.hits.map { hit -> LinkHitRecord in
            let post = byID[hit.id]
            return LinkHitRecord(
                post: "@\(hit.id.channelUsername)/\(hit.id.messageID)",
                channel: hit.id.channelUsername,
                date: post?.date.tgkbISO8601 ?? "",
                url_raw: hit.urlRaw,
                url_canonical: hit.urlCanonical,
                resolved_url: hit.effectiveURL,
                snippet: post.map { PostSummary.snippet($0.text.isEmpty ? ($0.poll?.question ?? "") : $0.text) } ?? "",
                link: "https://t.me/\(hit.id.channelUsername)/\(hit.id.messageID)")
        }
        return try CallTool.Result(
            content: [.text(text: render(links, total: results.total, nextCursor: results.nextCursor),
                            annotations: nil, _meta: nil)],
            structuredContent: FindLinksOutput(
                links: links, total: results.total,
                next_cursor: results.nextCursor,
                index_moved_since_cursor: results.indexMovedSinceCursor))
    }

    // MARK: - tgkb_get_post

    static func getPost(_ args: Args, store: Store) throws -> CallTool.Result {
        try args.expecting(["post"])
        try Task.checkCancellation()
        let ref = try args.require("post")
        guard let id = parsePostRef(ref) else {
            throw ToolInputError("post must be @channel/id or https://t.me/channel/id — got \(ref.debugDescription)")
        }
        guard let post = try store.post(id) else {
            // A successful call with no such post is still a failed lookup — isError, so the
            // model does not mistake an empty result for a post that exists.
            return failure("No post \(ref) in the archive.")
        }
        return try CallTool.Result(
            content: [.text(text: render(post), annotations: nil, _meta: nil)],
            structuredContent: PostDetail(post))
    }

    /// `@channel/id`, `channel/id`, `t.me/channel/id`, `https://t.me/channel/id` — the literal
    /// the records emit, plus the paste-friendly forms.
    static func parsePostRef(_ text: String) -> Post.ID? {
        var s = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://t.me/", "http://t.me/", "t.me/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.hasPrefix("@") { s.removeFirst() }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        // `Channel.isUsername`, not merely non-empty: `@bad name/1` is a malformed reference, and
        // saying so tells the model to fix the reference rather than that the post is missing.
        guard parts.count == 2, let id = Int(parts[1]), id > 0, Channel.isUsername(String(parts[0]))
        else { return nil }
        return Post.ID(channelUsername: parts[0].lowercased(), messageID: id)
    }

    // MARK: - Text renderings for clients that show only `content`

    /// One hit per pair of lines: `date  permalink  [by author]  [♥n]`, then the snippet. The
    /// permalink names the channel; a signed post's author has nowhere else to appear in text.
    static func render(_ posts: [PostSummary], total: Int, nextCursor: String?) -> String {
        var lines = posts.map {
            "\($0.date.prefix(10))  \($0.link)\($0.author.map { "  by \($0)" } ?? "")"
                + "\($0.reactions > 0 ? "  ♥\($0.reactions)" : "")\n    \($0.snippet)"
        }
        lines.append("\n" + footer(posts.count, of: total, noun: "result", nextCursor: nextCursor))
        return lines.joined(separator: "\n")
    }

    static func render(_ links: [LinkHitRecord], total: Int, nextCursor: String?) -> String {
        guard total > 0 else { return "No posts link to that URL." }
        let foot = footer(links.count, of: total, noun: "post", nextCursor: nextCursor)
        guard !links.isEmpty else { return foot }
        return links.map {
            var line = "\($0.date.prefix(10))  \($0.link)\n    \($0.url_raw)"
            if let resolved = $0.resolved_url, resolved != $0.url_raw {
                line += "  →  \(resolved)"
            }
            return line
        }
        .joined(separator: "\n") + "\n\n" + foot
    }

    /// The store decides whether a page continues (`nextCursor`), so the footer follows it: a
    /// final page that is smaller than `total` is the end of the walk, not a page to fetch more of.
    /// The cursor itself is in the text — a client that shows only `content` has no other way to
    /// get it.
    static func footer(_ shown: Int, of total: Int, noun: String, nextCursor: String?) -> String {
        if let nextCursor {
            return "\(shown) of \(total) \(noun)(s) — for the rest, call again with cursor: \(nextCursor)"
        }
        return shown < total ? "\(shown) of \(total) \(noun)(s)" : "\(shown) \(noun)(s)"
    }

    /// A poll's question and options are its content, so a text-only client sees them too —
    /// beside the body when there is one, in place of it when there is not.
    static func render(_ p: Post) -> String {
        var lines = ["\(p.permalink)  \(p.date.tgkbISO8601)"]
        if let author = p.authorName { lines.append("by \(author)") }
        if !p.text.isEmpty { lines.append(p.text) }
        if let poll = p.poll {
            lines.append("Poll: \(poll.question)")
            lines.append(contentsOf: poll.options.map { "  • \($0)" })
            if let votes = poll.totalVotes { lines.append("  \(votes) vote(s)") }
        } else if p.text.isEmpty {
            lines.append("[\(p.kind.rawValue), no text]")
        }
        return lines.joined(separator: "\n")
    }
}

/// An argument the tool cannot use. ``TGKBServer/call(_:arguments:store:)`` turns it into a tool
/// execution error, so the model reads the message and retries with the argument fixed.
struct ToolInputError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Argument decoding over `[String: Value]` — strict, because the SDK validates nothing.
struct Args {
    let values: [String: Value]
    init(_ values: [String: Value]?) { self.values = values ?? [:] }

    /// `additionalProperties: false`, enforced ourselves: a misspelled key must be an error the
    /// model sees, not a silently dropped filter.
    func expecting(_ keys: [String]) throws {
        let extra = values.keys.filter { !keys.contains($0) }
        guard extra.isEmpty else {
            throw ToolInputError("unknown argument(s): \(extra.sorted().joined(separator: ", "))")
        }
    }

    func require(_ key: String) throws -> String {
        guard let s = try string(key), !s.isEmpty else {
            throw ToolInputError("\(key) is required")
        }
        return s
    }

    func string(_ key: String) throws -> String? {
        guard let v = values[key] else { return nil }
        guard let s = v.stringValue else {
            throw ToolInputError("\(key) must be a string")
        }
        return s
    }

    func int(_ key: String, default d: Int, clampedTo max: Int) throws -> Int {
        guard let v = values[key] else { return d }
        let n: Int?
        if let i = v.intValue {
            n = i
        } else if let x = v.doubleValue, x.isFinite, x == x.rounded() {
            // A whole number past ±2^63 is still a whole number, and the schema promises
            // clamping; `Int(_:)` would trap there and take the server with it.
            n = Int(exactly: x) ?? (x > 0 ? Int.max : Int.min)
        } else {
            n = nil
        }
        guard let n, n >= 0 else {
            throw ToolInputError("\(key) must be a non-negative integer")
        }
        return Swift.min(n, max)
    }

    func enumerated<T: RawRepresentable>(_ key: String, as type: T.Type) throws -> T?
        where T.RawValue == String {
        guard let s = try string(key) else { return nil }
        guard let v = T(rawValue: s) else {
            throw ToolInputError("\(key) must be one of the declared values, not \(s.debugDescription)")
        }
        return v
    }

    /// A date argument as written: an instant, or a whole calendar day.
    enum DateArg: Equatable {
        case instant(Date)
        /// `YYYY-MM-DD` — which a model produces constantly. The caller decides what "the day"
        /// means for its bound: its first instant as a lower bound, and *everything before the
        /// next day* as an upper one. The day's "last instant" is not a representable date, and
        /// any approximation of it excludes the posts stamped after it.
        case day(start: Date)
    }

    /// ISO-8601 with or without fractional seconds — the store keeps dates to the millisecond,
    /// so a bound must be expressible at that precision — or a bare `YYYY-MM-DD`.
    func date(_ key: String) throws -> DateArg? {
        guard let s = try string(key) else { return nil }
        if let d = try? Self.iso.parse(s) { return .instant(d) }
        if let d = try? Self.isoFractional.parse(s) { return .instant(d) }
        if s.count == 10, let start = try? Self.iso.parse(s + "T00:00:00Z") { return .day(start: start) }
        throw ToolInputError("\(key) must be ISO-8601 or YYYY-MM-DD — got \(s.debugDescription)")
    }

    static let iso = Date.ISO8601FormatStyle()
    static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
