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
        var seen = Set<String>()
        for url in formatted.entities.compactMap(Self.linkTarget)
        where Self.isWebURL(url) && seen.insert(url).inserted {
            links.append(LinkRef(urlRaw: url))
        }
        // The one scheme check for a preview: a card for a `tg:` or relative address is no link.
        if let webPage, Self.isWebURL(webPage.url) {
            let preview = LinkPreview(siteName: webPage.siteName, title: webPage.title,
                                      description: webPage.description, resolvedURL: webPage.url,
                                      observedAt: observedAt)
            if let i = links.firstIndex(where: { $0.urlRaw == webPage.url }) {
                links[i].preview = preview
            } else {
                links.append(LinkRef(urlRaw: webPage.url, preview: preview))
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

    /// Only an absolute `http(s)` address is a link — from the text and from a preview alike.
    ///
    /// Public so a parser's markup mapping recognises a link by the same rule this type records it by.
    public static func isWebURL(_ address: String) -> Bool {
        address.hasPrefix("http://") || address.hasPrefix("https://")
    }
}
