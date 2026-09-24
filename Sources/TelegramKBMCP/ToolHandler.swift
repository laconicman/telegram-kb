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
/// by hand — a malformed call is a protocol-level `invalidParams`, not a tool error, per the
/// spec's split between *the call was ill-formed* and *the tool ran and failed*.
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
        switch name {
        case TGKBTools.searchPosts.name: return try await searchPosts(Args(arguments), store: store)
        case TGKBTools.findLinks.name: return try findLinks(Args(arguments), store: store)
        case TGKBTools.getPost.name: return try getPost(Args(arguments), store: store)
        // The conformance server's convention: a tool-level error result, not a protocol error —
        // the call was well-formed, the name just isn't ours.
        default:
            return CallTool.Result(
                content: [.text(text: "Unknown tool: \(name)", annotations: nil, _meta: nil)],
                isError: true)
        }
    }

    // MARK: - search_posts

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
                throw MCPError.invalidParams(
                    "kind must be one of \(TGKBTools.postKinds.joined(separator: ", "))")
            }
            filter.kind = k
        }
        filter.from = try args.date("from", bound: .lower)
        filter.to = try args.date("to", bound: .upper)
        let mode = try args.enumerated("mode", as: Store.SearchMode.self) ?? .both
        let limit = try args.int("limit", default: TGKBTools.defaultLimit, clampedTo: TGKBTools.maxLimit)
        let cursor = try args.string("cursor")

        // Hits and their posts from ONE read: a sync committing between two would pair this
        // page's total and cursor with bodies from a corpus they were not computed against.
        let page = try invalidParamsOnSearchError {
            try store.searchPosts(query, mode: mode, filter: filter, limit: limit, cursor: cursor)
        }
        let results = page.results
        let posts = page.posts.map(PostSummary.init)
        let output = SearchPostsOutput(
            posts: posts, total: results.total,
            next_cursor: results.nextCursor,
            index_moved_since_cursor: results.indexMovedSinceCursor)
        return try CallTool.Result(
            content: [.text(text: render(posts, total: results.total),
                            annotations: nil, _meta: nil)],
            structuredContent: output)
    }

    // MARK: - find_links

    static func findLinks(_ args: Args, store: Store) throws -> CallTool.Result {
        try args.expecting(["url", "limit", "cursor"])
        try Task.checkCancellation()
        let url = try args.require("url")
        let limit = try args.int("limit", default: TGKBTools.defaultLimit, clampedTo: TGKBTools.maxLimit)
        let cursor = try args.string("cursor")
        let page = try invalidParamsOnSearchError {
            try store.linkedPosts(to: url, limit: limit, cursor: cursor)
        }
        let results = page.results
        let byID = page.posts.reduce(into: [:]) { $0[$1.id] = $1 }
        let links = results.hits.map { hit -> LinkHitRecord in
            let post = byID[hit.id]
            return LinkHitRecord(
                post: "@\(hit.id.channelUsername)/\(hit.id.messageID)",
                channel: hit.id.channelUsername,
                date: post?.date.formatted(.iso8601) ?? "",
                url_raw: hit.urlRaw,
                url_canonical: hit.urlCanonical,
                resolved_url: hit.effectiveURL,
                snippet: post.map { PostSummary.snippet($0.text.isEmpty ? ($0.poll?.question ?? "") : $0.text) } ?? "",
                link: "https://t.me/\(hit.id.channelUsername)/\(hit.id.messageID)")
        }
        return try CallTool.Result(
            content: [.text(text: render(links, total: results.total), annotations: nil, _meta: nil)],
            structuredContent: FindLinksOutput(
                links: links, total: results.total,
                next_cursor: results.nextCursor,
                index_moved_since_cursor: results.indexMovedSinceCursor))
    }

    /// The cursor is a parameter; a stale or foreign one is an invalid argument, not a tool
    /// failure — -32602 is the honest signal.
    static func invalidParamsOnSearchError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as Store.SearchError {
            throw MCPError.invalidParams(e.description)
        }
    }

    // MARK: - get_post

    static func getPost(_ args: Args, store: Store) throws -> CallTool.Result {
        try args.expecting(["post"])
        try Task.checkCancellation()
        let ref = try args.require("post")
        guard let id = parsePostRef(ref) else {
            throw MCPError.invalidParams(
                "post must be @channel/id or https://t.me/channel/id — got \(ref.debugDescription)")
        }
        guard let post = try store.post(id) else {
            // A successful call with no such post is still a failed lookup — isError, so the
            // model does not mistake an empty result for a post that exists.
            return CallTool.Result(
                content: [.text(text: "No post \(ref) in the archive.", annotations: nil, _meta: nil)],
                isError: true)
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
        guard parts.count == 2, let id = Int(parts[1]), id > 0, !parts[0].isEmpty
        else { return nil }
        return Post.ID(channelUsername: parts[0].lowercased(), messageID: id)
    }

    // MARK: - Text renderings for clients that show only `content`

    static func render(_ posts: [PostSummary], total: Int) -> String {
        var lines = posts.map {
            "\($0.date.prefix(10))  \($0.link)\($0.reactions > 0 ? "  ♥\($0.reactions)" : "")\n    \($0.snippet)"
        }
        lines.append(posts.count < total
            ? "\n\(posts.count) of \(total) result(s) — pass next_cursor for the rest"
            : "\n\(posts.count) result(s)")
        return lines.joined(separator: "\n")
    }

    static func render(_ links: [LinkHitRecord], total: Int) -> String {
        guard !links.isEmpty else { return "No posts link to that URL." }
        return links.map {
            var line = "\($0.date.prefix(10))  \($0.link)\n    \($0.url_raw)"
            if let resolved = $0.resolved_url, resolved != $0.url_raw {
                line += "  →  \(resolved)"
            }
            return line
        }
        .joined(separator: "\n")
        + (links.count < total
            ? "\n\n\(links.count) of \(total) post(s) — pass next_cursor for the rest"
            : "\n\n\(links.count) post(s)")
    }

    /// A poll's question and options are its content, so a text-only client sees them too —
    /// beside the body when there is one, in place of it when there is not.
    static func render(_ p: Post) -> String {
        var lines = ["\(p.permalink)  \(p.date.formatted(.iso8601))"]
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

/// Argument decoding over `[String: Value]` — strict, because the SDK validates nothing.
struct Args {
    let values: [String: Value]
    init(_ values: [String: Value]?) { self.values = values ?? [:] }

    /// `additionalProperties: false`, enforced ourselves: a misspelled key must be a call
    /// error, not a silently dropped filter.
    func expecting(_ keys: [String]) throws {
        let extra = values.keys.filter { !keys.contains($0) }
        guard extra.isEmpty else {
            throw MCPError.invalidParams("unknown argument(s): \(extra.sorted().joined(separator: ", "))")
        }
    }

    func require(_ key: String) throws -> String {
        guard let s = try string(key), !s.isEmpty else {
            throw MCPError.invalidParams("\(key) is required")
        }
        return s
    }

    func string(_ key: String) throws -> String? {
        guard let v = values[key] else { return nil }
        guard let s = v.stringValue else {
            throw MCPError.invalidParams("\(key) must be a string")
        }
        return s
    }

    func int(_ key: String, default d: Int, clampedTo max: Int) throws -> Int {
        guard let v = values[key] else { return d }
        let n: Int? = v.intValue ?? v.doubleValue.flatMap { $0 == $0.rounded() ? Int($0) : nil }
        guard let n, n >= 0 else {
            throw MCPError.invalidParams("\(key) must be a non-negative integer")
        }
        return Swift.min(n, max)
    }

    func enumerated<T: RawRepresentable>(_ key: String, as type: T.Type) throws -> T?
        where T.RawValue == String {
        guard let s = try string(key) else { return nil }
        guard let v = T(rawValue: s) else {
            throw MCPError.invalidParams("\(key) must be one of the declared values, not \(s.debugDescription)")
        }
        return v
    }

    enum Bound { case lower, upper }

    /// ISO-8601, or a bare `YYYY-MM-DD` — which a model produces constantly. A date-only `from`
    /// means the day's start; a date-only `to` means its end, or the filter would exclude the
    /// day it names. The end is the day's last millisecond — the store keeps dates to the
    /// millisecond — not `23:59:59`: the bound is inclusive, and a post stamped inside the final
    /// second is still that day's.
    func date(_ key: String, bound: Bound) throws -> Date? {
        guard let s = try string(key) else { return nil }
        if let d = try? Self.iso.parse(s) { return d }
        if s.count == 10, let start = try? Self.iso.parse(s + "T00:00:00Z") {
            switch bound {
            case .lower: return start
            case .upper: return start.addingTimeInterval(86_400 - 0.001)
            }
        }
        throw MCPError.invalidParams("\(key) must be ISO-8601 or YYYY-MM-DD — got \(s.debugDescription)")
    }

    static let iso = Date.ISO8601FormatStyle()
}
