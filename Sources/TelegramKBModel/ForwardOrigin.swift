import Foundation

/// Where a forwarded post came from.
///
/// The web preview supplies all three fields, which is what makes the "author/sender" search
/// dimension work for forwarded content — and a great deal of shared material arrives forwarded.
public struct ForwardOrigin: Codable, Hashable, Sendable {
    /// Origin channel `@username`, without the `@`. `nil` when the origin is a user, not a channel.
    public var channelUsername: String?
    /// Message id in the *origin* channel, not ours.
    public var messageID: Int?
    /// Display name shown as the original author.
    public var authorName: String?

    public init(channelUsername: String? = nil, messageID: Int? = nil, authorName: String? = nil) {
        self.channelUsername = channelUsername
        self.messageID = messageID
        self.authorName = authorName
    }
}
