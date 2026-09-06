import Foundation
import Testing
@testable import TelegramKBModel

struct ModelTests {

    static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(T.self, from: enc.encode(value))
    }

    @Test("Post round-trips through Codable")
    func postRoundTrip() throws {
        let post = Post(
            id: .init(channelUsername: "iosgr", messageID: 4744),
            date: Date(timeIntervalSince1970: 1_756_000_000),
            kind: .text, formatSource: .web,
            text: "Навигация в SwiftUI",
            authorName: "Alexander Kraev",
            hashtags: ["howto"],
            links: [LinkRef(urlRaw: "http://www.Swift.org/blog/?utm_source=tg")],
            reactions: [Reaction(emoji: "👍", count: 13), Reaction(emoji: nil, count: 8, isPaid: true)],
            views: ViewCount(value: 1700, isApproximate: true))
        #expect(try Self.roundTrip(post) == post)
    }

    /// The case that actually fails if albums are modelled as one post per message id.
    @Test("an album is ONE post spanning many message ids")
    func albumGrain() throws {
        // Real corpus album: @ios_broadcast/581 occupies ids 581-586, and 582-586 never
        // appear as posts. Modelling it as six posts is the reconciliation bug in TD-8.
        let album = Post(id: .init(channelUsername: "ios_broadcast", messageID: 581),
                         date: Date(timeIntervalSince1970: 1_650_000_000),
                         kind: .album, formatSource: .web, mediaCount: 6)
        #expect(album.isAlbum)
        #expect(album.mediaCount == 6)
        #expect(album.messageIDSpan == 581...586)
        #expect(!album.messageIDSpan.contains(587), "587 is the NEXT post, not part of this album")
        #expect(try Self.roundTrip(album) == album)

        let single = Post(id: .init(channelUsername: "iosgr", messageID: 100),
                          date: .init(), kind: .photo, formatSource: .web)
        #expect(!single.isAlbum)
        #expect(single.messageIDSpan == 100...100, "a normal post spans exactly itself")
    }

    @Test("LinkRef canonicalises on construction and stamps the spec version")
    func linkRefCanonicalises() {
        let link = LinkRef(urlRaw: "http://www.Habr.com/ru/post/1/?utm_source=tg#comments")
        #expect(link.urlRaw == "http://www.Habr.com/ru/post/1/?utm_source=tg#comments",
                "urlRaw must never be rewritten")
        #expect(link.urlCanonical == "https://habr.com/ru/post/1")
        #expect(link.canonicalSpecVersion == URLCanonicaliser.specVersion)
    }

    @Test("a non-canonicalisable link keeps its raw form and is marked")
    func linkRefNonCanonical() {
        let link = LinkRef(urlRaw: "mailto:a@b.com")
        #expect(link.urlCanonical == nil, "nil means 'store raw, mark non-canonical' — not an error")
        #expect(link.urlRaw == "mailto:a@b.com")
    }

    @Test("effectiveURL prefers a resolution and falls back to the canonical form")
    func effectiveURLJoinKey() {
        let canon = "https://clck.ru/33ABCD"
        #expect(effectiveURL(canon, resolution: nil) == canon,
                "never resolved -> the canonical form is the key")

        let dead = URLResolution(urlCanonical: canon, resolvedCanonical: nil,
                                 httpStatus: "404", hops: 0, resolvedAt: .init())
        #expect(effectiveURL(canon, resolution: dead) == canon,
                "resolution FAILED -> still keyed on canonical; a dead link must remain joinable to itself")

        let ok = URLResolution(urlCanonical: canon, resolvedCanonical: "https://habr.com/ru/post/1",
                               httpStatus: "200", hops: 2, resolvedAt: .init())
        #expect(effectiveURL(canon, resolution: ok) == "https://habr.com/ru/post/1")
    }

    @Test("tdlibChatID is arithmetic, and survives monoforum-scale ids")
    func chatIDArithmetic() {
        let c = Channel(username: "swiftui_dev", rawChannelID: 1_492_664_793)
        #expect(c.tdlibChatID == -1_001_492_664_793)
        #expect(String(c.tdlibChatID) == "-100" + String(c.rawChannelID),
                "ordinary channels coincide with the -100 text pattern")

        // Monoforum ids reach 3e12, where the string trick breaks and arithmetic does not.
        let mono = Channel(username: "x", rawChannelID: 3_000_000_000_000)
        #expect(mono.tdlibChatID == -4_000_000_000_000)
        #expect(String(mono.tdlibChatID) != "-100" + String(mono.rawChannelID))
    }

    @Test("totalReactions sums every bucket including paid")
    func reactionTotals() {
        let p = Post(id: .init(channelUsername: "a", messageID: 1), date: .init(),
                     kind: .text, formatSource: .web,
                     reactions: [Reaction(emoji: "👍", count: 13),
                                 Reaction(emoji: "🔥", count: 4),
                                 Reaction(emoji: nil, count: 8, isPaid: true)])
        #expect(p.totalReactions == 25)
    }

    @Test("every post yields a citable t.me permalink")
    func permalink() {
        let p = Post(id: .init(channelUsername: "iosgr", messageID: 4744), date: .init(),
                     kind: .text, formatSource: .web)
        #expect(p.permalink == "https://t.me/iosgr/4744")
    }
}
