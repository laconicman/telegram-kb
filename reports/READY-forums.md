PASTE-READY — Swift Forums
Category: Development → Package Manager   (tags: traits, docc)

================ TITLE ================
Symbol-graph extraction enables all traits — and that forces binary-artifact downloads

================ BODY =================
Traits (SE-0450) give us a clean way to make a heavy dependency optional. I've been using one to
gate a large prebuilt XCFramework, and it works well — until documentation gets built. I think
there's a design question worth settling here, and I'd rather raise it than just file a bug,
because the current behaviour appears deliberate.

### The observation

Given a trait (disabled by default) gating a dependency that contains a
`.binaryTarget(url:checksum:)`:

| Command | Artifact downloaded? |
|---|---|
| `swift build` | no |
| `swift test` | no |
| `swift package resolve` | no |
| `swift package show-dependencies` | no — dependency pruned from the graph entirely |
| **`swift package dump-symbol-graph`** | **yes** |
| **`swift package generate-documentation`** | **yes** |

A one-file reproduction is in the issue linked below — a single `Package.swift` with one
trait-gated dependency on a real public package. Measured cold, on Swift 6.3.3 / macOS, with the
trait **disabled in both commands**:

| | `swift build` | `swift package dump-symbol-graph` |
|---|---|---|
| Wall time | 0.6 s | **214 s** |
| SwiftPM cache | 44 KB | **463 MB** (343 MB artifact) |
| Extracted | — | **1.3 GB** |

That example uses `Swiftgram/TDLibKit` purely because it is a convenient public package with a
large binary artifact — **nothing about this is specific to it, and it is not a problem with that
package.** There is also a self-contained, network-free reproduction at https://github.com/laconicman/swiftpm-trait-symbolgraph-repro — it reproduces in seconds
and ships a `run.sh` that exits 0 when fixed and 1 when present, which is the one to use while
iterating on a fix.

### Why it happens

This isn't an oversight. Both symbol-graph entry points deliberately pass `enableAllTraits: true`:

- `Sources/Commands/PackageCommands/DumpCommands.swift`, commented
  *"We are enabling all traits for dumping the symbol graph."*
- `Sources/Commands/Utilities/PluginDelegate.swift`, in `createSymbolGraphForPlugin` — which is
  the path swift-docc-plugin takes.

The intent seems clearly right: documentation should cover trait-gated public API rather than
silently omitting whatever the current trait configuration happens to disable.

The side effect is where I think the design under-specifies. Artifact resolution is driven by
`DependencyManifests`, not by the pruned `ModulesGraph`:

1. `TraitConfiguration.enableAllTraits` makes `EnabledTraits` `nil`, i.e. "all".
2. `isPackageDependencyUsed(_:enabledTraits:)` then returns `true`, so the dependency survives.
3. `BinaryArtifactsManager.parseArtifacts(from:)` walks every surviving manifest and enumerates
   every `.binary` target into the fetch list.
4. `_updateBinaryArtifacts` downloads them.

The target is pruned again at build-plan time — after the bytes have moved.

Worth noting that `packageManager.build(.all(includingTests: false))` from a plugin does *not*
reproduce this; it reuses the workspace's real trait configuration. Only the symbol-graph paths
construct a fresh build system with all traits forced on.

### The question I'd like to settle

**Should "enable all traits" for symbol-graph extraction imply "resolve and download all binary
artifacts"?**

I don't think it should. Enabling all traits is a statement about *which source to analyse*.
Symbol-graph extraction needs the interface of trait-gated Swift code — which is a good reason to
build it — but it doesn't obviously need the *binary* behind a target that will be pruned from
the final graph anyway. The current behaviour conflates the two.

The practical cost is real, and the table above is my actual package: 343 MiB compressed,
1.33 GiB unzipped, both kept — so a docs CI job pays roughly **1.7 GiB and 3.5 minutes** for API
it isn't documenting and can't link against. There's no flag to decline: the value is hardcoded
rather than derived from user options, so `--disable-default-traits` has no effect.

Gating a large binary dependency behind a trait feels like one of the most natural uses of the
feature, so I'd expect others to hit this.

### Possible directions

1. **Decouple artifact resolution from trait expansion for this operation.** Keep
   `enableAllTraits: true` for source analysis; don't let it drive `parseArtifacts`. Best
   preserves the original intent, but I don't know how cleanly the two separate in `Workspace`,
   since artifact resolution currently runs off the manifests rather than the graph.
2. **Respect the user's trait configuration**, and document that trait-gated API is absent from
   the symbol graph unless the trait is enabled. Simple and predictable, but it regresses the
   documentation-completeness goal the comment is protecting.
3. **Add an opt-out** — a trait-respecting flag on `dump-symbol-graph` and a matching option on
   `PackageManager.SymbolGraphOptions`. Smallest change; leaves the default surprising.
4. **Resolve artifacts lazily**, only when a target actually reaches the build plan. Most general
   and probably the largest change — and it might address other over-resolution cases too.

My preference is (1), falling back to (3) if the coupling in `Workspace` makes it impractical.

Is the artifact consequence something the traits work considered and accepted, or is it
incidental? If it's incidental, I'm happy to put up a PR for whichever direction maintainers
prefer — I'd want a steer on (1) vs (3) before writing it, since they touch quite different
layers.

Reproduced on Swift 6.3.3 / SwiftPM 6.3.3, macOS. Both call sites are current on `main` as of
2026-08-23.

Issue: <link once filed>

I asked on Stack Overflow first, in case I had simply misconfigured the trait; it has had no
answers: https://stackoverflow.com/questions/79997703/can-i-stop-swift-package-generate-documentation-from-downloading-a-trait-gated

**Filed as <https://github.com/swiftlang/swift-package-manager/issues/10448>** with the source
walk-through and both reproductions.
