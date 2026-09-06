import Foundation

/// One reaction bucket on a post: an emoji (or a paid star) and its count.
public struct Reaction: Codable, Hashable, Sendable {
    /// `nil` for paid/star reactions, which render with no emoji and no sprite URL.
    public var emoji: String?
    public var count: Int
    public var isPaid: Bool

    public init(emoji: String?, count: Int, isPaid: Bool = false) {
        self.emoji = emoji
        self.count = count
        self.isPaid = isPaid
    }
}
