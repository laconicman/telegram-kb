import ArgumentParser
import Foundation
import MCP
import Testing
import TelegramKBModel
import TelegramKBStore
@testable import TelegramKBMCP
@testable import tgkb

/// The two binaries read the same arguments the same way (Design § *One argument grammar for
/// both binaries*).
///
/// The grammar has one definition — `Store.SearchFilter`, `Post.ID(reference:)`, `PostKind` — and
/// this pins each surface to it, because a surface that bypassed it would still build. Equal
/// filters are what make a cursor portable: its fingerprint covers the filter, so a `tgkb query`
/// that read `--to 2023-11-14` as an inclusive instant would have its cursors refused by
/// `tgkb_search_posts`, and the reverse.
struct ArgumentParityTests {

    /// The same filter arguments, as each binary takes them: `--key value` and `"key": "value"`.
    static let filters: [[String: String]] = [
        [:],
        ["channel": "iosgr"],
        ["channel": "@IOSGR"],
        ["channel": "@@iosgr"],
        ["kind": "poll"],
        ["kind": "videoNote"],
        ["from": "2023-11-14"],
        ["to": "2023-11-14"],
        ["from": "2023-11-14", "to": "2023-11-14"],
        ["to": "2023-11-14T23:59:59Z"],
        ["to": "2023-11-14T23:59:59.500Z"],
        ["from": "2023-11-14T10:00:00+03:00"],
        ["channel": "@iosgr", "kind": "text", "from": "2023-01-01", "to": "2023-12-31T12:00:00.250Z"],
    ]

    @Test("tgkb query and tgkb_search_posts build the same filter from the same arguments",
          arguments: filters)
    func filtersAgree(_ row: [String: String]) throws {
        let flags = row.sorted { $0.key < $1.key }.flatMap { ["--\($0.key)", $0.value] }
        let cli = try Query.parse(["swift"] + flags).filter
        let mcp = try TGKBServer.filter(Args(row.mapValues { .string($0) }))
        #expect(cli == mcp)
    }

    /// Agreement could also mean both are wrong the same way; this row says what right is.
    @Test("a date-only --to is everything before the next UTC day")
    func dateOnlyToIsTheWholeDay() throws {
        let filter = try Query.parse(["swift", "--to", "2023-11-14"]).filter
        #expect(filter.to == nil)
        #expect(filter.before == Date(timeIntervalSince1970: 1_700_006_400)) // 2023-11-15T00:00:00Z
    }

    static let refused: [(key: String, value: String)] = [
        ("kind", "bogus"), ("kind", "Poll"), ("from", "yesterday"), ("to", "2023-11-1"),
        ("to", "20231114"),
    ]

    @Test("both refuse the same malformed arguments", arguments: refused)
    func refusalsAgree(_ row: (key: String, value: String)) {
        #expect(throws: (any Error).self) { try Query.parse(["swift", "--\(row.key)", row.value]) }
        #expect(throws: ToolInputError.self) {
            try TGKBServer.filter(Args([row.key: .string(row.value)]))
        }
    }

    static let references = ["@iosgr/123", "iosgr/123", "t.me/IOSGR/123", "https://t.me/iosgr/123",
                             "http://t.me/iosgr/123", "  @iosgr/123  "]

    @Test("tgkb show takes every reference tgkb_get_post takes", arguments: references)
    func referencesAgree(_ reference: String) throws {
        #expect(try Show.parse([reference]).post == Post.ID(channelUsername: "iosgr", messageID: 123))
    }

    @Test("tgkb show refuses the references tgkb_get_post refuses",
          arguments: ["iosgr", "@@iosgr/123", "@bad name/1", "iosgr/0", "t.me/iosgr?x/1"])
    func malformedReferencesAgree(_ reference: String) {
        #expect(Post.ID(reference: reference) == nil)
        #expect(throws: (any Error).self) { try Show.parse([reference]) }
    }

    /// REVIEW.md: numeric options in `Sources/tgkb/` are checked in `validate()` — `Array.prefix`
    /// traps on a negative length. `links` gained `--limit` through the same option group.
    @Test("a negative --limit is refused by both paging subcommands")
    func negativeLimitIsRefused() {
        #expect(throws: (any Error).self) { try Query.parse(["swift", "--limit=-1"]) }
        #expect(throws: (any Error).self) { try Links.parse(["https://example.com/", "--limit=-1"]) }
    }
}
