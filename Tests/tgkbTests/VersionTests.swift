import Foundation
import Testing
@testable import tgkb

/// `tgkb --version` prints what the StampVersion plugin generated for this build, by the one rule in
/// `Scripts/build-version.sh` (#12). That the two built binaries agree, and carry what the rule gives
/// for the tree now, is `Scripts/check-invariants.sh`'s check; the rule's own cases are here.
struct VersionTests {

    @Test("--version is the generated build version: the package version, then the commit")
    func versionIsTheBuildStamp() throws {
        #expect(TGKB.configuration.version == BuildVersion.string)
        let stamp = try #require(BuildVersion.string.wholeMatch(of: /(\d+\.\d+\.\d+)\+(.+)/))
        #expect(stamp.output.2.wholeMatch(of: /[0-9a-f]{7,}(-dirty)?|unknown/) != nil,
                "a short commit hash, -dirty for a changed tree, or unknown without git")
    }

    /// 🟡 Run inside an unpacked archive that sat in some other checkout, the rule named that
    /// checkout's commit, because `git -C` walks up to the nearest repository (Devin Review, #19).
    /// Then, with the rule written twice, the plugin and the invariant check disagreed about a
    /// repository with no commit yet. One rule now, and these are its cases — including the
    /// untracked directory a tool leaves at the root, which the plugin's git, blind to the user's
    /// global ignore file, once counted as a change.
    @Test("the stamp names the tree it is given: its commit, -dirty, or unknown — never another's")
    func stampRuleNamesTheTree() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgkb-stamp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let repo = scratch.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        try Self.git(["init", "-q"], in: repo)
        try Data("a".utf8).write(to: repo.appendingPathComponent("file"))
        #expect(try Self.stamp(repo) == "unknown", "no commit yet, so nothing to be dirty against")

        try Self.git(["add", "file"], in: repo)
        try Self.git(["commit", "-qm", "one"], in: repo)
        let hash = try Self.git(["rev-parse", "--short", "HEAD"], in: repo)
        #expect(try Self.stamp(repo) == hash)

        let tool = repo.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: tool, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tool.appendingPathComponent("settings.local.json"))
        #expect(try Self.stamp(repo) == hash, "an untracked file SwiftPM never compiles is no change")

        let sources = repo.appendingPathComponent("Sources/tool")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: sources.appendingPathComponent("Untracked.swift"))
        #expect(try Self.stamp(repo) == "\(hash)-dirty", "an untracked source is compiled all the same")
        try FileManager.default.removeItem(at: sources)

        try Data("changed".utf8).write(to: repo.appendingPathComponent("file"))
        #expect(try Self.stamp(repo) == "\(hash)-dirty", "a tracked file changed anywhere is a change")
        try Self.git(["checkout", "--", "file"], in: repo)

        let worktree = scratch.appendingPathComponent("worktree")
        try Self.git(["worktree", "add", "-q", worktree.path], in: repo)
        #expect(try Self.stamp(worktree) == hash, "a linked worktree is its own package root")

        let archive = repo.appendingPathComponent("vendor/archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        #expect(try Self.stamp(archive) == "unknown", "an archive inside a checkout is not its commit")
    }

    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scripts/build-version.sh")

    /// What the rule puts after the package version's `+`.
    static func stamp(_ package: URL) throws -> String {
        let version = try run(["sh", script.path, package.path], in: package)
        let parts = version.split(separator: "+", maxSplits: 1)
        try #require(parts.count == 2 && parts[0].wholeMatch(of: /\d+\.\d+\.\d+/) != nil,
                     "\(version.debugDescription) is not <version>+<build>")
        return String(parts[1])
    }

    /// Git with the test's own identity and none of the user's configuration — a signing or hook
    /// setting there must not decide what these repositories look like.
    @discardableResult
    static func git(_ arguments: [String], in directory: URL) throws -> String {
        try run(["git"] + arguments, in: directory)
    }

    static func run(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0",
            "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        ]) { _, override in override }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read before waiting: a full pipe would otherwise block the child, and the wait with it.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(arguments.joined(separator: " ")) failed")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
