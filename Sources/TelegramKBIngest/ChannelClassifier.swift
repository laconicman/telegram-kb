import Foundation
import TelegramKBModel

/// Decides whether a channel is reachable through the web preview, and if not, why.
///
/// `t.me/s/<name>` returns the **same 302** for three different situations, so the redirect alone
/// carries no information. Only the plain page tells them apart — and the distinction decides
/// whether a channel is Phase 1 work or needs TDLib.
public struct ChannelClassifier: Sendable {
    let fetcher: PageFetcher
    public init(fetcher: PageFetcher) { self.fetcher = fetcher }

    /// - Throws: `WebPreviewSource.CrawlError.http` on any non-2xx response. A 429 or 5xx page
    ///   holds none of the markers below, so classifying it would call a live channel
    ///   "not publicly resolvable" — and `sync` would skip it and exit 0 on stale data.
    public func classify(_ username: String) async throws -> Channel.Reachability {
        // Before it reaches a URL: a name with a `/`, `?` or space would crash `URL(string:)`
        // or quietly fetch a different page (PR #3, review round 2).
        guard Channel.isUsername(username) else { throw Channel.InvalidUsername(name: username) }
        let preview = URL(string: "https://t.me/s/\(username)")!
        let result = try await Self.successful(fetcher.fetch(preview), preview)
        // A 200 whose body actually holds messages. Following the redirect would look like a
        // 200 too, so the path is checked rather than the status alone.
        if result.finalURL.path.hasPrefix("/s/") {
            return .webPreview
        }

        let url = URL(string: "https://t.me/\(username)")!
        let plain = try await Self.successful(fetcher.fetch(url), url)
        return Self.classifyPlainPage(plain.body)
    }

    static func successful(_ result: FetchResult, _ url: URL) throws -> FetchResult {
        guard (200..<300).contains(result.statusCode) else {
            throw WebPreviewSource.CrawlError.http(status: result.statusCode, url: url.absoluteString)
        }
        return result
    }

    /// - `tgme_page_extra` reading "N subscribers" → a broadcast channel exists, so a 302 on
    ///   `/s/` means its **preview is switched off**.
    /// - "N members" → a **group**, which has no `/s/` preview at all.
    /// - Neither, only "If you have Telegram, you can contact @X" → **not publicly resolvable**.
    static func classifyPlainPage(_ html: String) -> Channel.Reachability {
        guard let extra = between(html, #"<div class="tgme_page_extra">"#, "</div>") else {
            return .unresolvable
        }
        if extra.contains("subscriber") { return .previewDisabled }
        if extra.contains("member") { return .group }
        return .unresolvable
    }

    static func between(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex)
        else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }
}
