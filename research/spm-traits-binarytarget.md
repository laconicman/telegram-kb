# Do SwiftPM traits gate a `binaryTarget` download?

**Yes.** Empirically verified by me on 2026-08-23, Swift 6.3.3, tools-version 6.1.

This answers the open SPM question in brief §6.1 verbatim: *"Can SwiftPM package traits (Swift
6.1+) gate the TDLibFramework dependency, so a consumer who only wants the index + MCP side
never pulls 300 MB? Verify traits × binaryTarget interaction empirically — don't assume."*

---

## Verdict

**Yes for `swift build`, `swift test` and `swift package resolve` — but NOT for
`swift package dump-symbol-graph`, and therefore not for `swift package generate-documentation`,
which goes through it.**

The gating is real and worth having: a normal build or test run with the trait off does not
resolve the products, does not download the artifact, and does not even list the dependency in
the graph. **But the DocC plugin bypasses it**, so any CI job that builds documentation pays the
full download regardless.

That second half is a correction to my own first conclusion. I initially recorded an unqualified
"yes" from a scratch test using a `.package(path:)` dependency, and flagged the remote case as
untested. When the real remote dependency was wired up, a 343 MB `TDLibFramework.zip` duly
appeared in `~/Library/Caches/org.swift.swiftpm/artifacts/` with the trait off — which looked
at first like a flat refutation. It was not: an isolated re-test with the real remote dependency
confirmed `swift build` still downloads nothing. The download timestamp (22:31:59) sat 36
seconds before the DocC archive was written (22:32:35), which pointed at the docs build, and a
minimal probe then confirmed it directly.

**Net effect on the design: the trait still earns its place**, because day-to-day builds, tests
and a lean consumer's `swift build` all stay free. It just is not a complete shield, and a docs
CI job needs to be treated as a heavyweight step.

> **Root cause — see `reports/` for the authoritative write-up.** A parallel session in this
> repo took this finding considerably further than I did, and its account supersedes mine on the
> mechanism. Rather than restate it here and let the two drift, the short version and a pointer:
>
> The trigger is **`swift package dump-symbol-graph`**, not the DocC plugin as such — DocC just
> takes that path. Both symbol-graph entry points deliberately pass `enableAllTraits: true`
> (`Sources/Commands/PackageCommands/DumpCommands.swift` and
> `Sources/Commands/Utilities/PluginDelegate.swift`). Artifact resolution is then driven by
> `DependencyManifests`, **not** by the pruned `ModulesGraph`: enabling all traits makes the
> dependency survive `isPackageDependencyUsed`, `BinaryArtifactsManager.parseArtifacts` enumerates
> every `.binary` target into the fetch list, and the download happens. The target *is* pruned
> again at build-plan time — after the bytes have moved.
>
> Measured there, cold, trait disabled in both: `swift build` 0.6 s / 44 KB cache;
> `dump-symbol-graph` **214 s / 463 MB cache / 1.3 GB extracted**.
>
> Also worth knowing: `packageManager.build(...)` from a plugin does **not** reproduce it — it
> reuses the workspace's real trait configuration. Only the symbol-graph paths force traits on.
>
> The intent behind `enableAllTraits` is defensible (documentation should cover trait-gated API
> rather than silently omitting it); it is the artifact side-effect that looks under-specified.

## Method

Deliberately cheap: rather than download a real 300 MB artifact, I pointed a `binaryTarget` at
an **unreachable URL with a bogus checksum**. If SwiftPM tries to fetch it the command fails
loudly; if it never tries, the command succeeds. Absence of a download is then observable
without ever transferring a byte.

```swift
// FakeBinary/Package.swift  — the dependency package
.binaryTarget(
    name: "FakeXCF",
    url: "https://example.invalid/definitely-not-here.xcframework.zip",
    checksum: "0000000000000000000000000000000000000000000000000000000000000000"),
.target(name: "FakeWrapper", dependencies: ["FakeXCF"]),
```

```swift
// Consumer/Package.swift  — gates the product behind a trait
traits: [.trait(name: "TDLib")],
dependencies: [.package(path: "../FakeBinary")],
targets: [
    .executableTarget(name: "Consumer", dependencies: [
        .product(name: "FakeWrapper", package: "FakeBinary",
                 condition: .when(traits: ["TDLib"]))
    ]),
]
```

## Verified results

**Scratch probe (path dependency, unreachable URL):**

| Command | Outcome | Artifacts fetched |
|---|---|---|
| `swift build` | **Build complete** | **0** |
| `swift package resolve` | exit 0 | **0** |
| `swift package show-dependencies` | `No external dependencies found` | — |
| `swift build --traits TDLib` | **error: failed downloading …** | (attempted) |
| `swift package resolve --traits TDLib` | **error: failed downloading …** | 2 partial |

The two trait-enabled rows are the control: they prove the mechanism is live and that the
artifact really would be fetched but for the trait. Without that control the passing rows would
prove nothing — SwiftPM might simply defer binary downloads.

**Real remote dependency (`Swiftgram/TDLibKit` `1.5.2-tdlib-1.8.66-022d6020`), isolated cache
via `--cache-path`, trait off:**

| Command | Outcome | Isolated cache size |
|---|---|---|
| `swift build` | Build complete | **44 KB** — no artifact |
| `swift package show-dependencies` | empty | — |

So the result holds for remote dependencies, not just path ones.

**The DocC hole — isolated probe, trait off:**

| Command | Outcome |
|---|---|
| `swift build` | Build complete, **no download attempted** |
| `swift package generate-documentation` | **`Downloading binary artifact https://example.invalid/…`** → fails |

Two further observations from the real package, trait off:

- **The dependency is still cloned.** `TDLibKit` (12 MB) and `TDLibFramework` (107 MB) appear in
  `.build/checkouts/` and in `Package.resolved`, even though the artifact is not fetched and
  `show-dependencies` reports the graph as clean. Source checkout and artifact download are
  separate costs; only the second is gated.
- **Empty placeholder directories** are created under `.build/artifacts/tdlibframework/` — zero
  bytes, but enough to fool a naive "is the directory present" check. The real artifact lives in
  the *global* cache at `~/Library/Caches/org.swift.swiftpm/artifacts/`, which is where any
  invariant check must look.

---

## Root cause of the DocC hole — confirmed in source

**It is deliberate, not an oversight — but the artifact download is an unintended consequence
of that deliberate choice.** Both symbol-graph entry points hardcode `enableAllTraits: true`:

| Call site | Note |
|---|---|
| `Sources/Commands/PackageCommands/DumpCommands.swift:66` | comment: *"We are enabling all traits for dumping the symbol graph."* |
| `Sources/Commands/Utilities/PluginDelegate.swift:380` | `createSymbolGraphForPlugin` — the path swift-docc-plugin takes |

Both current on `main` as of 2026-08-23 (I fetched the files directly rather than relying on a
possibly-stale index). `enableAllTraits` defaults to `false` everywhere else.

The chain from "enable all traits" to "download 343 MiB":

1. `TraitConfiguration.enableAllTraits` resolves `EnabledTraits` to `nil`, meaning *all*.
2. `Workspace.loadPackageGraph` consults `manifest.isPackageDependencyUsed(_:enabledTraits:)`,
   which now returns `true`, so the trait-gated dependency is **not pruned**.
3. `Workspace.BinaryArtifactsManager.parseArtifacts(from:)` walks every surviving manifest and
   enumerates every `.binary` target into the remote fetch list.
4. `Workspace._updateBinaryArtifacts` downloads everything in that list not already cached.

**The target is pruned again at build-plan time — after the bytes have moved.** Artifact
resolution runs off `DependencyManifests`, not off the final `ModulesGraph`, so pruning happens
too late to prevent the download.

This also explains the otherwise-odd result that `packageManager.build(.all(includingTests:))`
from inside a plugin is clean: it routes through `pluginRequestedBuildOperation`, which reuses
the workspace's real trait configuration. Only the symbol-graph paths build a fresh build system
with all traits forced on.

**There is no opt-out.** No flag on `dump-symbol-graph`, no option on
`PackageManager.SymbolGraphOptions`, and `--disable-default-traits` has no effect because the
value is hardcoded rather than derived from user options.

Corroborated independently by DeepWiki in deep mode against `swiftlang/swift-package-manager`
([conversation](https://deepwiki.com/search/why-does-symbol-graph-extracti_d9f8b508-a4cb-45f0-99e6-30e8ff08345c?mode=deep)),
which reached the same call sites and the same `parseArtifacts` mechanism. Its index was pinned
248 days back, so I verified both call sites against current `main` myself; the line numbers here
are from `main`, not from the index.

No existing SPM issue covers this — searched issues for traits × binaryTarget, traits × symbol
graph, and dump-symbol-graph × traits. The one nearby hit, `#8848`, is about `dump-symbol-graph`
not supporting the swiftbuild build system and is unrelated.

Reproductions: `reports/repro/real` (one package, real artifact) and `reports/repro/offline` (synthetic, no network). Drafted write-ups: `reports/`.

---

## Unverified / caveats

- ~~Path dependency, not remote.~~ **Now tested with the real remote dependency** — gating holds
  for `swift build`. The git checkout does still occur (119 MB across the two repos), as
  suspected.
- **Xcode, not just SwiftPM CLI.** Xcode resolves packages with its own logic and a different
  default-trait story. Since the brief's §"Package dependency during development" describes
  dragging the local package into an Xcode project, this deserves a check before relying on it
  for the Xcode workflow.
- **Default traits and downstream consumers.** If `telegram-kb` is ever consumed *as a
  dependency*, the enabled-trait set is decided by the top-level package. A consumer that
  enables `TDLib` transitively re-introduces the artifact. Fine for our use, worth knowing.
- I did not test `.package(url:…, traits:)` (gating traits *of* a dependency), which is a
  different feature from what is tested here.

---

## Consequences for the design

1. **Keep one package.** Use a `TDLib` trait, default **off**, gating the
   `TelegramKBIngestTDLib` target and its TDLibFramework dependency. A separate package for the
   TDLib side would buy nothing that the trait does not, and would cost a second repo, a second
   version number and a split test suite.
2. **`tgkb-mcp` never sees the artifact.** Combined with the brief's hard invariant that
   `tgkb-mcp` must not transitively depend on `TelegramKBIngestTDLib`, the trait makes that
   invariant cheap to hold *and* cheap to verify.
3. **The invariant test must inspect the global cache, not `.build/artifacts`.** Empty
   placeholder directories appear there with the trait off and will fool a presence check —
   mine did, and reported a false violation. Assert on bytes in
   `~/Library/Caches/org.swift.swiftpm/artifacts/`.
4. **Treat the docs CI job as heavyweight.** `generate-documentation` pulls the full artifact
   regardless of traits. Either accept it, run it only on release, or give it a warm cache.
4. **Phase 1 needs no network at build time at all** — which matches the finding that Phase 1
   needs no TDLib at runtime either.
