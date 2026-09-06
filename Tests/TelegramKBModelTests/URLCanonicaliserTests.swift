import Foundation
import Testing
@testable import TelegramKBModel

/// Runs the co-owned seam contract, `Spec/url-canonical/fixtures.json`.
///
/// `artanl` runs the same file against its own implementation. A failure here means either this
/// implementation is wrong or the spec changed without a version bump — in both cases the join
/// key would silently stop joining (`TD-16`).
struct URLCanonicaliserContractTests {

    struct Fixture: Codable {
        let name: String
        let input: String
        let expected: String?     // nil = "not canonicalisable; store url_raw, mark non-canonical"
        let note: String?
    }

    static let fixtures: [Fixture] = {
        guard let url = Bundle.module.url(forResource: "url-canonical-fixtures", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Fixture].self, from: data)
        else { return [] }
        return decoded
    }()

    @Test("the fixture file is present and non-empty")
    func fixturesLoad() {
        #expect(!Self.fixtures.isEmpty, "Spec fixtures failed to load — the contract is not being tested")
    }

    @Test("spec version is recorded", arguments: [3])
    func specVersion(expected: Int) {
        #expect(URLCanonicaliser.specVersion == expected)
    }

    @Test("canonicalisation matches the shared spec", arguments: URLCanonicaliserContractTests.fixtures)
    func matchesSpec(fixture: Fixture) {
        let actual = URLCanonicaliser.canonicalise(fixture.input)
        #expect(
            actual == fixture.expected,
            """
            \(fixture.name)
              input:    \(fixture.input)
              expected: \(fixture.expected.map { "\"\($0)\"" } ?? "nil")
              actual:   \(actual.map { "\"\($0)\"" } ?? "nil")
            \(fixture.note.map { "  note:     \($0)" } ?? "")
            """
        )
    }

    @Test("canonicalisation is idempotent")
    func idempotent() {
        for f in Self.fixtures {
            guard let once = URLCanonicaliser.canonicalise(f.input) else { continue }
            #expect(URLCanonicaliser.canonicalise(once) == once,
                    "not idempotent for \(f.name): \(once) -> \(URLCanonicaliser.canonicalise(once) ?? "nil")")
        }
    }

    @Test("entity decoding is repeated until stable")
    func entityDecoding() {
        #expect(URLCanonicaliser.decodingHTMLEntities("a&amp;amp;b") == "a&b")
        #expect(URLCanonicaliser.decodingHTMLEntities("a&b") == "a&b")
    }
}

extension URLCanonicaliserContractTests.Fixture: CustomTestStringConvertible {
    var testDescription: String { name }
}
