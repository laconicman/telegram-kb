import Foundation

/// The result of following a URL's redirects — **an observation with a timestamp, not a fact.**
///
/// Resolution deliberately does not mutate ``LinkRef/urlCanonical``. Three reasons, and the third
/// is the one that decides it:
///
/// 1. Identity must not depend on I/O, or an unresolvable URL has no computable key. Dead
///    shorteners are real: `bit.ly/3ARSuTJ` returns 404.
/// 2. Resolution is time-varying, so the key would be too — two crawls of one post could yield
///    two keys, a silent divergence *inside* this store.
/// 3. A pure key is recomputable; a resolved key is not. Folding resolution into the key would
///    break the spec's own promise that a revision is a recompute over `urlRaw`.
///
/// The join key is ``effectiveURL(_:resolution:)``.
public struct URLResolution: Codable, Hashable, Sendable {
    /// The canonical URL that was resolved. Primary key.
    public var urlCanonical: String

    /// Canonicalised final URL, or `nil` when resolution failed — dead link, timeout, 4xx.
    /// `nil` is a recorded outcome, distinct from "never attempted", which is an absent row.
    public var resolvedCanonical: String?

    /// HTTP status, or a transport error name (`"URLError"`, `"TooManyRedirects"`).
    public var httpStatus: String?
    public var hops: Int
    public var resolvedAt: Date
    /// Spec version of the canonicalisation applied to `resolvedCanonical`.
    public var canonicalSpecVersion: Int

    public init(urlCanonical: String, resolvedCanonical: String?, httpStatus: String?,
                hops: Int, resolvedAt: Date,
                canonicalSpecVersion: Int = URLCanonicaliser.specVersion) {
        self.urlCanonical = urlCanonical
        self.resolvedCanonical = resolvedCanonical
        self.httpStatus = httpStatus
        self.hops = hops
        self.resolvedAt = resolvedAt
        self.canonicalSpecVersion = canonicalSpecVersion
    }
}

/// The **join key** shared with `artanl`: the resolved form when known, else the canonical form.
///
/// `COALESCE(resolution.resolved_canonical, url_canonical)`. Both sides join on this; where both
/// hold a resolution and they disagree, that is a reportable condition rather than a silent miss.
public func effectiveURL(_ urlCanonical: String, resolution: URLResolution?) -> String {
    resolution?.resolvedCanonical ?? urlCanonical
}
