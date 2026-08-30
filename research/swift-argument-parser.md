# apple/swift-argument-parser — research notes

Probe date: 2026-08-23. Source citations against tag **`1.8.2`**
(`https://raw.githubusercontent.com/apple/swift-argument-parser/1.8.2/...`).

---

## Verdict / what this means for us

1. **Pin `1.8.2`** (2026-06-04; confirmed by the API as `releases/latest`). Use
   `.upToNextMinor(from: "1.8.2")` — the project ships breaking-ish behavior in minors and
   also back-patches old lines (`1.7.2` was published 2026-07-08, *after* `1.8.2`), so
   `upToNextMajor` on a `1.x` is looser than it looks.
2. **Root `Tgkb` conforms to `AsyncParsableCommand`, not `ParsableCommand`**, because
   `serve` and `sync` are async. Rule from the official article, verbatim: "For the root
   command in your command-line tool, declare conformance to `AsyncParsableCommand`,
   **whether or not that command uses asynchronous code**." Subcommands conform
   individually — `query`/`doctor` can stay sync `ParsableCommand`, they will still run.
3. **The `@main` pitfall applies and is trivially avoidable: our root command must NOT live
   in a file named `main.swift`.** Name the file `Tgkb.swift`. Verified from the docs and
   the compiler rule they cite (see below).
4. **`@OptionGroup` is the sharing mechanism** — define a `ParsableArguments` struct
   (`GlobalOptions`: `--db`, `--verbose`, `--config`) and splat it into every subcommand.
   It contributes no new command; it "splats in the arguments defined by another
   `ParsableArguments` type".
5. **Exit codes we get for free:** `0` success, `EXIT_FAILURE` (1) for any thrown error,
   **`EX_USAGE` (64)** for a `ValidationError` or parse failure on macOS/Linux. `ExitCode`
   is `RawRepresentable<Int32>` so we can define our own domain codes for `doctor`.
6. **Completions ship built-in** — `tgkb --generate-completion-script zsh|bash|fish`.
   Notable for us: `CompletionKind.custom` has an **async** overload, so
   `tgkb query --channel <TAB>` can complete channel names by querying our SQLite index.
7. `serve` needs no special treatment beyond `AsyncParsableCommand` — but see the note on
   `print`/stdout at the bottom, which is where SAP and the MCP stdio constraint collide.

---

## Verified

### Version

`repos/apple/swift-argument-parser/releases/latest` → **`1.8.2`, 2026-06-04**.
Tag list (newest first): `1.8.2, 1.8.1, 1.8.0, 1.7.2, 1.7.1, 1.7.0, 1.6.2, …`.
Watch out: the *releases* feed is ordered by publish date and shows `1.7.2` published
2026-07-08, i.e. a maintenance backport landed after `1.8.2`. Read tags, not the feed.

### Subcommand structure — `Documentation.docc/Articles/CommandsAndSubcommands.md`

The canonical shape, applied to us:

```swift
// File: Sources/tgkb/Tgkb.swift   ← NOT main.swift
import ArgumentParser

@main
struct Tgkb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tgkb",
        abstract: "Local knowledge base over Telegram channel posts.",
        version: "0.1.0",
        subcommands: [Login.self, Sync.self, Query.self, Doctor.self, Serve.self],
        defaultSubcommand: nil
    )
}
```

`CommandConfiguration`'s public surface (`Parsable Types/CommandConfiguration.swift`):
`commandName`, `abstract`, `usage`, `discussion`, `version`, `shouldDisplay`,
`subcommands` (computed), `ungroupedSubcommands`, `groupedSubcommands: [CommandGroup]`,
`defaultSubcommand`, `helpNames`, `aliases`.

- Setting `version:` gives us `--version` for free.
- `aliases: ["mul"]` exists per-subcommand — useful if we want `tgkb q` for `query`.
- **`groupedSubcommands: [CommandGroup]`** is worth knowing about: five subcommands is
  under the threshold where grouping helps, but if `login`/`sync` later grow siblings we
  can group them in help output without restructuring the tree.

### `ParsableCommand` vs `AsyncParsableCommand`

`Parsable Types/AsyncParsableCommand.swift`:

```swift
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public protocol AsyncParsableCommand: ParsableCommand {
    mutating func run() async throws
}
```

Its `static func main() async` does the dispatch, and — important — it handles a **mixed
tree** correctly:

```swift
public static func main(_ arguments: [String]?) async {
    do {
        var command = try await asyncParseAsRoot(arguments)
        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
    } catch {
        exit(withError: error)
    }
}
```

So: root async, subcommands whichever they need to be. `Query` and `Doctor` as plain
`ParsableCommand` is fine and costs nothing.

`mutating func run()` — commands are value types mutated in place after parsing. Not a
place to hold an actor reference across suspension points casually; build your services
*inside* `run()`.

### The `@main` pitfall — verified, primary source

`Documentation.docc/Extensions/AsyncParsableCommand.md`, step 2:

> Apply the `@main` attribute to the root command. (Note: If your root command is in a
> `main.swift` file, rename the file to the name of the command.)

and the explicit note:

> The Swift compiler uses either the type marked with `@main` or a `main.swift` file as the
> entry point for an executable program. You can use either one, but not both — rename your
> `main.swift` file to the name of the command when you add `@main`.

**Practical rule for our SwiftPM layout:** `Sources/tgkb/Tgkb.swift` with `@main`, and
*no* `main.swift` anywhere in that target. If you ever see
`'main' attribute cannot be used in a module that contains top-level code`, this is why.

The old `AsyncMainProtocol` workaround (Swift 5.5 era) is still in the source but is
`@available(swift, deprecated: 5.6, message: "Use @main directly on your root
AsyncParsableCommand type.")`. **Do not use it.** Any tutorial showing
`@main struct AsyncMain: AsyncMainProtocol { typealias Command = … }` is stale.

### Sharing options — `@OptionGroup`

From the same article:

> `@OptionGroup` doesn't define any new arguments for a command; instead, it splats in the
> arguments defined by another `ParsableArguments` type.

Applied to us:

```swift
struct GlobalOptions: ParsableArguments {
    @Option(name: [.customLong("db")], help: "Path to the SQLite index.")
    var databasePath: String = FileManager.default
        .homeDirectoryForCurrentUser.appending(path: ".tgkb/index.sqlite").path

    @Flag(name: .shortAndLong, help: "Verbose diagnostics on stderr.")
    var verbose = false
}

extension Tgkb {
    struct Query: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search the index.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "FTS5 MATCH expression.") var pattern: String
        mutating func run() throws { … }
    }
}
```

`ParsableArguments` types parse but do not execute (no `run()`) — exactly what a shared
options bag should be.

Also present in 1.8.2 and worth knowing: `Parsable Properties/ParentCommand.swift`
(a `@ParentCommand` property wrapper for reaching the enclosing command's parsed values)
and `@OptionGroup`'s visibility control via `ArgumentVisibility`
(`.default`, `.hidden`, `.private`) — used to keep an option out of help output.

### Exit codes and error presentation — `Parsable Properties/Errors.swift`

```swift
public struct ValidationError: Error, CustomStringConvertible {
    public init(_ message: String)   // message shown to the user, alongside usage
}

public struct ExitCode: Error, RawRepresentable, Hashable {
    public var rawValue: Int32
    public init(_ code: Int32)
    public static let success            = ExitCode(EXIT_SUCCESS)          // 0
    public static let failure            = ExitCode(EXIT_FAILURE)          // 1
    public static let validationFailure  = ExitCode(EX_USAGE)              // 64 on macOS/Linux
    public var isSuccess: Bool
}

public struct CleanExit: Error, CustomStringConvertible {
    public static func helpRequest(_ command: ParsableCommand.Type? = nil) -> CleanExit
    public static func helpRequest(_ command: ParsableCommand) -> CleanExit
    public static func message(_ text: String) -> CleanExit               // exits 0
}
```

`ExitCode`'s own doc comment names its niche precisely:

> If you're printing custom error messages yourself, you can throw this error to specify the
> exit code without adding any additional output to standard out or standard error.

Exit-code mapping, verified in `Usage/MessageInfo.swift`:

| Thrown | Exit code | Output |
|---|---|---|
| nothing (clean `run()`) | `0` | — |
| `CleanExit.message("…")` / `.helpRequest()` | `0` | the message / full help |
| `ValidationError("…")` **or** any parse failure | `EX_USAGE` = **64** (macOS/Linux); `ERROR_BAD_ARGUMENTS` on Windows; `EXIT_FAILURE` on WASI | message + usage + help, **to stderr** |
| `ExitCode(n)` | `n` | nothing (`message: ""`) |
| any other `Error` | `EXIT_FAILURE` = **1** | `error.describe()` |

`MessageInfo.swift:123-126` is the exact switch:

```swift
case let exitCode as ExitCode:
    self = .other(message: "", exitCode: exitCode)
default:
    self = .other(message: error.describe(), exitCode: .failure)
```

**Design consequence for `tgkb doctor`:** if `doctor` should report "index stale" vs
"index corrupt" vs "not logged in" distinguishably to a script, print our own human
message and then `throw ExitCode(3)` etc. Do *not* overload `ValidationError` for
runtime conditions — 64 means "you typed it wrong", and conflating those makes shell
callers unable to tell a bad flag from a bad database.

`validate()` — `ParsableArguments` has a `mutating func validate() throws` hook that runs
after parsing, before `run()`. That is where `--db` path existence should be checked, so
the failure prints usage rather than a bare stack of our own errors.

### Shell completions — `Articles/InstallingCompletionScripts.md`

Built in, no configuration required:

```
tgkb --generate-completion-script zsh  > ~/.zsh/completion/_tgkb
tgkb --generate-completion-script bash > ~/.bash_completions/tgkb.bash
tgkb --generate-completion-script fish > ~/.config/fish/completions/tgkb.fish
```

Supported shells: **bash, zsh, fish** (only these three). Zsh filename must be `_tgkb`.

Per-argument completion behavior, `Parsable Properties/CompletionKind.swift`:

```swift
.default
.list([String])
.file(extensions: [String] = [])
.directory
.shellCommand(String)
.custom(@Sendable ([String], Int, String) -> [String])         // words, cursor index, current word
.custom(@Sendable ([String], Int, String) async -> [String])    // async overload, macOS 10.15+
```

Used as `@Option(completion: .file(extensions: ["sqlite"])) var db: String`.

The async `.custom` overload is the interesting one for `tgkb`: channel-name completion can
open the index and query it. Two caveats from the source: the deprecated one-parameter
`.custom(([String]) -> [String])` still exists — use the **three**-parameter form; and the
doc comments carry a page of fish-3-vs-4 and zsh quoting caveats (words passed unquoted in
fish 3, cursor index inconsistencies, zsh redirect handling), so treat custom completion as
a nice-to-have, not a v1 requirement.

`.shellCommand("…")` is the cheap alternative if we do not want to pay the DB-open cost.

### Extras present in 1.8.2 worth a line

- `Plugins/GenerateDoccReference` + `Tools/generate-docc-reference` — the package ships a
  **SwiftPM plugin that generates DocC reference pages from the command tree**. If we want
  `tgkb`'s CLI reference inside our DocC catalog rather than hand-maintained, this is the
  supported path. (Existence verified from the tree; wiring not probed — see Unverified.)
- `Tools/generate-manual` — man-page generation, same idea.
- `EnumerableFlag` — for `--kind average|median` style mutually-exclusive flags. Likely
  useful for `tgkb query --format text|json|ndjson`.
- `Utilities/Mutex.swift` internally — the library is concurrency-clean; `CompletionKind`
  explicitly conforms to `Sendable`.

---

## Where SAP and the MCP stdio constraint collide — read this before writing `serve`

`tgkb query` and `tgkb doctor` legitimately `print()` to stdout; that is what a CLI does.
`tgkb serve` **must not** — stdout is the JSON-RPC channel (see `mcp-swift-sdk.md`).
SAP itself will also write to stdout/stderr on its own: help text, `--version`, and error
messages. In practice that is safe, because all of that happens *before* the transport
connects and results in process exit — but it means:

- Never call `CleanExit.message(…)` or let a `ValidationError` surface from inside a
  running `serve` session. Validate everything in `Serve.validate()`, before
  `server.start(transport:)`.
- Keep result-rendering code that `print`s out of the module `Serve` imports. The cleanest
  split is: a `TelegramKBCore` module that *returns* strings, a `tgkb` CLI target that
  prints them, and a serve path that hands the same strings to `CallTool.Result`.

---

## Unverified

- **The `GenerateDoccReference` plugin's actual invocation and output layout** — the
  plugin directory exists at tag 1.8.2 (`Plugins/GenerateDoccReference/GenerateDoccReference.swift`,
  with snapshot tests under `Tests/ArgumentParserGenerateDoccReferenceTests/Snapshots/`),
  but its `Package.swift` product name, command verb, and whether it is exported as a
  package plugin for *consumers* were not read. Verify before planning docs around it.
- **`@ParentCommand` semantics** — file exists (`Parsable Properties/ParentCommand.swift`);
  contents not read. Mentioned only so we know to look, not as a recommendation.
- **Whether `EX_USAGE` is 64 on our exact platform** — verified as `EX_USAGE` in source
  (`Utilities/Platform.swift:155-163`); the value 64 comes from `sysexits.h` and was not
  independently confirmed on this machine.
- **Swift 6.3 compatibility** — `1.8.2`'s `Package.swift` was not read for its
  `swift-tools-version`. SAP is Apple-maintained and tracks toolchains closely, so this is
  low-risk, but it is an assumption, not a verification.
- **Behavior of `defaultSubcommand`** with an async root — not probed. We plan
  `defaultSubcommand: nil` (bare `tgkb` prints help), which is the default path.
