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

    public func classify(_ username: String) async throws -> Channel.Reachability {
        let preview = URL(string: "https://t.me/s/\(username)")!
        let result = try await fetcher.fetch(preview)
        // A 200 whose body actually holds messages. Following the redirect would look like a
        // 200 too, so the path is checked rather than the status alone.
        if result.statusCode == 200, result.finalURL.path.hasPrefix("/s/") {
            return .webPreview
        }

        let plain = try await fetcher.fetch(URL(string: "https://t.me/\(username)")!)
        return Self.classifyPlainPage(plain.body)
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
