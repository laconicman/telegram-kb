Append to the end of the SO question (after "no answers so far", or as a new section):

---

**Update:** this turned out to be a SwiftPM bug rather than a configuration mistake, so it is
not something a package author can currently avoid.

Both symbol-graph entry points pass `enableAllTraits: true` when loading the package graph —
`Sources/Commands/PackageCommands/DumpCommands.swift:66` and
`Sources/Commands/Utilities/PluginDelegate.swift:380`. That un-prunes the trait-gated dependency
before binary artifacts are enumerated for download, so the artifact is fetched even though the
target is pruned again later at build-plan time and never linked. Because the value is hardcoded
rather than derived from user options, `--disable-default-traits` has no effect — there is no
opt-out.

- Filed upstream: https://github.com/swiftlang/swift-package-manager/issues/10448
- Minimal offline reproduction with a regression harness:
  https://github.com/laconicman/swiftpm-trait-symbolgraph-repro

For anyone hitting this meanwhile, the only mitigations are to keep the docs job's SwiftPM cache
warm, or to run documentation builds only on release rather than on every commit.
