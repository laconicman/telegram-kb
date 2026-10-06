/// A message's text and the typed entities in it — TDLib's `formattedText` (`td_api.tl`).
///
/// **The seam every source shares.** The two HTML sources come from different code: `t.me/s` is
/// rendered server-side, the chat export by a Telegram client (tdesktop's
/// `export_output_html.cpp`, which the macOS client reimplements). Both render the same MTProto
/// message — its text, a list of typed entities, media and a link preview — and TDLib hands the
/// same model over as `formattedText`. So a parser's job is to map its markup onto this value, and
/// ``PostText`` derives a post's fields from it by one rule, whichever source it came from.
///
/// Named after TDLib's `formattedText` rather than `messageText`: TDLib's `messageText` is the
/// message *content* — a `formattedText` plus its link preview — and TDLibKit exports both names,
/// so one name meaning two shapes would meet in the module that maps between them.
public struct FormattedText: Hashable, Sendable {
    public var text: String
    /// In the order they occur in ``text``.
    public var entities: [TextEntity]

    public init(text: String, entities: [TextEntity] = []) {
        self.text = text
        self.entities = entities
    }
}

/// One typed span of a message's text — TDLib's `textEntity`, without its offsets yet.
public struct TextEntity: Hashable, Sendable {
    public var type: TextEntityType

    /// The text the entity covers, as the message shows it: `#tag`, `@name`, `https://example.com`.
    ///
    /// It stands in for TDLib's `offset` and `length` until those are added. When they are, they
    /// count **UTF-16 code units**, as TDLib's do (`td_api.tl`, `textEntity`) — not `Character`s or
    /// Unicode scalars, which is what Swift counts by default and which disagree with UTF-16 on
    /// every character outside the Basic Multilingual Plane, emoji included.
    public var text: String

    public init(_ type: TextEntityType, text: String) {
        self.type = type
        self.text = text
    }
}

/// The kinds of entity a post's fields are derived from: the subset of TDLib's `TextEntityType`
/// that names, tags or links something. Formatting — bold, code, spoilers — is not modelled.
///
/// Cases mirror TDLib's (`textEntityTypeMention`, …), payloads included, with one addition: a
/// mention carries its username (see ``mention(username:)``).
public enum TextEntityType: Hashable, Sendable {
    /// `@username`.
    ///
    /// The username as the source links it, without the `@`. TDLib's type carries nothing, because
    /// its covered text is the username; an HTML source links the mention to `t.me/<username>`, and
    /// that address — not the text shown, whose case may differ — is what ``PostText`` records.
    case mention(username: String)
    /// `#tag`. The covered text starts with `#`.
    case hashtag
    /// `$USD`. The covered text starts with `$`.
    case cashtag
    /// `/start`.
    case botCommand
    /// An address written out in the text: the covered text is the URL.
    case url
    case emailAddress
    case phoneNumber
    /// A link whose text is not its address — TDLib's `textEntityTypeTextUrl`.
    case textURL(href: String)
    /// A mention of a user who may have no username. TDLib's carries the user's id; neither HTML
    /// source writes one (tdesktop's message text renders `ShowMentionName()` with no argument), so
    /// this carries nothing.
    case mentionName
}
