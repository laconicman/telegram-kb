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
    public static let specVersion = 3

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
    /// host.
    ///
    /// This never resolves redirects. The join key is `effective_url` — see the spec's v2
    /// section: identity must not depend on I/O, or an unresolvable URL has no computable key. `nil` means "store `url_raw`, mark non-canonical" — it is not an error.
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

        // RFC 3986 §6.2.2.2 normalisation, applied to path and query values only. Not to the
        // host (already lowercased/punycoded) and not blindly to the whole string, because a
        // reserved octet like %2F must survive — decoding it would change what the URL means.
        // NB: the `percentEncoded*` variants, deliberately. `components.path` returns an
        // ALREADY-DECODED path, so reading it loses the reserved/unreserved distinction this
        // rule depends on — `%2F` arrives as `/` and re-encoding cannot tell them apart. Caught
        // by a test asserting `%2F` survives.
        components.percentEncodedPath = decodingUnreservedEscapes(components.percentEncodedPath)
        if let q = components.percentEncodedQuery {
            components.percentEncodedQuery = decodingUnreservedEscapes(q)
        }

        // Trailing slash: removed, and a bare "/" becomes empty.
        if components.percentEncodedPath.hasSuffix("/") && components.percentEncodedPath != "/" {
            components.percentEncodedPath.removeLast()
        } else if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }

        return components.string
    }

    /// Repeatedly decodes **well-formed, semicolon-terminated** HTML entities until stable.
    ///
    /// The semicolon requirement is the whole rule, and it fixes two opposite bugs found by
    /// diffing this implementation against `artanl`'s over the corpus — neither of which the 42
    /// hand-written fixtures caught:
    ///
    /// - **Ours:** `&#33;` was not decoded, so a literal `#` survived into parsing, became the
    ///   fragment delimiter, and step 8 discarded the rest of the path.
    ///   `…/Help&#33;-I&#39;m-becoming-Post-Junior` silently became `…/Help&` — 35 characters
    ///   gone, nothing thrown.
    /// - **Theirs:** a permissive decoder treated `&sect` (a real entity, no semicolon) inside
    ///   `&amp;sectionName` as one, producing `§ionName`.
    ///
    /// Decoding *everything* breaks the second; decoding only `&amp;` breaks the first. Requiring
    /// a semicolon fixes both, keeps the original `&amp;amp;` collapse working, and is the only
    /// form two languages can implement identically — "use your platform's entity decoder" is by
    /// construction different everywhere, which is how we arrived at opposite failures on
    /// adjacent URLs.
    static func decodingHTMLEntities(_ s: String, maxPasses: Int = 3) -> String {
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        ]
        var current = s
        for _ in 0..<maxPasses {
            var out = ""
            var rest = Substring(current)
            while let amp = rest.firstIndex(of: "&") {
                out += rest[rest.startIndex..<amp]
                let after = rest.index(after: amp)
                // A well-formed entity is `&…;` with no intervening `&` and a short body.
                guard let semi = rest[after...].prefix(12).firstIndex(of: ";") else {
                    out.append("&"); rest = rest[after...]; continue
                }
                let body = rest[after..<semi]
                var replacement: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    replacement = UInt32(body.dropFirst(2), radix: 16)
                        .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if body.hasPrefix("#") {
                    replacement = UInt32(body.dropFirst())
                        .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[String(body).lowercased()]
                }
                if let replacement, !body.isEmpty, !body.contains("&") {
                    out += replacement
                    rest = rest[rest.index(after: semi)...]
                } else {
                    out.append("&"); rest = rest[after...]
                }
            }
            out += rest
            if out == current { return current }
            current = out
        }
        return current
    }

    /// Decodes `%XX` escapes **only** where they encode an RFC 3986 *unreserved* character.
    ///
    /// RFC 3986 §6.2.2.2 makes this the sanctioned normalisation: percent-encoded unreserved
    /// octets are equivalent to their decoded form. §2.2 makes decoding *reserved* characters a
    /// semantic change instead — `%2F` is not `/` — so a blanket `unquote` is wrong, which is
    /// exactly the disagreement this rule settles.
    static func decodingUnreservedEscapes(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "%", let a = s.index(i, offsetBy: 1, limitedBy: s.endIndex),
                  let b = s.index(i, offsetBy: 2, limitedBy: s.endIndex), b < s.endIndex,
                  let value = UInt8(s[a...b], radix: 16),
                  let scalar = Unicode.Scalar(UInt32(value)).map(Character.init),
                  scalar.isLetter && scalar.isASCII || scalar.isNumber && scalar.isASCII
                    || "-._~".contains(scalar)
            else {
                out.append(s[i]); i = s.index(after: i); continue
            }
            out.append(scalar)
            i = s.index(i, offsetBy: 3)
        }
        return out
    }
}
