# SPM GitHub issue — draft

**Repo:** `swiftlang/swift-package-manager` · **Template:** BUG_REPORT.yml
**Not yet filed.** Review before posting.

---

## Title

`dump-symbol-graph` / plugin `getSymbolGraph` force-enable all traits, downloading binary artifacts for trait-gated dependencies the user disabled

---

## Is it reproducible with SwiftPM command-line tools?

- [x] Confirmed reproduction steps with SwiftPM CLI.

## Description

A package trait that gates a dependency containing a `.binaryTarget(url:checksum:)` is correctly
honoured by `swift build`, `swift test`, `swift package resolve` and `show-dependencies` — the
dependency is pruned and nothing is downloaded.

**`swift package dump-symbol-graph` downloads the binary artifact anyway**, as does
`PackagePlugin`'s `PackageManager.getSymbolGraph(for:options:)` — which means
`swift package generate-documentation` (swift-docc-plugin) does too.

The cause is explicit and intentional in source: both symbol-graph entry points pass
`enableAllTraits: true`.

- `Sources/Commands/PackageCommands/DumpCommands.swift:66` — with the comment
  *"We are enabling all traits for dumping the symbol graph."*
- `Sources/Commands/Utilities/PluginDelegate.swift:380` — same, in `createSymbolGraphForPlugin`.

Both are current on `main` as of 2026-08-23.

**I want to be clear that enabling all traits for symbol-graph extraction looks like a deliberate
and reasonable choice** — documentation should presumably cover trait-gated public API. This
report is about a side effect of that choice that I don't think was intended, and for which there
is no opt-out.

### Why the side effect is not obvious from the design intent

Enabling all traits so that *documentation is complete* is a statement about which **source** to
analyse. It incidentally also changes which **artifacts get downloaded**, because artifact
resolution runs off `DependencyManifests` — before graph pruning — rather than off the final
`ModulesGraph`:

1. `enableAllTraits: true` selects the `TraitConfiguration.enableAllTraits` case
   (`Sources/PackageModel/Manifest/TraitConfiguration.swift:15`, short-circuited at `:25-27`).
2. Dependency pruning consults
   `Manifest.isPackageDependencyUsed(_:enabledTraits:)`
   (`Sources/PackageModel/Manifest/Manifest+Traits.swift:405`), which with all traits enabled
   reports the trait-gated dependency as used, so it is not pruned.
3. `Workspace.BinaryArtifactsManager.parseArtifacts(from:)`
   (`Sources/Workspace/Workspace+BinaryArtifacts.swift:76`) then walks
   `manifests.root.packages.values + manifests.dependencies` (`:82-83`) and enumerates every
   `.binary` target into the remote fetch list.
4. Those artifacts are downloaded.

The target is pruned again later at build-plan time — but the download has already happened.

Notably, `packageManager.build(.all(includingTests: false))` from inside a plugin does **not**
exhibit this — I tested it as a negative control, and no download is attempted. So the trigger is
specific to the symbol-graph paths, which create a fresh build system with all traits enabled,
rather than to the plugin API or to dependency resolution generally. (I have not traced *why* the
build path differs; that is an observation, not a claim about its implementation.)

### Why this matters in practice

I maintain a package whose optional ingestion path is trait-gated specifically so that consumers
who don't need it don't pay for the artifact. The trait works exactly as intended for builds and
tests. But the artifact is **343 MiB compressed and 1.33 GiB unzipped**, and SwiftPM keeps both,
so any CI job that builds documentation pays roughly **1.7 GiB and ~3.5 minutes** for API it is
not documenting and cannot link against. There is no flag to decline.

This seems likely to affect any package using traits to gate a large binary dependency, which is
one of the more natural uses of the feature.

## Expected behavior

Either:

1. Artifact resolution respects the *effective* enabled-traits configuration, so a
   trait-gated `binaryTarget` is not downloaded when the trait is off; **or**
2. symbol-graph extraction keeps `enableAllTraits: true` for source analysis but does not treat
   it as a reason to fetch binary artifacts; **or**
3. there is a documented opt-out — a `--traits`-respecting mode on `dump-symbol-graph`, and a
   corresponding option on `PackageManager.SymbolGraphOptions`.

(2) looks closest to the original intent: keep documentation complete, stop paying for binaries
that will not be linked. Symbol-graph extraction needs the *interface*, and for a trait-gated
dependency whose target is pruned from the final graph, it arguably needs neither.

## Actual behavior

The artifact is downloaded. `--disable-default-traits` does not prevent it — the value is
hardcoded, not derived from user options.

## Steps to reproduce

### One package, copy-paste, no assembly

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TraitRepro",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TraitRepro", targets: ["TraitRepro"])],
    traits: [.trait(name: "TDLib")],          // not a default trait -> disabled
    dependencies: [
        .package(url: "https://github.com/Swiftgram/TDLibKit.git",
                 exact: "1.5.2-tdlib-1.8.66-022d6020"),
    ],
    targets: [
        .target(name: "TraitRepro", dependencies: [
            .product(name: "TDLibKit", package: "TDLibKit",
                     condition: .when(traits: ["TDLib"]))
        ]),
    ])
```

Plus one throwaway source file at `Sources/TraitRepro/TraitRepro.swift`:

```swift
public func traitRepro() {}
```

> **To be clear, this is not a problem with TDLibKit, TDLibFramework, or Swiftgram.** I use them
> only because they are a convenient public example of a large `binaryTarget`. The behaviour
> reproduces with any `.binaryTarget(url:checksum:)` behind a disabled trait; a synthetic
> offline version is at the end of this issue.

Then, with the trait **disabled in both commands** (`--cache-path`/`--scratch-path` keep this out
of your real cache, so cleanup is `rm -rf`):

```bash
swift build --cache-path .cache --scratch-path .scratch
du -sh .cache                                                                # 44K

swift package --cache-path .cache --scratch-path .scratch dump-symbol-graph
du -sh .cache .scratch/artifacts                                             # 463M, 1.3G
```

Measured on Swift 6.3.3 / macOS with a cold cache:

| | `swift build` | `swift package dump-symbol-graph` |
|---|---|---|
| Wall time | 0.6 s | **214 s** |
| Cache | 44 KB | **463 MB** (343 MB artifact) |
| Extracted into scratch tree | — | **1.3 GB** |

The relevant output line:

```
Downloading binary artifact https://github.com/Swiftgram/TDLibFramework/releases/download/1.8.66-022d6020/TDLibFramework.zip
[1369/359822073] Downloading …
```

Also reproduces via `swift package generate-documentation` (swift-docc-plugin) and via a custom
command plugin calling `packageManager.getSymbolGraph(for:options:)`. A plugin calling
`packageManager.build(.all(includingTests: false))` does **not** reproduce it.

Unaffected by the trait configuration flags: `swift package --disable-default-traits
dump-symbol-graph` downloads just the same, because the value is hardcoded rather than derived
from user options.

### Offline reproduction, for iterating on a fix

You will not want to re-download 343 MB on every test run. A self-contained, **network-free**
reproduction is here:

**https://github.com/laconicman/swiftpm-trait-symbolgraph-repro**

It points the `binaryTarget` at an unreachable URL, so the download *attempt* is the signal and
nothing is fetched. `./run.sh` is a regression harness — **exit 0 when fixed, exit 1 when
present** — isolated via `--cache-path`/`--scratch-path` so it never touches your real cache.
Current output on 6.3.3:

```
positive control — trait ENABLED, a download attempt is correct:
  swift build --traits Heavy                           ok

trait DISABLED — no download attempt should ever occur:
  swift build                                          ok
  swift package resolve                                ok
  swift package show-dependencies                      ok
  swift package dump-symbol-graph                      MISMATCH (expected download=no, got yes)
  swift package --disable-default-traits (dsg)         MISMATCH (expected download=no, got yes)
  plugin -> packageManager.getSymbolGraph              MISMATCH (expected download=no, got yes)
  plugin -> packageManager.build  (control)            ok
```

The last two rows are the useful part for whoever picks this up: the plugin API reproduces via
`getSymbolGraph` but **not** via `build`, which localises the fault to symbol-graph extraction
rather than to the plugin API or to dependency resolution.

## Swift Package Manager version/commit hash

```
Swift Package Manager - Swift 6.3.3
```

## Swift & OS version

```
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101) Target: arm64-apple-macosx26.0 
Darwin Pauls-MacBook-Pro.local 25.5.0 Darwin Kernel Version 25.5.0: Tue Jun  9 22:26:46 PDT 2026; root:xnu-12377.121.10~1/RELEASE_ARM64_T8103 arm64
```

---

Also asked on Stack Overflow in case this was a configuration mistake on my part; no answers so
far: https://stackoverflow.com/questions/79997703/can-i-stop-swift-package-generate-documentation-from-downloading-a-trait-gated
