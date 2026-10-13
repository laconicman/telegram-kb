import Foundation
import PackagePlugin

/// Stamps the build it runs in: generates `BuildVersion.string`, the package version plus the commit
/// the tree was built from — `0.1.0+539cf51`, with `-dirty` when the tree had changes. Both
/// executables use it, so `tgkb --version`, `tgkb-mcp --version`, `serverInfo.version` and
/// `tgkb doctor` print one string (<doc:Design> § *Every build says which commit it is*).
///
/// The rule, and the package version, are `Scripts/build-version.sh`'s: this only runs it, so the
/// plugin and `Scripts/check-invariants.sh`, which checks the binaries against the same script,
/// cannot disagree about what a tree is called.
///
/// A **prebuild** command, so it runs before every build and a new commit or an edit shows up on an
/// incremental one. The script runs the system `git` — a prebuild command cannot use a tool built
/// from this package — inside SwiftPM's plugin sandbox, which allows reads anywhere, so a worktree
/// whose `.git` points outside the package works too. `GIT_OPTIONAL_LOCKS=0` keeps `git status`
/// from trying to refresh the index, a write the sandbox would refuse.
///
/// Each executable target runs it, within one build; a tree edited between the two runs could give
/// them different strings, which `Scripts/check-invariants.sh` reports.
@main
struct StampVersion: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let package = context.package.directoryURL
        let output = context.pluginWorkDirectoryURL.appending(path: "generated")
        return [.prebuildCommand(
            displayName: "Stamp the build version into \(target.name)",
            executable: URL(filePath: "/bin/sh"),
            arguments: [package.appending(path: "Scripts/build-version.sh").path, package.path, output.path],
            environment: ["GIT_OPTIONAL_LOCKS": "0"],
            outputFilesDirectory: output)]
    }
}
