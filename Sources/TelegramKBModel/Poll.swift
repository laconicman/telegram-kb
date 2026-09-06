import Foundation

/// A poll attached to a post.
///
/// The question and options are **indexed as text**: they are free text we would otherwise
/// discard, and the question is often a better statement of the topic than the post around it.
public struct Poll: Codable, Hashable, Sendable {
    public var question: String
    public var options: [String]
    public var totalVotes: Int?

    public init(question: String, options: [String], totalVotes: Int? = nil) {
        self.question = question
        self.options = options
        self.totalVotes = totalVotes
    }
}
