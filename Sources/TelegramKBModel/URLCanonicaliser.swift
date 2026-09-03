import Foundation

/// Canonicalises a URL string for use as the `url_canonical` join key.
///
/// This is the Swift half of a **co-owned contract**: `Spec/url-canonical/SPEC.md` defines the
/// algorithm and `Spec/url-canonical/fixtures.json` is run by both this repository and `artanl`.
/// Divergence between the two implementations is a test failure, not a discovery — see `TD-16`.
///
/// Canonicalisation is **pure and total**: no network, no throwing, no `nil` for well-formed
/// input. Following redirects is a separate step whose *output* is fed to this one, deliberately
/// kept outside the contract so the fixtures can run in CI on both sides with no network.
public enum URLCanonicaliser {

    /// The spec version this implementation satisfies. Store it beside every canonical value so
    /// a spec revision is a recompute over `url_raw` rather than a re-crawl.
    public static let specVersion = 1

    /// Query parameters removed during canonicalisation.
    ///
    /// A **denylist**, never an allowlist. `v` alone occurs 416 times in the corpus and is
    /// YouTube's video identity; an allowlist would collapse every YouTube link onto
    /// `youtube.com/watch`. Unknown parameters are always kept.
    /// Any parameter whose name starts with one of these is removed.
    ///
    /// `utm_` is a prefix rather than an enumeration because the corpus contains `utm_refcode`,
    /// which an enumerated list missed — and because a percent-mangled `utm_campaign%3D…` (a
    /// real corpus URL where `=` was encoded) is only caught by prefix matching.
    static let trackingPrefixes: [String] = ["utm_"]

    static let trackingParameters: Set<String> = [
        "ssource",      // Habr — 152 corpus occurrences
        "share", "startapp",  // Telegram — 109
        "ref", "referrer", "referer",
        "fbclid", "gclid", "yclid", "dclid", "msclkid", "twclid", "igshid",
        "_openstat", "mc_cid", "mc_eid", "spm", "at_medium", "at_campaign",
        "si",           // YouTube share token
        "s",            // X/Twitter share token
    ]

    /// Returns the canonical form, or `nil` when `raw` is not an absolute http(s) URL with a
    /// host. `nil` means "store `url_raw`, mark non-canonical" — it is not an error.
    public static func canonicalise(_ raw: String) -> String? {
        let decoded = decodingHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)

        guard var components = URLComponents(string: decoded),
              let host = components.host, !host.isEmpty,
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        components.scheme = "https"                     // http -> https
        components.fragment = nil                       // strip fragment

        // NB: `URLComponents` converts an internationalised host to punycode
        // (`радом.орг` -> `xn--80aiyhh.xn--c1avg`). That is the right canonical form, and two
        // such hosts appear in the corpus — but Python's `urlsplit` does *not* do it, so this is
        // a live cross-language divergence risk. Covered by a fixture.
        var normalisedHost = host.lowercased()
        if normalisedHost.hasPrefix("www.") {
            normalisedHost.removeFirst(4)
        }
        components.host = normalisedHost

        if components.port == 80 || components.port == 443 { components.port = nil }

        if let items = components.queryItems {
            let kept = items
                .filter { item in
                    let name = item.name.lowercased()
                    if trackingParameters.contains(name) { return false }
                    return !trackingPrefixes.contains { name.hasPrefix($0) }
                }
                .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            components.queryItems = kept.isEmpty ? nil : kept
        }

        // Trailing slash: removed, and a bare "/" becomes empty.
        if components.path.hasSuffix("/") && components.path != "/" {
            components.path.removeLast()
        } else if components.path == "/" {
            components.path = ""
        }

        return components.string
    }

    /// Repeatedly decodes HTML entities until stable, at most `maxPasses` times.
    ///
    /// Real corpus hrefs contain `&amp;amp;` (412 occurrences). Without repeated decoding those
    /// yield query parameters literally named `amp;amp;utm_medium`, which then fail to match the
    /// tracking denylist and survive into the canonical form.
    static func decodingHTMLEntities(_ s: String, maxPasses: Int = 3) -> String {
        var current = s
        for _ in 0..<maxPasses {
            let next = current
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            if next == current { return current }
            current = next
        }
        return current
    }
}
