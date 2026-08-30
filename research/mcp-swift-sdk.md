# modelcontextprotocol/swift-sdk — research notes

Probe date: 2026-08-23. All source citations are against tag **`0.12.1`**
(`https://raw.githubusercontent.com/modelcontextprotocol/swift-sdk/0.12.1/...`).

---

## Verdict / what this means for us

1. **Pin `0.12.1`** (released 2026-05-07). Pre-1.0, and the README states outright that
   *minor* bumps may break. Use `.upToNextMinor(from: "0.12.1")` or `.exact`.
2. **Spec revision: `2025-11-25`** — verified in source, not prose.
   `Version.latest` is computed as `supported.max()` over
   `["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]`, and the SDK negotiates
   down to whatever the client asks for if it's in that set. So an older Claude Desktop
   speaking `2025-06-18` still works.
3. **Tool input schemas are hand-authored JSON trees**, typed as `Value` — an
   `enum` with `ExpressibleBy{Dictionary,Array,String,Integer,Float,Boolean,Nil}Literal`.
   **There is no schema DSL, no result builder, and no Codable-derived schema.**
   This is the single biggest ergonomic fact for our tool layer: we will want a thin
   local helper (or a tiny `JSONSchema` struct that `Encodable`s into `Value`) so we are
   not writing raw `.object([...])` trees in five places. Budget for that.
4. **Tool annotations are fully modelled** — `Tool.Annotations` with `readOnlyHint`,
   `destructiveHint`, `idempotentHint`, `openWorldHint`, `title`. Ready for our later
   write-operations phase; pass `annotations:` in the `Tool` initializer.
5. **Logging: the footgun is real and the SDK's default protects us — but the README's
   own "Debugging and Logging" snippet does not.** See the Logging section; the short
   version is: never `print()`, bootstrap swift-log to **stderr**, and prefer
   `server.log(level:logger:data:)` (`notifications/message`) for anything the client
   should see. **Additionally, spend four lines making the mistake impossible**: `dup` the
   real stdout to a spare fd, pass it as `StdioTransport(output:)`, and `dup2` stderr onto
   fd 1 — see Logging §5.
6. **Cursors: modelled but not implemented.** `ListTools.Parameters.cursor` and
   `ListTools.Result.nextCursor` exist as plain `String?`. The SDK does no paging for us
   — opaque cursor encoding/decoding is 100% our problem. For a FTS5 search tool this
   matters: we should page `tgkb_search` results ourselves.
7. **Swift 6 ready.** `swift-tools-version:6.1`, `.enableUpcomingFeature("StrictConcurrency")`,
   `Server` and `StdioTransport` are `actor`s, all model types `Sendable`. macOS 13+.
   Linux supported (glibc/musl); stdio transport is gated on Darwin/Glibc/Musl.
8. It **is** the right dependency — it is the official org-owned SDK, actively released
   (three releases in 2026), and nothing else is close. See "Alternatives".

---

## Verified

### Release history (GitHub API `repos/modelcontextprotocol/swift-sdk/releases`)

| Tag | Published | Notes |
|---|---|---|
| **0.12.1** | 2026-05-07 | auth improvements (#217), fixes (#223) — **current** |
| 0.12.0 | 2026-03-24 | "2025-11-25 review fixes" (#201); OAuth (SEP-990, SEP-1046); NetworkTransport race fix |
| 0.11.0 | 2026-02-19 | "The latest 2025-11-25 specification covered"; conformance tests (SEP-1730); icons/metadata (SEP-973); elicitation updates; **server HTTP transport added** |
| 0.10.2 | 2025-09-23 | strict concurrency adopted (#157); `Tool.description` made optional |
| 0.10.1 | 2025-08-14 | Linux SDK build, Alpine |
| 0.10.0 | 2025-08-10 | `Tool.inputSchema` made **non-optional** (#123) |
| 0.9.0 | 2025-05-26 | sampling |

0.11.0's notes list as *not yet covered*: experimental Task support (SEP-1686), and
sampling (listed under "Not covered yet" alongside Tasks — though `requestSampling`
exists in `Server.swift`; read that note as "not conformance-tested", not "absent").

### Spec revision — `Sources/MCP/Base/Versioning.swift`

```swift
public enum Version {
    public static let supported: Set<String> = [
        "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
    ]
    public static let latest = supported.max()!
    static func negotiate(clientRequestedVersion: String) -> String { … }
}
```

`supported.max()` on a `Set<String>` is lexicographic — works only because the
`YYYY-MM-DD` format sorts correctly. Fine, but worth knowing it is not a curated constant.

### Package facts — `Package.swift` @ 0.12.1

- `// swift-tools-version:6.1`
- Platforms: macOS 13.0, macCatalyst 16.0, iOS 16.0, watchOS 9.0, tvOS 16.0, visionOS 1.0
- Product: `.library(name: "MCP", targets: ["MCP"])` — **the module is `MCP`**, the
  package name is `mcp-swift-sdk`.
- Target `MCP` has `swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]`
- Dependencies pulled transitively into our binary: `apple/swift-system` (SystemPackage),
  `apple/swift-log` (Logging), `mattt/eventsource` (Apple platforms only).
  `apple/swift-nio` is used **only** by the conformance executables, not by `MCP`.
- There is also a `Package@swift-6.0.swift` for older toolchains.

Our `Package.swift` line:

```swift
.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
// target dependency:
.product(name: "MCP", package: "swift-sdk"),
```

### Server construction + stdio transport — real shapes

`Sources/MCP/Server/Server.swift`:

```swift
public actor Server {
    public init(
        name: String,
        version: String,
        title: String? = nil,
        instructions: String? = nil,
        capabilities: Server.Capabilities = .init(),
        configuration: Configuration = .default
    )

    public func start(
        transport: any Transport,
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)? = nil
    ) async throws

    public func stop() async
    public func waitUntilCompleted() async     // await task?.value

    @discardableResult
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self
}
```

Note: **`Server.init` takes no logger.** `Server`'s internal logger is a computed
property reading `connection?.logger` — i.e. it comes from the *transport*
(`Server.swift:139-142`). Injecting a logger means `StdioTransport(logger:)`.

`Sources/MCP/Base/Transports/StdioTransport.swift`:

```swift
public actor StdioTransport: Transport {
    public init(
        input: FileDescriptor = FileDescriptor.standardInput,
        output: FileDescriptor = FileDescriptor.standardOutput,
        logger: Logger? = nil
    )
}
```

Available transports at 0.12.1: `StdioTransport`, `HTTPClientTransport`,
`StatefulHTTPServerTransport`, `StatelessHTTPServerTransport`, `NetworkTransport`,
`InMemoryTransport`. **`InMemoryTransport` is our test seam** — we can drive the whole
server in a unit test without spawning a process.

### Minimal "server with one tool" as it exists in 0.12.1

Composed from `Sources/MCPConformance/Server/main.swift` (the SDK's own current code) +
`Server.swift` signatures. Not from the README, which still shows deprecated
`.text("…")` call sites:

```swift
import MCP
import Logging

// 1. stderr-only logging — see Logging section.
LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }
let logger = Logger(label: "tgkb.mcp")

let server = Server(
    name: "tgkb-mcp",
    version: "0.1.0",
    capabilities: .init(
        logging: .init(),
        tools: .init(listChanged: false)
    )
)

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [
        Tool(
            name: "tgkb_search",
            title: "Search Telegram archive",
            description: "Full-text search over indexed Telegram channel posts.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("FTS5 MATCH expression"),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "default": .int(20),
                    ]),
                ]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false),
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false,
                               idempotentHint: true, openWorldHint: false)
        )
    ], nextCursor: nil)
}

await server.withMethodHandler(CallTool.self) { params in
    guard params.name == "tgkb_search",
          let q = params.arguments?["query"]?.stringValue
    else {
        return .init(content: [.text(text: "Unknown tool", annotations: nil, _meta: nil)],
                     isError: true)
    }
    let hits = try await index.search(q)          // our code
    return .init(
        content: [.text(text: render(hits), annotations: nil, _meta: nil)],
        isError: false
    )
}

let transport = StdioTransport(logger: logger)
try await server.start(transport: transport)
await server.waitUntilCompleted()
```

Two API-churn traps to note, both verified in `Tools.swift`:

- `Tool.Content.text(_:metadata:)` and `.text(text:metadata:)` are **`@available(*, deprecated)`**.
  The live case is `.text(text:annotations:_meta:)`. The README has not been updated;
  the conformance server has. Follow the conformance server.
- `Tool.inputSchema` is non-optional (`0.10.0`), `Tool.description` **is** optional (`0.10.2`).

### Tool / schema authoring — the exact shape

`Sources/MCP/Server/Tools.swift`:

```swift
public struct Tool: Hashable, Codable, Sendable {
    public let name: String
    public let title: String?
    public let description: String?
    public let inputSchema: Value          // ← JSON tree, non-optional
    public var icons: [Icon]?
    public let outputSchema: Value?        // ← structured output, optional
    public var _meta: Metadata?
    public var annotations: Annotations

    public init(name: String, title: String? = nil, description: String?,
                inputSchema: Value, annotations: Annotations = nil,
                outputSchema: Value? = nil, icons: [Icon]? = nil,
                _meta: Metadata? = nil)
}
```

`Value` (`Sources/MCP/Base/Value.swift`) is a plain JSON enum:

```swift
public enum Value: Hashable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String)
    case data(mimeType: String? = nil, Data)
    case array([Value]), object([String: Value])

    public init<T: Codable>(_ value: T) throws     // ← the escape hatch
    public var stringValue: String? { … }          // + int/double/bool/array/object
}
```

Conformances: `ExpressibleByNilLiteral`, `…BooleanLiteral`, `…IntegerLiteral`,
`…FloatLiteral`, `…StringLiteral`, `…ArrayLiteral`, `…DictionaryLiteral`,
`…StringInterpolation`, plus `Codable` and `CustomStringConvertible`.

Because of the literal conformances the conformance server writes schemas terse, e.g.
`inputSchema: .object(["type": "object", "properties": ["a": ["type": "number", "description": "First number"]]])`
— the nested dictionaries and strings are coerced. Both styles compile.

**`public init<T: Codable>(_ value: T) throws` is the lever we want.** It lets us declare
a schema as a small Swift `Encodable` struct (or `[String: AnyCodable]`) and convert once:
`inputSchema: try Value(MySchema())`. That is the closest thing to Codable-derived
schemas the SDK offers — it is *encode-a-hand-written-schema-object*, **not**
reflect-a-Swift-type-into-a-schema. Nothing in the SDK derives a schema from a Swift type.

The SDK does show it handles modern JSON Schema fine — the conformance server registers a
`json_schema_2020_12_tool` using `$schema`, `$defs` and `$ref`.

Argument decoding on the call side is manual: `params.arguments` is `[String: Value]?`,
and you reach in with `?["query"]?.stringValue`. **The SDK does not validate arguments
against `inputSchema`.** Validating (or at least defaulting + erroring cleanly) is on us.

### Tool annotations — exposed, complete

`Tool.Annotations` is `Hashable, Codable, Sendable, ExpressibleByNilLiteral` with
`title`, `destructiveHint`, `idempotentHint`, `openWorldHint`, `readOnlyHint`
(all `Bool?`), plus `isEmpty`. Source comment worth carrying into our design docs:

> All properties in `ToolAnnotations` are **hints**. They are not guaranteed to provide a
> faithful description of tool behavior … Clients should never make tool use decisions
> based on `ToolAnnotations` received from untrusted servers.

Defaults per the source doc comments when unspecified: `destructiveHint = true`,
`idempotentHint = false`, `openWorldHint = true`, `readOnlyHint = false`. **Meaning: if we
omit annotations on our read-only search tools, clients assume destructive + open-world.**
Set them explicitly on every tool from day one.

### Pagination / cursors — modelled, not implemented

`Tools.swift`:

```swift
public enum ListTools: Method {
    public static let name = "tools/list"
    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        public let cursor: String?
        public init()                 // cursor = nil
        public init(cursor: String)
    }
    public struct Result: … {
        public let tools: [Tool]
        public let nextCursor: String?
        public var _meta: Metadata?
    }
}
```

Same pattern on `ListResources` (README shows `.init(resources:, nextCursor: nil)`).
The cursor is an opaque `String` the SDK passes through untouched — no encoding helper,
no page-size handling, no continuation store. For `tgkb_search` results we page inside our
own tool result payload (our own `cursor` field in the tool's output), since MCP cursors
apply to `*/list` methods, not to `tools/call` results.

### `CallTool.Result` — structured output available

```swift
public struct Result {
    public let content: [Tool.Content]
    public let structuredContent: Value?
    public let isError: Bool?
    public var _meta: Metadata?

    public init<Output: Codable>(content: [Tool.Content] = [], structuredContent: Output,
                                 isError: Bool? = nil, _meta: Metadata? = nil) throws
}
```

The `Codable` overload is nice for us: return search hits as a typed struct and let the
SDK encode it, alongside a human-readable `.text` rendering. Pair with `Tool.outputSchema`.

`Tool.Content` cases: `.text`, `.image`, `.audio`, `.resource`, `.resourceLink`.
`.resourceLink(uri:name:title:description:mimeType:annotations:)` is interesting for us —
we could return links to `tgkb://post/<id>` resources instead of inlining every post body.

### Progress + cancellation

`Sources/MCP/Base/Utilities/{Progress,Cancellation,Ping,RequestContext}.swift` exist.
`CallTool.Parameters._meta` carries the client's `progressToken`; the README documents
reading it and emitting `ProgressNotification`. `Server.cancelRequest(_:reason:)` exists,
and `start()`'s loop tracks `pendingRequestTasks: [ID: Task<…>]` for cancellation.
Long FTS5 scans can therefore be made cancellable.

### Swift 6 strict concurrency + Linux

- `Server`, `StdioTransport`, `Client` are `actor`s; `Tool`, `Value`, `Tool.Annotations`,
  all `*.Parameters`/`*.Result` are `Sendable`.
- Handlers are `@escaping @Sendable (M.Parameters) async throws -> M.Result` — captured
  state must be `Sendable`, so our SQLite index should be an `actor` (or a `Sendable`
  wrapper over a connection pool).
- `Server.currentHandlerContext` is a `@TaskLocal` and the doc comment explicitly warns
  that `Task.detached` does not inherit it. Only relevant for HTTP transports (it is `nil`
  for stdio), but the warning is a good general reminder.
- StdioTransport is compiled only `#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)`.
  macOS is fine.

---

## LOGGING — load-bearing

### 1. The footgun is real, and it is architectural, not incidental

Primary source, `StdioTransport.swift` doc comment:

> The stdio transport works by: — Reading JSON-RPC messages from standard input —
> Writing JSON-RPC messages to standard output — Using newline characters as message
> delimiters

The transport writes framed JSON-RPC to `FileDescriptor.standardOutput` and delimits on
newline. **Any `print()`, `dump()`, `FileHandle.standardOutput.write`, or a dependency
that logs to stdout, injects a non-JSON line into the stream and corrupts the session.**
The MCP spec says the same normatively — see the spec citation below.

### 2. What the SDK does to protect us — one good default, one bad example

**Good (verified, `StdioTransport.init`):** when no logger is passed, the transport
installs a *no-op* handler, so the SDK itself emits nothing to stdout by default:

```swift
self.logger = logger ?? Logger(label: "mcp.transport.stdio",
                               factory: { _ in SwiftLogNoOpLogHandler() })
```

That is the whole of the protection. There is **no** stdout guard, no fd redirection, no
assertion, no `dup2` of fd 1 — nothing stops *our* code from printing.

**Bad (verified, `README.md`, "Debugging and Logging" section):** the README's own
troubleshooting snippet bootstraps swift-log to **standard output** and then hands that
logger to `StdioTransport`:

```swift
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)   // ← corrupts the stream
    handler.logLevel = .debug
    return handler
}
let logger = Logger(label: "com.example.mcp")
let transport = StdioTransport(logger: logger)
```

Following the README literally breaks a stdio server. **Our rule: `StreamLogHandler.standardError`,
never `.standardOutput`.** Worth a TechDebt/Design note so nobody "fixes" it back.

### 3. The two sanctioned diagnostics paths

**(a) stderr, via swift-log.** The spec explicitly blesses this (below). Bootstrap once in
`main`:

```swift
LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }
```

**(b) MCP `logging` capability → `notifications/message`.** Fully modelled in
`Sources/MCP/Server/Logging.swift`:

- `LogLevel`: `.debug .info .notice .warning .error .critical .alert .emergency` (RFC 5424 order)
- `SetLoggingLevel` (`logging/setLevel`), `Result = Empty` — the client sets a minimum level
- `LogMessageNotification` (`notifications/message`) with `level`, `logger: String?`, `data: Value`

Server side (`Server.swift:609-636`):

```swift
public func log(level: LogLevel, logger: String? = nil, data: Value) async throws
public func log<T: Codable>(level: LogLevel, logger: String? = nil, data: T) async throws
```

Requires `capabilities: .init(logging: .init(), …)`. **Caveat:** the SDK does *not*
implement the level filter for us — the README says outright that on `SetLoggingLevel` you
"Store the client's preference and filter log messages accordingly (Implementation depends
on your server architecture)". So if we adopt this path we hold the minimum-level state
ourselves. Also `server.log` `throws` if not connected, so it is not a drop-in for
early-startup diagnostics; stderr covers that window.

**Design recommendation for `tgkb-mcp`:** a single `Diagnostics` façade with two sinks —
stderr always (swift-log, `StreamLogHandler.standardError`), plus `server.log(...)` when
the server is connected and the client asked for that level. Ban `print` in the MCP
target; a `swiftlint` `custom_rules` entry or a grep in CI is cheap insurance. The CLI
target (`tgkb query`, `doctor`) prints to stdout freely — only `tgkb serve` is under the
constraint. **That is an argument for keeping the MCP server in its own module that has no
`print` in it at all**, rather than sharing a "render results" helper with the CLI.

### 4. Spec primary source for the stdout rule

`modelcontextprotocol/modelcontextprotocol`, `docs/specification/2025-11-25/basic/transports.mdx`,
section "stdio" (identical wording in `2025-06-18/basic/transports.mdx` except the stderr
bullet, which was widened in 2025-11-25 from "for logging purposes" to "for any logging
purposes including informational, debug, and error messages"):

- "The server **MAY** write UTF-8 strings to its standard error (`stderr`) for any logging
  purposes including informational, debug, and error messages."
- "The client **MAY** capture, forward, or ignore the server's `stderr` output and
  **SHOULD NOT** assume `stderr` output indicates error conditions."
- "The server **MUST NOT** write anything to its `stdout` that is not a valid MCP message."
- "Messages are delimited by newlines, and **MUST NOT** contain embedded newlines."

So: stderr is normatively sanctioned as *the* free-form diagnostics channel, stdout is
normatively exclusive to MCP messages, and — note the second bullet — a client is entitled
to throw our stderr away, which is why `server.log(...)` exists as the second path for
anything the *user* should see.

---

### 5. Independent cross-check (DeepWiki, indexed `modelcontextprotocol/swift-sdk`)

Asked directly whether the SDK guards stdout and whether it helps with cursors. It agreed
with the primary-source reading above and cited the same files
(`Sources/MCP/Base/Transports/StdioTransport.swift` lines 51-52, 66-83, 111-129, 197-222;
`Sources/MCP/Client/Client.swift` 743-755). Its summary: **no fd redirection, no guard
against interleaved writes, no doc-comment warning**, and for cursors "the SDK only
transports the cursor value; its meaning/format is defined and implemented entirely by
whoever writes the server's `ListTools`/`ListResources` handler." Treat the *conclusions*
as verified (I read the same files); the line numbers are DeepWiki's and unverified.

It named one mitigation the SDK does not do but we could: **`dup` fd 1 to a spare
descriptor at startup, hand that to `StdioTransport(output:)`, and `dup2` `/dev/null` (or
stderr) onto fd 1.** Then any stray `print()` — ours, or a dependency's — is physically
incapable of reaching the client. `StdioTransport.init` already takes
`output: FileDescriptor`, so this is supported by the existing API, not a hack.
Roughly:

```swift
// Before starting the server: move the real stdout out of harm's way.
let realStdout = dup(STDOUT_FILENO)                 // e.g. becomes fd 3
dup2(STDERR_FILENO, STDOUT_FILENO)                  // stray print() → stderr
let transport = StdioTransport(
    input: .standardInput,
    output: FileDescriptor(rawValue: realStdout),
    logger: logger
)
```

**Recommendation: do this in `tgkb serve`.** It costs four lines and converts a whole class
of "the MCP server mysteriously stopped responding" bugs — including ones introduced by
third-party code we do not control — into harmless stderr noise. Record it in Design as a
deliberate decision, since it looks strange without the rationale.

---

## Alternatives (brief, no rabbit hole)

GitHub search over Swift MCP repos, sorted by stars:

- **`modelcontextprotocol/swift-sdk`** — 1470 stars, last push 2026-05-07. Official,
  org-owned, versioned releases, has conformance tests against the official framework.
  **Recommended.**
- **`Cocoanetics/SwiftMCP`** — 160 stars, last push 2026-08-14 (i.e. *more* recent commit
  activity than the official SDK), tagged through `v1.10.4`. Community package by Oliver
  Drobnik. Its differentiator is exactly the ergonomic gap we identified: it derives
  tool schemas from Swift function signatures via **macros** (`@MCPServer`, `@MCPTool`,
  `@MCPResource`, `@MCPPrompt`) over a `JSONSchema` type, and uses SwiftPM **package
  traits** to drop swift-nio for client/tools-only consumers. Verified from its README
  on `main`.
- Everything else in the search is an MCP *server application* built on one of the above
  (ObsidianMCPServer, apple-events-mcp, …), or a stale 2025-era experiment
  (`gavinaboulhosn/SwiftMCP` last pushed 2025-03, `1amageek/swift-context-protocol` 2025-02).

**Call:** take the official SDK. Reasons: it tracks the spec revision authoritatively
(`Version.supported` is the ground truth for negotiation), it is what Anthropic's own docs
point at, and our tool surface is small enough (a handful of read-only search tools) that
hand-written `Value` schemas are a bounded cost — one small internal helper, not a
framework. Revisit `SwiftMCP` only if the tool count grows past ~15 and the hand-written
schemas start drifting from the Swift argument structs. Note if we ever compare: macro-
derived schemas trade the drift problem for a macro-expansion debugging problem.

---

## Unverified

- **"Sampling not covered yet"** — 0.11.0's release notes list sampling under "Not covered
  yet", but `Server.requestSampling(...)` exists at `Server.swift:473` and the README
  documents client-side sampling. Reading the note as "not conformance-tested against the
  official framework" is an *inference*, not verified. Irrelevant to us (we do not need
  sampling), flagged only so nobody trusts the inference later.
- **Whether the README's `StreamLogHandler.standardOutput` snippet has an open issue
  against it** — not probed. The snippet itself is verified present at 0.12.1.
- **Actual build against Swift 6.3 / our toolchain** — not attempted (research only).
  `Package.swift` declares `swift-tools-version:6.1`, which 6.3 accepts, but "declares 6.1"
  is not the same as "compiles clean under 6.3 with our warning settings". First
  implementation step should be a throwaway `swift build` to confirm.
- **`InMemoryTransport` as a test seam** — the file exists at
  `Sources/MCP/Base/Transports/InMemoryTransport.swift`; its API was not read. Treat the
  "drive the server in a unit test" claim as plausible-but-unread.
- **Claude Desktop / Claude Code's negotiated protocol version** — not probed. The SDK
  negotiates down through `2024-11-05`, so this is low-risk either way.
