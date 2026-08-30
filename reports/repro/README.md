# Repro — symbol-graph extraction downloads a trait-gated `binaryTarget`

## `real/` — one package, real artifact, real cost

This is the evidence behind the numbers in the reports. A single `Package.swift` depending on
`Swiftgram/TDLibKit`, whose binary artifact is genuinely large.

```bash
cd real
swift build --cache-path .cache --scratch-path .scratch                       # trait off
du -sh .cache                                                                  # ~44K
swift package --cache-path .cache --scratch-path .scratch dump-symbol-graph    # trait STILL off
du -sh .cache .scratch/artifacts                                               # ~463M and ~1.3G
```

Measured on Swift 6.3.3 / macOS, cold cache:

| | `swift build` | `dump-symbol-graph` |
|---|---|---|
| Wall time | 0.6 s | **214 s** |
| Cache | 44 KB | **463 MB** (343 MB artifact) |
| Extracted | — | **1.3 GB** |

`--cache-path` / `--scratch-path` keep this out of the real SwiftPM cache; cleanup is `rm -rf`.

> **Not a problem with TDLibKit, TDLibFramework, or Swiftgram.** They are used only as a
> convenient public example of a large `binaryTarget`.

## Offline reproduction

Moved to its own repository so it can be cloned and run by anyone working on a fix:
**https://github.com/laconicman/swiftpm-trait-symbolgraph-repro**

Network-free, plus a `run.sh` regression harness (exit 0 when fixed, 1 when present) and a
plugin-API probe with a negative control.
