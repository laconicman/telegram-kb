# Stack Overflow question — draft

**Tags:** `swift` `swift-package-manager` `docc` `xcframework`
**Not yet posted.** Review before posting.

---

## Title

Can I stop `swift package generate-documentation` from downloading a trait-gated `binaryTarget`?

---

## Body

I use a SwiftPM **package trait** (Swift 6.1+) to make a large binary dependency optional, so
consumers who don't need it never download it. The artifact is ~343 MB compressed and ~1.3 GB
unzipped, so this matters.

The trait works exactly as I expect for building and testing. It does **not** work for building
documentation, and I can't find a supported way to opt out.

### Minimal reproducible example

One package. `Swiftgram/TDLibKit` is a real public package with a genuinely large binary
artifact, so this is runnable as-is:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TraitRepro",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TraitRepro", targets: ["TraitRepro"])],
    traits: [.trait(name: "TDLib")],          // not a default trait, so it is disabled
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

with one throwaway file at `Sources/TraitRepro/TraitRepro.swift`:

```swift
public func traitRepro() {}
```

> **This is not a problem with TDLibKit or Swiftgram** — I use that package only because it is a
> convenient public example of a large `binaryTarget`. The same thing happens with any
> `.binaryTarget(url:checksum:)` behind a disabled trait.

The `--cache-path` / `--scratch-path` flags below keep the experiment out of your real SwiftPM
cache, so you can undo it with `rm -rf`.

### What works as expected

```
$ swift build --cache-path .cache --scratch-path .scratch
Build complete! (0.60s)

$ du -sh .cache
 44K                      # nothing downloaded — the dependency is pruned
```

### What doesn't

Same trait configuration — still disabled — different command:

```
$ swift package --cache-path .cache --scratch-path .scratch dump-symbol-graph
Downloading binary artifact https://github.com/Swiftgram/TDLibFramework/releases/download/1.8.66-022d6020/TDLibFramework.zip
[1369/359822073] Downloading …

$ du -sh .cache .scratch/artifacts
463M    .cache            # 343 MB artifact
1.3G    .scratch/artifacts
```

214 seconds and ~1.7 GB, for a trait I never enabled. `swift package generate-documentation`
(swift-docc-plugin) does the same thing, because it calls
`PackageManager.getSymbolGraph(for:options:)` under the hood — which is how I hit this in the
first place, in CI.

### What I've already tried

- `swift package --disable-default-traits dump-symbol-graph` — downloads just the same.
- `swift package --traits "" dump-symbol-graph` — rejected as an invalid trait list.
- A custom command plugin calling `packageManager.build(.all(includingTests: false))` — this
  does **not** download the artifact, so it's specific to the symbol-graph path rather than to
  plugins in general.
- Checked `PackageManager.SymbolGraphOptions` for a relevant flag — it has
  `minimumAccessLevel`, `includeSynthesized`, `includeSPI` and `emitExtensionBlocks`, nothing
  about traits or artifacts.

Reading SwiftPM's source, both symbol-graph entry points hardcode `enableAllTraits: true`:
`Sources/Commands/PackageCommands/DumpCommands.swift` (with the comment *"We are enabling all
traits for dumping the symbol graph"*) and `Sources/Commands/Utilities/PluginDelegate.swift` in
`createSymbolGraphForPlugin`. So it appears deliberate — presumably so documentation covers
trait-gated API — but it also drives binary-artifact resolution, because artifacts are collected
from the dependency manifests before the graph is pruned.

### Question

Is there a supported way to build documentation for a package with a trait-gated `binaryTarget`
**without** downloading that artifact — a flag, an environment variable, or a manifest
arrangement I've missed?

If there isn't, is there a recommended workaround short of restructuring the package so the
binary dependency lives in a separate package that the documented one never references?

Swift 6.3.3, macOS, SwiftPM 6.3.3.
