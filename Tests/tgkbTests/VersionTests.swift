import Testing
@testable import tgkb

/// `tgkb --version` prints what the StampVersion plugin generated for this build (#12). That the two
/// binaries agree, and name the tree they were built from, is `Scripts/check-invariants.sh`'s check:
/// it needs both built executables and the repository, which a unit test has neither of.
struct VersionTests {

    @Test("--version is the generated build version: the package version, then the commit")
    func versionIsTheBuildStamp() throws {
        #expect(TGKB.configuration.version == BuildVersion.string)
        let stamp = try #require(BuildVersion.string.wholeMatch(of: /(\d+\.\d+\.\d+)\+(.+)/))
        #expect(stamp.output.2.wholeMatch(of: /[0-9a-f]{7,}(-dirty)?|unknown/) != nil,
                "a short commit hash, -dirty for a changed tree, or unknown without git")
    }
}
