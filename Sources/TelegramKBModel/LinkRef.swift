import Foundation

/// A link as it appeared in a post, plus everything derived from it.
///
/// **`urlRaw` is never rewritten.** What was crawled is a fact about the post; the canonical form
/// is an index built on top of it. That is what lets a spec revision be a recompute rather than a
/// re-crawl — see `Design` § *URLs: store both forms*.
public struct LinkRef: Codable, Hashable, Sendable {
    /// Exactly as it appeared in the post's markup. Immutable.
    public var urlRaw: String

    /// `URLCanonicaliser.canonicalise(urlRaw)`. `nil` when the input is not an absolute
    /// http(s) URL — store the raw form and mark it non-canonical; this is not an error.
    public var urlCanonical: String?

    /// The spec version `urlCanonical` was produced under.
    ///
    /// A column rather than a constant so a spec bump is a *query* — "recompute every row whose
    /// version is below N" — instead of a migration script.
    public var canonicalSpecVersion: Int

    /// Link-preview metadata, as Telegram resolved it. See ``LinkPreview``.
    public var preview: LinkPreview?

    public init(urlRaw: String, preview: LinkPreview? = nil) {
        self.urlRaw = urlRaw
        self.urlCanonical = URLCanonicaliser.canonicalise(urlRaw)
        self.canonicalSpecVersion = URLCanonicaliser.specVersion
        self.preview = preview
    }
}

/// Telegram's own resolved metadata for a link, as rendered in the web preview.
///
/// This is the floor `artanl`'s tier ladder builds on, and it arrives free in HTML we already
/// parse. It is **a snapshot Telegram took**, not a live read — hence `observedAt`.
public struct LinkPreview: Codable, Hashable, Sendable {
    public var siteName: String?
    public var title: String?
    public var description: String?
    /// The URL Telegram itself resolved the link to, which is sometimes already the destination
    /// of a shortener and sometimes another shortener.
    public var resolvedURL: String?
    public var observedAt: Date

    public init(siteName: String? = nil, title: String? = nil, description: String? = nil,
                resolvedURL: String? = nil, observedAt: Date) {
        self.siteName = siteName
        self.title = title
        self.description = description
        self.resolvedURL = resolvedURL
        self.observedAt = observedAt
    }
}
