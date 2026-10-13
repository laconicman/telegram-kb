import ArgumentParser
import Foundation
import TelegramKBModel
import TelegramKBStore

/// One post in full — `tgkb_get_post`: its whole text, the links with Telegram's previews of
/// them, and the reactions. `query` and `links` print compact records; this is the follow-up.
struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print one post in full: its text, links with their previews, and reactions.")

    @OptionGroup var store: StoreOptions

    @Argument(help: ArgumentHelp(
        "The post: its t.me link, as query and links print it, or @channel/id.",
        valueName: "post"))
    var post: Post.ID

    func run() async throws {
        let db = try Store.openForReading(at: store.databasePath)
        guard let found = try db.post(post) else {
            FileHandle.standardError.write(Data("""
                no post @\(post.channelUsername)/\(post.messageID) in the store — take it from a \
                tgkb query or tgkb links result\n
                """.utf8))
            throw ExitCode(1)
        }
        print(Self.render(found))
    }

    static func render(_ p: Post) -> String {
        var meta = [p.date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
                    p.isAlbum ? "\(p.kind.rawValue) of \(p.mediaCount)" : p.kind.rawValue]
        if p.isEdited { meta.append("edited") }
        if let reply = p.replyTo { meta.append("reply to https://t.me/\(p.id.channelUsername)/\(reply)") }
        if let views = p.views { meta.append("\(views.isApproximate ? "≈" : "")\(views.value) views") }

        var lines = [p.permalink, meta.joined(separator: " · ")]
        if let author = p.authorName { lines.append("by \(author)") }
        if !p.text.isEmpty { lines += ["", p.text] }
        if let poll = p.poll {
            lines += ["", "Poll: \(poll.question)"]
            lines += poll.options.map { "  • \($0)" }
            if let votes = poll.totalVotes { lines.append("  \(votes) vote(s)") }
        } else if p.text.isEmpty {
            lines += ["", "[\(p.kind.rawValue), no text]"]
        }
        if let forward = p.forward {
            let origin = forward.channelUsername.map { channel in
                forward.messageID.map { "https://t.me/\(channel)/\($0)" } ?? "@\(channel)"
            }
            let from = [origin, forward.authorName.map { "by \($0)" }].compactMap { $0 }
            if !from.isEmpty { lines += ["", "Forwarded from \(from.joined(separator: " "))"] }
        }
        if !p.links.isEmpty {
            lines += ["", "Links:"]
            for link in p.links {
                lines.append("  • \(link.urlRaw)")
                guard let preview = link.preview else { continue }
                let heading = [preview.siteName, preview.title].compactMap { $0 }
                if !heading.isEmpty { lines.append("      \(heading.joined(separator: " — "))") }
                if let description = preview.description { lines.append("      \(description)") }
                // Telegram's own resolution, from the preview it rendered — not this store's.
                if let resolved = preview.resolvedURL, resolved != link.urlRaw {
                    lines.append("      preview resolved to \(resolved)")
                }
            }
        }
        if !p.reactions.isEmpty {
            let buckets = p.reactions.map { "\($0.emoji ?? "★") \($0.count)\($0.isPaid ? " paid" : "")" }
            lines += ["", "Reactions: \(buckets.joined(separator: "  ")) — \(p.totalReactions) in all"]
        }
        if !p.hashtags.isEmpty {
            lines.append("Hashtags: " + p.hashtags.map { "#\($0)" }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}

// `Post.ID(reference:)` is the grammar `tgkb_get_post` shares; this only adapts it.
extension Post.ID: ExpressibleByArgument {
    public init?(argument: String) { self.init(reference: argument) }
}
