# `Swiftgram/TDLibKit` — the Swift wrapper layer

**Provenance.** Everything below traced to the GitHub REST API or to files fetched from
`raw.githubusercontent.com/Swiftgram/TDLibKit/main/...` on **2026-08-23**. Repo tree read at
commit **`85ceb00029c4cca943611708299df3ceed4000d2`** (branch `main`,
`GET /repos/Swiftgram/TDLibKit/git/trees/main?recursive=1`, `truncated: false`, 1878 blobs).

Marker convention: **Verified** = quoted from a repo file or a GitHub API response.
**Unverified** = anything else. This document covers only the *Swift packaging* layer;
TDLib's own semantics are in `tdlib-td.md` and are not repeated.

---

## Verdict in one screen

| Question | Answer |
|---|---|
| Latest release | **`1.5.2-tdlib-1.8.66-022d6020`**, created 2026-07-18, last updated **2026-08-23** |
| TDLib targeted | **1.8.66** at commit **`022d6020`** |
| `Package.swift` | **Generated**, by `scripts/swift_package_generator.py`. Header says `DO NOT EDIT!` |
| Binary pin | **`.exact("1.8.66-022d6020")`** — a hard exact pin, not a range |
| Generator | `tl2swift`, a **separate SwiftPM executable vendored at `scripts/tl2swift/`** |
| Generated output | **1832 files, 5.8 MiB** — one file per TL type *and* two 31k-line God-files |
| Receive loop | **A serial `DispatchQueue` running `while(true)` — not a `Thread`, not a `Task`** |
| Errors | **Yes, a typed `TDLibKit.Error`** (`code: Int, message: String`), sniffed by trial decode |
| Updates delivered by | **A closure taking raw `Data`.** No delegate, no `AsyncStream` |
| Swift 6 strict concurrency | **Not ready.** Zero `Sendable` anywhere; tools version 5.3 |

**Two things to plan around before writing a line of code:**
1. **62,132 lines of Swift in two files** is the compile-time bill, and roughly half of it is a
   `@available(*, deprecated)` API surface we will never call (§3).
2. **No `AsyncStream`.** The update path is a raw-`Data` closure hopping DispatchQueues, which
   is exactly the boundary where Swift 6 strict concurrency will bite us (§6, §7).

---

## 1. Releases and the TDLib version targeted — **VERIFIED**

`GET https://api.github.com/repos/Swiftgram/TDLibKit/releases?per_page=8`:

| Tag | Published / last updated |
|---|---|
| **`1.5.2-tdlib-1.8.66-022d6020`** (latest) | created 2026-07-18T01:56:18Z, updated **2026-08-23T12:36:19Z** |
| `1.5.2-tdlib-1.8.66-d8d46dfa` | 2026-07-17T13:23:50Z |
| `1.5.2-tdlib-1.8.66-1b08c83b` | 2026-07-16T14:06:10Z |
| `1.5.2-tdlib-1.8.66-07d3a097` | 2026-07-15T13:36:12Z |
| `1.5.2-tdlib-1.8.65-a17f87c4` | 2026-07-14T13:28:50Z |
| `1.5.2-tdlib-1.8.65-062f2605` | 2026-06-12T14:57:46Z |
| `1.5.2-tdlib-1.8.65-d6debbb2` | 2026-06-12T10:40:58Z |
| `1.5.2-tdlib-1.8.64-e0943d06` | 2026-06-11T15:52:50Z |

**No release carries any asset** — TDLibKit is a pure-source package; the 343 MiB binary comes
transitively from TDLibFramework.

**Version scheme: `<package-version>-tdlib-<tdlib-version>-<tdlib-sha8>`.** Built in `ci.yml`:

```python
          print(f"{versions["package"]}-tdlib-{versions['tdlib_version']}-{versions['tdlib_commit']}", end="")
```

The inputs are a checked-in `versions.json` — the single source of truth, verbatim:

```json
{
    "package": "1.5.2",
    "tdlib_version": "1.8.66",
    "tdlib_commit": "022d6020",
    "tdlibframework_version": "1.8.66-022d6020"
}
```

**Note the package component `1.5.2` has been static across all 8 releases.** The *wrapper's*
own semver only moves when its hand-written code changes; everything else in the tag tracks
upstream. So `1.5.2` appearing in a tag tells you nothing about whether the generated API
changed — the TDLib SHA does.

**These are `1.8.66`-generation sources.** `tdlib-td.md` was researched against `tdlib/td`
**master on 2026-08-23**, which is *newer* than `022d6020` (2026-07-18). Any `td_api.tl`
line quoted there that postdates 1.8.66 will have **no generated Swift counterpart** in
TDLibKit 1.5.2. Everything `tdlib-td.md` relies on (`getChatHistory`, `searchChatMessages`,
`updateMessageInteractionInfo`, `messageInteractionInfo`, `getChatMessageByDate`) is
long-established API and is present — *but verify per symbol before depending on it, don't
assume master parity.* **Unverified — I did not diff master's `td_api.tl` against 1.8.66's.**

**The CI runs on a 12-hour cron**, so TDLibKit re-checks upstream twice daily:

```yaml
  schedule:
    - cron: '0 */12 * * *' # Every 12 hours
```

## 2. `Package.swift` is generated, and the pin is `.exact` — **VERIFIED**

Full manifest at `main`, verbatim:

```swift
// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.
// DO NOT EDIT! Generated automatically. See scripts/swift_package_generator.py

import PackageDescription

let package = Package(
    name: "TDLibKit",
    platforms: [
        // Following versions of https://github.com/Swiftgram/TDLibFramework/blob/main/Package.swift
        .iOS(.v12),
        .macOS(.v10_15),
        .watchOS(.v4),
        .tvOS(.v12)
    ],
    products: [
        .library(
            name: "TDLibKit",
            targets: ["TDLibKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Swiftgram/TDLibFramework", .exact("1.8.66-022d6020")),
    ],
    targets: [
        .target(
            name: "TDLibKit",
            dependencies: ["TDLibFramework"]
        ),
        .testTarget(
            name: "TDLibKitTests",
            dependencies: ["TDLibKit"]
        ),
    ]
)
```

### The version-coupling contract with TDLibFramework — the requested line, quoted

```swift
        .package(url: "https://github.com/Swiftgram/TDLibFramework", .exact("1.8.66-022d6020")),
```

**`.exact(...)`. Not a range, not `upToNextMajor`, not a branch.** And it is *generated* —
`scripts/swift_package_generator.py` takes the version as its one positional argument and
interpolates it into that exact line:

```python
        .package(url: "https://github.com/Swiftgram/TDLibFramework", .exact("{tdlibframework_version}")),
```

**Why `.exact` is correct here, not paranoia.** The generated Swift is produced from the
`td_api.tl` of a *specific TDLib commit*, and the binary implements that same commit's JSON
protocol. Mismatch them and you get no compile error at all — you get **runtime JSON decode
failures**, because a field the Swift struct requires is absent from what the C library
emits. `.exact` converts a silent runtime failure class into a resolver-level guarantee.
This is the codegen↔artifact coupling contract, and it is the single most transferable idea
in either repo.

Confirmed downstream in `Package.resolved`:

```json
      {
        "package": "TDLibFramework",
        "repositoryURL": "https://github.com/Swiftgram/TDLibFramework",
        "state": {
          "branch": null,
          "revision": "3b19a6205abf5aa76a214dc35af0b01d3a12659e",
          "version": "1.8.66-022d6020"
        }
      }
```

That revision `3b19a620…` is **the same commit I independently read TDLibFramework's tree at**
— the two repos agree.

### How *we* pin or upgrade the TDLib version

**The contract propagates: because TDLibKit pins its binary with `.exact`, we pin TDLibKit
and get the TDLib version for free.** Concretely:

```swift
.package(url: "https://github.com/Swiftgram/TDLibKit", .exact("1.5.2-tdlib-1.8.66-022d6020")),
```

Three notes:

1. **Do not use `.upToNextMajor` / `from:` on TDLibKit.** These tags are not semver —
   `1.5.2-tdlib-1.8.66-022d6020` parses as semver `1.5.2` with prerelease identifiers
   `tdlib.1.8.66.022d6020`… inconsistently across tools, and *every* release shares the
   `1.5.2` core. A range would let SwiftPM swap the underlying TDLib commit under us.
   **Unverified — I did not test how SwiftPM's semver parser actually orders these tags.**
   That uncertainty is itself the argument for `.exact`.
2. **Upgrading is a two-line, deliberate act:** bump the `.exact` string, run
   `swift package resolve`, re-run our decode tests. Because TDLibKit's own pin is exact,
   there is exactly one TDLibFramework version that can result.
3. **`.exact` on a transitive dependency is a conflict source.** If anything else in our
   graph ever depends on TDLibFramework at a different version, resolution *fails hard*
   rather than picking one. For a macOS MCP server with a small graph this is a feature.

**Platform floor for us:** `.macOS(.v10_15)`. The async/await surface is additionally gated
at `macOS 10.15` (§5). No constraint on our Swift 6.3 toolchain from this.

## 3. `tl2swift` — how codegen is invoked and what it emits — **VERIFIED**

### It is a vendored SwiftPM executable, not a script

`scripts/tl2swift/Package.swift`:

```swift
// swift-tools-version:5.0
let package = Package(
    name: "tl2swift",
    products: [ .executable(name: "tl2swift", targets: ["tl2swift"]) ],
    dependencies: [],
    targets: [
        .target(name: "TlParserLib", dependencies: []),
        .target(name: "tl2swift", dependencies: ["TlParserLib"])
    ]
)
```

Zero dependencies, hand-written TL parser (`Parser/Parser.swift`) plus a `Composer/`
directory of emitters (`StructComposer`, `EnumComposer`, `MethodsComposer`, …).
Credited in the README to Anton Glezman's [tl2swift](https://github.com/modestman/tl2swift).

Its CLI, from `scripts/tl2swift/Sources/tl2swift/main.swift`:

```
Usage: 
	tl2swift api.tl output_dir tdlib_version tdlib_commit_sha
```

### The invocation — `scripts/update.py`, the whole regeneration cycle

```python
    # Fetch the latest release tag name from GitHub
    tdlibframework_version = run_command(["gh","release","list","--repo","Swiftgram/TDLibFramework",
                                          "--limit","1","--json","tagName","-q",".[0].tagName"])
    ...
    run_command(["python3", os.path.join(scripts_dir, "swift_package_generator.py"),
                 tdlibframework_version], check=True)
    run_command(["swift", "package", "update"], check=True)
    ...
    td_api_url = f"https://raw.githubusercontent.com/tdlib/td/{tdlib_commit}/td/generate/scheme/td_api.tl"
    urllib.request.urlretrieve(td_api_url, td_api_tl_path)
    ...
    run_command(["rm","-rf", os.path.join(scripts_dir,"..","Sources","TDLibKit","Generated")], check=True)
    run_command(["swift","run","tl2swift",
                 os.path.join(scripts_dir,"..","td_api.tl"),
                 os.path.join(scripts_dir,"..","Sources","TDLibKit","Generated"),
                 tdlib_version, tdlib_commit], check=True)
```

**Read the order — it is the whole design.** (1) ask GitHub for TDLibFramework's newest tag;
(2) regenerate `Package.swift` pinning *that* tag exactly; (3) `swift package update` so the
binary is on disk; (4) derive the TDLib commit *from the resolved framework version*;
(5) download **that exact commit's** `td_api.tl`; (6) **`rm -rf` the entire `Generated/`
tree**; (7) regenerate. The TL schema and the binary can therefore never drift apart —
the binary's version *selects* the schema.

Step (6) matters: generation is **destructive, not incremental**, so a type deleted upstream
disappears rather than lingering. It also means never hand-editing anything under
`Sources/TDLibKit/Generated/` — every file carries
`// Generated automatically. Any changes will be lost!`.

### What it generates — **both shapes, and the split is the compile-time story**

Measured from the repo tree (sizes are the API's own `size` field):

| Directory | Files | Bytes |
|---|---|---|
| `Sources/TDLibKit/Generated/Models/` | **1824** | 2.91 MiB |
| `Sources/TDLibKit/Generated/API/` | **3** | **2.89 MiB** |
| `Sources/TDLibKit/Generated/Supporting/` | 5 | 0.01 MiB |
| **Total generated** | **1832** | **5.80 MiB** |

For scale: the repo has **1878 blobs total, of which only 46 are not generated.** TDLibKit is
97.5 % machine-written.

**Models: one file per TL type.** 1824 files averaging 1.7 KiB — `AccentColor.swift`,
`AcceptCall.swift`, `AccountTtl.swift`, … Fine-grained, parallelisable, cheap.

**API: two God-files.** Line counts, measured by downloading them:

```
   31071 Sources/TDLibKit/Generated/API/TDLibApi.swift    (1,516,418 bytes)
   31061 Sources/TDLibKit/Generated/API/TdApi.swift       (1,512,029 bytes)
   62132 total
```

(plus a tiny `TdClient.swift` protocol.)

> **Compile-time verdict.** 62,132 lines of Swift concentrated in **two** files is the
> material cost, and it is worse than the raw number suggests: Swift's type checker and SIL
> passes work per-file, so two 31k-line files cannot be parallelised the way 1824 small ones
> can. They are the critical path of every clean build of the package.
>
> **And roughly half of it is dead weight for us.** `TDLibApi.swift` and `TdApi.swift` are
> near-identical 31k-line surfaces over the same ~1000 TL functions — the modern class and
> the legacy one. The legacy consumer is explicitly deprecated:
> ```swift
> @available(*, deprecated, message: "will be removed; use TDLibClientManager")
> open class TdClientImpl: TdClient {
> ```
> We will use `TDLibApi` (via `TDLibClient`) and never `TdApi`, yet we compile both. There is
> **no way to opt out** — one target, no traits, no conditional compilation.
>
> **Mitigation, and it is the ordinary one:** this is a *dependency*, so SwiftPM compiles it
> **once per configuration** and caches it. It hurts clean builds and CI cold caches, not the
> edit-compile loop. Do not let this drive an architecture decision on its own — unlike the
> 1.33 GiB artifact, which does.
>
> **Unverified — I did not build the package**, so I have no wall-clock number. If it matters,
> measure with `swift build -Xswiftc -stats-output-dir` before acting.

Each generated method appears **twice** — completion-handler and `async` — which is why 1000
TL functions become 31k lines. From `TDLibApi.swift`:

```swift
    public final func getAuthorizationState(completion: @escaping (Result<AuthorizationState, Swift.Error>) -> Void) throws {
        let query = GetAuthorizationState()
        self.run(query: query, completion: completion)
    }

    @available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
    public final func getAuthorizationState() async throws -> AuthorizationState {
        let query = GetAuthorizationState()
        return try await self.run(query: query)
    }
```

Both files carry a provenance header naming the exact upstream commit:

```swift
//  Generated automatically. Any changes will be lost!
//  Based on TDLib 1.8.66-022d6020
//  https://github.com/tdlib/td/tree/022d6020
```

## 4. Client lifecycle and the single-`td_receive` contract — **VERIFIED**

`tdlib-td.md` §5 established the contract from `td_json_client.h`: **`td_receive` is global,
not per-client**, must not be called from two threads simultaneously, and updates must be
applied in arrival order. Here is exactly how TDLibKit honours it.

### The mechanism: a serial `DispatchQueue` running an infinite loop

**Not a `Thread`. Not a `Task`. A `DispatchQueue.async` containing `while (true)`.**
`Sources/TDLibKit/TDLibClientManager.swift`:

```swift
open class TDLibClientManager {
    /// 'receiveQueue' is a separate queue that calls ``td_receive`` in a loop
    private let receiveQueue = DispatchQueue(label: "app.swiftgram.TDLibKit.receive")
    /// 'queryQueue' is a separate queue that will decode update string and lookup for possible completions in existing ``self.clients``. 'queryQueue' exists to quickly switch back to 'receiveQueue' and call next ``td_receive``
    private let queryQueue = DispatchQueue(label: "app.swiftgram.TDLibKit.query")
    public private(set) var clients = ConcurrentDictionary<Int32,TDLibClient>()

    public init(logger: TDLibLogger? = nil) {
        #warning("Breaking changes may be introduced to TDLibClientManager without major version bump.")
        self.logger = logger
        self.receiveQueue.async { [weak self] in
            while (true) {
                guard let self else { break }
                guard
                    let res = td_receive(10),
                    case let dataString = String(cString: res),
                    let data = dataString.data(using: .utf8)
                else {
                    continue
                }
                self.logger?.log(dataString, type: .receive)
                self.queryResultAsync(data)
            }
        }
    }
```

**Five observations, in order of how much they matter to us.**

1. **Uniqueness is enforced only by convention.** `receiveQueue` is an *instance* property, so
   two `TDLibClientManager`s would run two concurrent `td_receive` loops — violating the C
   contract. Nothing in the type system prevents it; the README just says
   *"Make sure to create only one `TDLibClientManager`, since `td_receive` can be only called
   from a single thread."* **Action for us: construct exactly one, own it in a single place,
   and never let a second exist — a `static let` or explicit composition-root ownership.**
2. **The borrowed-pointer footgun is handled correctly.** `tdlib-td.md` warns the
   `const char *` is valid only until the next `td_receive`/`td_execute`.
   `String(cString: res)` copies **synchronously, on the same queue, before the loop
   iterates**. `queryResultAsync` receives an already-copied `Data`. No raw pointer crosses a
   queue hop. Correct.
3. **The loop occupies one thread from the global pool forever.** A serial `DispatchQueue`
   with a non-terminating block never yields its thread. With `td_receive(10)` it blocks up to
   10 s per call. This is a permanently-parked worker thread — acceptable, but it is *not*
   structured concurrency and it will not cooperate with a `Task` cancellation.
4. **Shutdown is a `while` spin.** `deinit` calls `closeClients()`, which is:
   ```swift
    public func closeClients() {
        for client in self.clients.values {
            try? client.close(completion: { _ in })
        }
        while (!self.clients.isEmpty) {}
    }
   ```
   `while (!self.clients.isEmpty) {}` is a **busy-wait spinning a core at 100 %** until every
   client's `authorizationStateClosed` arrives. It implements the correct *protocol* from
   `tdlib-td.md` §5 (send `close`, await `authorizationStateClosed`, never destroy) but with
   the worst possible waiting primitive. The receive loop itself is never stopped — it runs
   until process exit. **Action for us: call `closeClients()` deliberately at a controlled
   shutdown point (the docs suggest `willTerminateNotification`), accept the brief spin, and
   do not call it from a latency-sensitive path.**
5. **Routing is by `@client_id`, with a silent default.**
   ```swift
            let clientId = dictionary["@client_id"] as? Int32 ?? 1
   ```
   `?? 1` is a guess, not a fallback — an update lacking `@client_id` is attributed to client
   1. Benign with a single client (ours), but note it.

### Ordering: preserved, per client

The TDLib contract requires in-order application. TDLibKit gets this right by giving **each
client its own serial queue** and dispatching handlers onto it:

```swift
    /// 'updateHandlerQueue' is a client-specific queue for incoming updates and responses. Serial queue ensures an order of updates https://core.telegram.org/tdlib/getting-started#handling-updates
    public let updateHandlerQueue: DispatchQueue
```
```swift
                    client.updateHandlerQueue.async {
                        client.updateHandler(result, client)
                    }
```

Chain: `receiveQueue` (serial) → `queryQueue` (serial) → per-client `updateHandlerQueue`
(serial). Every hop is serial, so **arrival order is preserved end-to-end.** This satisfies
`tdlib-td.md`'s requirement that the consumer be serial. *Caveat:* our own handler must not
fan out into concurrent work that commits out of order — the guarantee ends at our closure.

### Sending, and client creation

`td_send` is called from a **concurrent** queue, which is legal ("May be called from any
thread"):

```swift
    /// 'queryQueue' is a client-specific queue for outgoing requests. It's a concurrent queue, so some requests may be dispatched earlier even if they were called later.
    private let queryQueue: DispatchQueue
```

Correlation is by a UUID in `@extra`:

```swift
            var extra: String? = nil
            if let completion = completion {
                extra = UUID().uuidString
                self.awaitingCompletions[extra!] = completion
            }
```

Clients can only be made through the manager — `TDLibClient.init` is `fileprivate`, with the
reason stated in its doc comment:

```swift
    /// Since ``td_receive`` can be called only from a single thread, ``TDLibClient`` initializer is private to ensure each client will receive responses for their requests.
    fileprivate init(updateHandler: @escaping (Data, TDLibClient) -> Void, logger: TDLibLogger? = nil) {
        self.id = td_create_client_id()
```

And `createClient` immediately pokes the instance — which is the fix for the
"a fresh client is silent until poked" footgun in `tdlib-td.md` §5:

```swift
        try? newClient.send(query: DTO(GetOption(name: "version")), completion: { _ in })
```

**Note the `try?`** — if that priming send fails, the client is returned looking healthy and
will simply never produce updates.

**The `#warning` will appear in our build.** `#warning("Breaking changes may be introduced to
TDLibClientManager without major version bump.")` is compiled into `TDLibClientManager.init`.
Expect it in every build log, and treat the API-stability disclaimer as sincere — another
argument for `.exact` pinning (§2).

## 5. The async/await surface and the error model — **VERIFIED**

### There IS a typed error, and it is a generated struct

`Sources/TDLibKit/Generated/Models/Error.swift`, in full:

```swift
/// An object of this type can be returned on every function call, in case of an error
public struct Error: Codable, Equatable, Hashable, Swift.Error {

    /// Error code; subject to future changes. If the error code is 406, the error message must not be processed in any way and must not be displayed to the user
    public let code: Int

    /// Error message; subject to future changes
    public let message: String
```

This is `td_api.tl:18`'s `error code:int32 message:string = Error;` rendered into Swift. It is
**the same two fields and no more** — confirming `tdlib-td.md` §4c: there is **no structured
`retry_after`**, so our `429` back-off must still parse `"Too Many Requests: retry after N"`
out of `message` ourselves.

**Naming trap:** the type is called `Error` and conforms to `Swift.Error`. Inside TDLibKit's
own generated code every reference to the Swift protocol is spelled `Swift.Error`
(`Result<AuthorizationState, Swift.Error>`). **In our code, `import TDLibKit` puts a type named
`Error` in scope** — write `TDLibKit.Error` when catching, and be careful with bare `Error` in
generic constraints.

### How TDLib `error` objects become Swift errors — trial decode, not a discriminator

Both `run` overloads, `TDLibApi.swift:31029-31071`:

```swift
    private final func run<Q, R>(
        query: Q,
        completion: @escaping (Result<R, Swift.Error>) -> Void)
        where Q: Codable, R: Codable {

        let dto = DTO(query, encoder: self.encoder)
        do {
            try self.send(query: dto) { [weak self] result in
                guard let strongSelf = self else { return }
                if let error = try? strongSelf.decoder.decode(DTO<Error>.self, from: result) {
                    completion(.failure(error.payload))
                } else {
                    let response = strongSelf.decoder.tryDecode(DTO<R>.self, from: result)
                    completion(response.map { $0.payload })
                }
            }
        } catch let err as Error {
            completion( .failure(err))
        } catch let any {
            let err = Error(code: 500, message: any.localizedDescription)
            completion( .failure(err))
        }
    }

    @available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
    private final func run<Q, R>(query: Q) async throws -> R where Q: Codable, R: Codable {
        let dto = DTO(query, encoder: self.encoder)
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try self.send(query: dto) { result in
                    if let error = try? self.decoder.decode(DTO<Error>.self, from: result) {
                        continuation.resume(with: .failure(error.payload))
                    } else {
                        let response = self.decoder.tryDecode(DTO<R>.self, from: result)
                        continuation.resume(with: response.map { $0.payload })
                    }
                }
            } catch let err as Error {
                continuation.resume(with: .failure(err))
            } catch let any {
                let err = Error(code: 500, message: any.localizedDescription)
                continuation.resume(with: .failure(err))
            }
        }
    }
```

**The mapping rules, stated precisely:**

| Situation | What we get |
|---|---|
| TDLib returned `{"@type":"error","code":N,"message":"…"}` | `throw TDLibKit.Error(code: N, message: …)` — the real thing |
| TDLib returned the expected type | the decoded payload |
| Response decodes as neither | whatever `decoder.tryDecode` yields — a `DecodingError`, **not** a `TDLibKit.Error` |
| `send` itself threw a non-`Error` | `TDLibKit.Error(code: 500, message: <localizedDescription>)` — a **synthesised** 500 |

**Four consequences we must design around.**

1. **`catch let e as TDLibKit.Error` is not exhaustive.** A `DecodingError` can reach us
   (schema drift, §1). Our TDLib call sites need a two-arm catch, and the `DecodingError` arm
   should be loud — it means the generated Swift and the binary disagree.
2. **`code: 500` is ambiguous.** It is both a real TDLib code (`authorizationStateClosed`
   answers everything with 500, per `tdlib-td.md` §5) and TDLibKit's synthetic
   encode-failure code. Log `message` to tell them apart.
3. **Error detection is a *trial decode*, not a `@type` check.** Any response whose JSON
   happens to satisfy `{code: Int, message: String}` is classified as a failure. The
   demonstrable case is in the generated code itself:
   ```swift
    @available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)
    public final func testReturnError(error: Error?) async throws -> Error {
   ```
   `testReturnError` is declared to *return* an `Error` on success — and can never do so,
   because `run` will always take the failure branch first. Harmless (it is a test-only TL
   method we will never call) but it proves the sniffing is structural, not `@type`-driven.
   **No TL type we care about — `Messages`, `Message`, `FoundChatMessages`, `Chat` — has that
   shape, so we are not exposed.**
4. **`@extra` correlation is fire-and-forget.** `send` stores the completion under a UUID; if
   a response never arrives, the entry in `awaitingCompletions` is **never reaped and the
   continuation never resumes** — an `await` that hangs forever *and* leaks. There is **no
   timeout anywhere in TDLibKit.** **Action: wrap every TDLib `await` in our own timeout**
   (e.g. a `withThrowingTaskGroup` race against `Task.sleep`) — especially the backfill loop,
   where `tdlib-td.md` §4c tells us long flood waits are absorbed internally and a call can
   legitimately take a minute.

### Availability

Every `async` method is gated `@available(iOS 13.0, macOS 10.15, watchOS 6.0, tvOS 13.0, *)`,
matching the package's `.macOS(.v10_15)` floor. Non-issue for us.

## 6. How updates are delivered — **closure over raw `Data`. No `AsyncStream`, no delegate** — **VERIFIED**

The one and only delivery mechanism:

```swift
    public let updateHandler: (Data, TDLibClient) -> Void
```
```swift
    public func createClient(updateHandler: @escaping (Data, TDLibClient) -> Void) -> TDLibClient {
```

**We receive undecoded `Data`** and must decode it ourselves, using the client's own
pre-configured decoder — README, verbatim:

```swift
let client = manager.createClient(updateHandler: { /* data: Data, client: TDLibCLient */
    do {
        let update = try $1.decoder.decode(Update.self, from: $0)
        switch update {
            case .updateNewMessage(let newMsg):
```

The decoder must be `client.decoder`, not a fresh `JSONDecoder`, because of key strategy set
in `TDLibApi.init`:

```swift
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
```

**Grep result: zero occurrences of `AsyncStream`, `AsyncSequence`, or a delegate protocol for
updates in the package.** `Update` is a generated enum (`Generated/Models/Update.swift`,
196,971 bytes — the largest model by far, ~500 cases).

**What this means for `telegram-kb`.** We will want an `AsyncStream<Update>` to feed a serial
consumer, and we must build the bridge ourselves. Two hazards, both from things established
above:
- **Back-pressure.** `AsyncStream` with `.unbounded` (the default) will grow without limit if
  our consumer is slower than the update rate — real during a channel backfill. Use
  `.bufferingNewest(n)` or an explicitly bounded policy, and decide what dropping means.
- **Ordering must survive the bridge.** The serial chain in §4 guarantees ordered *delivery
  into our closure*; `AsyncStream.Continuation.yield` preserves that, but only if a **single**
  consumer awaits the stream. `tdlib-td.md` §5 is explicit that ordered application is part of
  the contract, not an optimisation.
- **Decode off the update queue, or accept the cost.** Decoding a large `Update` inside
  `updateHandler` runs on the per-client serial queue and blocks subsequent updates. Yielding
  raw `Data` into the stream and decoding on the consumer side keeps the queue short.

## 7. Swift 6 strict concurrency and `Sendable` — **NOT READY** — **VERIFIED**

**Hard evidence:**
- `grep -c Sendable` over both generated API files: **0 and 0.**
- `swift-tools-version:5.3` in the manifest — so the package builds in **Swift 5 language
  mode**, and no strict-concurrency checking is applied to its own sources.
- No `@preconcurrency`, no `@unchecked Sendable`, no actors, no global-actor annotations
  anywhere in the hand-written sources I read.

The concurrency primitives are pre-`Sendable` by construction — `ConcurrentDictionary` is a
`final class` guarded by a `pthread_rwlock_t`:

```swift
public final class ConcurrentDictionary<Key: Hashable, Value> {
    private var container: [Key: Value] = [:]
    private let rwlock = RWLock()
```
```swift
final class RWLock {
    private var lock: pthread_rwlock_t
```

It is genuinely thread-safe, but **it is not declared `Sendable`**, so the compiler cannot
know that. Likewise `TDLibClient` is a mutable-state `public class` and `TDLibClientManager`
is `open`.

**What breaks at our call site, and why it is our problem not theirs.** A package compiles in
the language mode of *its own* tools version, so TDLibKit itself will build clean under our
Swift 6.3 toolchain. The friction is entirely at the boundary:
- `updateHandler: @escaping (Data, TDLibClient) -> Void` is a **non-`Sendable` closure** that
  TDLibKit hops across three `DispatchQueue`s. Capturing anything actor-isolated in it is a
  diagnostic under Swift 6 language mode.
- **Public structs from another module are not implicitly `Sendable`.** `Update`, `Message`,
  `FoundChatMessages` are `public struct`s in a non-strict-concurrency module, so they do not
  get implicit conformance across the module boundary — moving one into an actor is a
  diagnostic even though every stored property is a value type.

**Reasoned, not verified — I did not compile anything.** Flagged as such deliberately; the
`Sendable` counts and tools version are facts, the compiler's exact diagnostics are not.

**Recommended posture for `telegram-kb`:**
1. `@preconcurrency import TDLibKit` in the one file that touches it. This is the sanctioned
   escape for a not-yet-audited dependency and downgrades the boundary diagnostics.
2. **Confine TDLibKit to a single adapter type** — one `actor` (or `@MainActor`-free
   `final class` with explicit queue confinement) that owns the sole `TDLibClientManager`, the
   sole `TDLibClient`, and the `AsyncStream` bridge from §6. Nothing else in the codebase
   imports TDLibKit.
3. **Convert at the boundary.** Decode `Update` inside the adapter and re-emit our *own*
   `Sendable` domain structs (the SQLite row types). That solves the implicit-`Sendable`
   problem properly instead of papering it with `@unchecked`, and it is the same seam that
   lets the web-preview ingestion source share a schema (per `tdlib-td.md`'s
   two-source-merge design).
4. **Never `@unchecked Sendable` a TDLibKit type.** `TDLibClient` has genuinely mutable
   state; the claim would be false.

## 8. Testing and CI — **VERIFIED**, brief

`.github/workflows/ci.yml`: `update` (runs `scripts/update.py`, uploads the whole workspace as
an artifact) → `test` (matrix: macOS, iOS-sim, tvOS-sim `test`; watchOS-sim, visionOS-sim
`build` only, with the comment *"Became much slower on CI with macos-14 images, while working
fine locally / we will only build them"*) → `release` (commits `[no ci] Version …`, pushes,
runs `scripts/release.py`).

Pinned like the framework repo: `runs-on: macos-15`,
`DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer`. Tests are retried once
(`… || …`). `concurrency: cancel-in-progress: true` on the ref.

**`Tests/TDLibKitTests/TDLibKitTests.swift` is 11,874 bytes — the entire test suite** for a
5.8 MiB generated API. Treat TDLibKit as lightly tested and write our own decode tests against
recorded fixtures for the handful of TL types we depend on.

---

## Verified / Unverified ledger

**Verified** (repo at `85ceb000`, GitHub REST API, 2026-08-23): latest tag and its TDLib
version/commit; `versions.json`; `Package.swift` is generated and pins `.exact("1.8.66-022d6020")`;
`Package.resolved` revision `3b19a620…`; `tl2swift` is a vendored zero-dependency SwiftPM
executable invoked by `scripts/update.py` after `rm -rf Generated/`; 1832 generated files /
5.8 MiB, with 1824 one-per-type models and two 31k-line API files (62,132 lines total);
the receive loop is `DispatchQueue.async { while(true) { td_receive(10) } }`; `String(cString:)`
copies before the next iteration; serial `receiveQueue`→`queryQueue`→per-client
`updateHandlerQueue`; `closeClients()` busy-waits `while (!clients.isEmpty) {}`;
`TDLibKit.Error(code:message:)` conforms to `Swift.Error`; error detection is a trial decode
of `DTO<Error>`; non-`Error` throws become `Error(code: 500, …)`; updates arrive as
`(Data, TDLibClient) -> Void`; zero `Sendable` in the generated API; tools version 5.3;
`#warning` about breaking changes in `TDLibClientManager.init`.

**Unverified — could not probe:**
1. **Actual compile time** of the package. Not built. The 62k-line figure is measured; its
   wall-clock cost is not.
2. **How SwiftPM's semver parser orders `1.5.2-tdlib-1.8.66-022d6020`.** Not tested; it is the
   reason to use `.exact` rather than a range.
3. **Whether TDLib master (2026-08-23, the basis of `tdlib-td.md`) has TL surface absent from
   1.8.66.** No diff performed. Verify per symbol before depending on anything recent.
4. **Exact Swift 6 diagnostics at our call site.** Reasoned from the `Sendable` audit and
   tools version; nothing compiled.
5. **`decoder.tryDecode`'s exact failure type.** Declared in
   `Generated/Supporting/` (5 files, ~10 KiB) which I did not fetch in full; the branch is
   quoted above but the helper's error wrapping is unread.
6. **`scripts/release.py` contents** — not fetched. Release mechanics inferred from `ci.yml`.
