/// The link-preview card a message carries, as its source rendered it — the fields of TDLib's
/// `linkPreview` that this package keeps.
///
/// Named `WebPage`, the name MTProto and tdesktop give it (TDLib's was `webPage` until it became
/// `linkPreview`), because ``LinkPreview`` is already taken by the snapshot a post stores —
/// which ``PostText`` derives from this.
public struct WebPage: Hashable, Sendable {
    /// The address the card previews, as the source wrote it.
    public var url: String
    public var siteName: String?
    public var title: String?
    public var description: String?

    public init(url: String, siteName: String? = nil, title: String? = nil, description: String? = nil) {
        self.url = url
        self.siteName = siteName
        self.title = title
        self.description = description
    }
}
