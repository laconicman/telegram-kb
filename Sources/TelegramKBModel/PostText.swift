import Foundation

/// A post's text fields — ``Post/text``, ``Post/hashtags`` and ``Post/links`` — and the one rule
/// that derives them from a message's ``FormattedText`` and ``WebPage``.
///
/// Every source goes through this initialiser; a parser only maps its markup onto the typed
/// values. The two HTML parsers used to derive these fields each by their own copy of the rules,
/// and the copies had drifted: only the export's checked a preview URL's scheme (`TD-26`).
public struct PostText: Hashable, Sendable {
    public var text: String
    /// Every hashtag entity's tag, without the `#`, in text order — repeats kept.
    public var hashtags: [String]
    /// Every web address the text links to, each once, in text order; then the preview's address,
    /// carrying the preview — attached to the matching link, or added as its own.
    public var links: [LinkRef]

    /// - Parameter observedAt: when the source rendered the preview — see ``LinkPreview/observedAt``.
    public init(_ formatted: FormattedText, webPage: WebPage?, observedAt: Date) {
        text = formatted.text
        hashtags = formatted.entities.compactMap { entity in
            guard case .hashtag = entity.type else { return nil }
            return String(entity.text.dropFirst())
        }

        var links: [LinkRef] = []
        var indexByURL: [String: Int] = [:]
        for entity in formatted.entities {
            guard let url = Self.linkTarget(of: entity), Self.isWebURL(url) else { continue }
            let autoLink = Self.isAutoLink(of: entity)
            // Links dedup by URL, first occurrence kept — but the flag upgrades: any
            // bare-address showing means the source linkified the address, whatever the
            // other showings of it looked like.
            if let i = indexByURL[url] {
                if autoLink { links[i].isAutoLink = true }
                continue
            }
            indexByURL[url] = links.count
            links.append(LinkRef(urlRaw: url, isAutoLink: autoLink))
        }
        // The one scheme check for a preview: a card for a `tg:` or relative address is no link.
        if let webPage, Self.isWebURL(webPage.url) {
            let preview = LinkPreview(siteName: webPage.siteName, title: webPage.title,
                                      description: webPage.description, resolvedURL: webPage.url,
                                      observedAt: observedAt)
            if let i = links.firstIndex(where: { $0.urlRaw == webPage.url }) {
                links[i].preview = preview
            } else {
                // A preview's address is no link the text made — `false`, not `nil`:
                // the source did say, and what it said is "not an auto-link".
                links.append(LinkRef(urlRaw: webPage.url, preview: preview, isAutoLink: false))
            }
        }
        self.links = links
    }

    /// The address an entity links to, when it links anywhere.
    static func linkTarget(of entity: TextEntity) -> String? {
        switch entity.type {
        case .url: entity.text
        case .textURL(let href): href
        // A mention is recorded as a link to its `t.me` page, as both parsers always recorded it.
        // Deliberate, and temporary: moving mentions to a field of their own is a separate
        // decision and a separate change (`TD-26`), and until it lands this is how a search for a
        // mentioned channel finds the post.
        case .mention(let username): "https://t.me/\(username)"
        case .hashtag, .cashtag, .botCommand, .emailAddress, .phoneNumber, .mentionName: nil
        }
    }

    /// Whether the entity's visible text was the bare address — `build.sh`, `example.com` —
    /// for the source to have linkified, rather than prose over the link (`the docs`) or
    /// the full address typed with its scheme. "With its scheme" means a scheme at the
    /// head: `example.com/?u=https://x` is still a bare address — its `://` is in the query.
    ///
    /// The markup cannot say it outright: both HTML renderers prepend a scheme to an
    /// address written without one, so a bare `build.sh` lands in `.textURL` beside a
    /// genuine hidden link (`EntityMarkup.link`). The signature is the covered text
    /// canonicalising to the href's own canonical form — `https://` is supplied for the
    /// text because ``URLCanonicaliser`` reads absolute URLs only, and every
    /// normalisation the renderer applied (scheme, trailing slash, host case, `www.`,
    /// IDN) is one the canonicaliser already undoes. That makes the comparison
    /// tracking-parameter-insensitive too — accepted, since it lands in the same
    /// false-positive class as the hidden-link residue below. A hidden link whose text
    /// reads like its own address compares equal as well; that residue is accepted
    /// (issue #13). `.url` and `.mention` are `false`: for the HTML sources `.url` always
    /// shows the full address, and a mention's text is not an address. A TDLib `url`
    /// entity can cover schemeless text — an auto-link the entity type names outright —
    /// which is why a TDLib source sets the flag from the entity type instead (`TD-26`).
    static func isAutoLink(of entity: TextEntity) -> Bool {
        guard case .textURL(let href) = entity.type,
              !Self.hasLeadingScheme(entity.text),
              let target = URLCanonicaliser.canonicalise(href)
        else { return false }
        return URLCanonicaliser.canonicalise("https://" + entity.text) == target
    }

    /// Whether the visible text opens with a URI scheme — `https://x` typed out is a
    /// deliberate share, while `x.test/?u=https://y` is still a bare address: its `://`
    /// sits in the query, not at the head. A scheme is `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`
    /// followed by `://` (RFC 3986).
    static func hasLeadingScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon]
        return scheme.first?.isLetter == true
            && scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
            && text[text.index(after: colon)...].hasPrefix("//")
    }

    /// Only an absolute `http(s)` address is a link — from the text and from a preview alike.
    ///
    /// Public so a parser's markup mapping recognises a link by the same rule this type records it by.
    public static func isWebURL(_ address: String) -> Bool {
        address.hasPrefix("http://") || address.hasPrefix("https://")
    }
}
