import Foundation

/// One HTTP GET. Injected so the crawler's tests run against committed fixtures with no network.
///
/// The protocol exists for testability, not for pluggability — there is one production
/// implementation and no plan for a second.
public protocol PageFetcher: Sendable {
    /// - Returns: body, final status code, and whether the request was redirected away from the
    ///   requested path (which is how `t.me/s/<channel>` signals "no web preview").
    func fetch(_ url: URL) async throws -> FetchResult
}

public struct FetchResult: Sendable {
    public var body: String
    public var statusCode: Int
    public var finalURL: URL
    public init(body: String, statusCode: Int, finalURL: URL) {
        self.body = body
        self.statusCode = statusCode
        self.finalURL = finalURL
    }
}

/// The production fetcher: one request at a time, with a delay between them.
///
/// **No concurrency, deliberately.** Channel crawling talks to exactly one host, so the per-host
/// bounded concurrency that mattered for URL resolution (1,654 hosts) buys nothing here and would
/// only make us rude to `t.me`. The endpoint's own ~2.8 s median latency already dominates.
public actor URLSessionPageFetcher: PageFetcher {
    private let session: URLSession
    private let delay: Duration
    private var lastRequest: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    /// Chrome on macOS. Telegram serves the preview to a default `URLSession` UA too, but a
    /// browser UA is what the endpoint is built for and what every probe here was measured with.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    public init(delay: Duration = .seconds(1), session: URLSession = .shared) {
        self.session = session
        self.delay = delay
    }

    public func fetch(_ url: URL) async throws -> FetchResult {
        if let last = lastRequest {
            let elapsed = clock.now - last
            if elapsed < delay { try await Task.sleep(for: delay - elapsed) }
        }
        lastRequest = clock.now

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return FetchResult(body: String(decoding: data, as: UTF8.self),
                           statusCode: http?.statusCode ?? 0,
                           finalURL: http?.url ?? url)
    }
}
