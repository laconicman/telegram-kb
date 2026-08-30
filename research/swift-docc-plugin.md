# swiftlang/swift-docc-plugin — research notes

Probe date: 2026-08-23. Source citations against tag **`1.5.0`**
(`https://raw.githubusercontent.com/swiftlang/swift-docc-plugin/1.5.0/...`).

---

## Verdict / what this means for us

1. **Pin `.package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0")`**
   (1.5.0 released 2026-04-27). Add it to `dependencies` only — **no target dependency**,
   it is a command plugin.
2. **A docs-only umbrella target works, and this is not an inference — the docc-plugin's own
   package does exactly that.** Its `SwiftDocCPlugin` target has *no API at all*: one
   `EmptyFile.swift` containing only comments, plus a `.docc` catalog. Verified by reading
   both `Package.swift` and the file itself.
3. **The one concrete requirement: the target must contain at least one `.swift` file.**
   SwiftPM rejects a target with zero sources. The file may be **entirely empty of code** —
   comments only. **No dummy public symbol is needed.** Apple's own file says so in a
   comment: "This is an empty source file used to make SwiftDocCPluginDocumentation a valid
   documentation build target."
4. Two layout details that make the docs-only target look right rather than broken:
   - The `.docc` root article must be named after the **target**
     (`TelegramKB.docc/TelegramKB.md`, starting `# ``TelegramKB```) to become the landing page.
   - Add an `Info.plist` in the catalog with `CDDefaultModuleKind` so the page is not
     labelled "Framework". Apple sets it to `Command Plugin`; we'd set something like
     `Project Documentation`. Optionally `@Metadata { @DisplayName("Telegram KB") }` in the
     root article for a prettier title.
5. **`.spi.yml` for Swift Package Index is three lines**, and points at our umbrella target:
   `documentation_targets: [TelegramKB]`. The first target listed is the landing page.
   Note SPI **injects the plugin itself** if our manifest lacks it — so `.spi.yml` works
   even before we add the dependency. (`telegram-kb` is likely private, in which case SPI is
   moot and the local/GitHub-Pages commands below are what matter.)
6. Note the target **name** drives the docs URL path (lowercased), not the directory name —
   Apple's target is named `SwiftDocCPlugin` but lives at `Sources/SwiftDocCPluginDocumentation/`,
   and publishes to `/documentation/swiftdoccplugin`. So name the target for the URL you want.

---

## Verified

### Version

`repos/swiftlang/swift-docc-plugin/releases` → `1.5.0` (2026-04-27), `1.4.6` (2026-02-06),
`1.4.5` (2025-06-30), `1.4.4`, `1.4.3`.

The plugin package itself is `// swift-tools-version:5.7`, `platforms: [.macOS("10.15.4")]`,
and depends on `swiftlang/swift-docc-symbolkit`. Its products:

```swift
.plugin(name: "Swift-DocC",         targets: ["Swift-DocC"]),          // intent: .documentationGeneration()
.plugin(name: "Swift-DocC Preview", targets: ["Swift-DocC Preview"]),  // verb: "preview-documentation"
```

The README states: "Swift 5.6 is required in order to run the plugin."

### `Package.swift` wiring — ours

Dependency only; **do not** add it to any target's `dependencies`:

```swift
dependencies: [
    // …
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
],
targets: [
    // The docs-only umbrella. No product needed unless we want it importable.
    .target(name: "TelegramKB"),
    // …
]
```

Verified README snippet (README.md:20-26) shows exactly this — the dependency added, and
`targets: [ // targets ]` left untouched.

Note the MCP SDK does the same thing (`modelcontextprotocol/swift-sdk` `Package.swift`
declares `.package(url: "https://github.com/swiftlang/swift-docc-plugin", branch: "main")`)
— a second real-world confirmation of the dependency-only pattern, though pinning to
`branch: "main"` as they do is not something we should copy.

### Commands — verified from README and `Articles/Generating Documentation for Hosting Online.md`

**Everything:**
```shell
swift package generate-documentation
```

**One target, to a directory** (the `--allow-writing-to-directory` is mandatory — the plugin
sandbox blocks writes into the package directory otherwise):
```shell
swift package --allow-writing-to-directory ./docs \
    generate-documentation --target TelegramKB --output-path ./docs
```

**Local preview** (needs `--disable-sandbox`, and is **limited to one target at a time**):
```shell
swift package --disable-sandbox preview-documentation --target TelegramKB
```
`preview-documentation --product OtherFramework` also works for a dependency's product.

**Static hosting build** (GitHub Pages or any dumb file server):
```shell
swift package --allow-writing-to-directory ./docs \
    generate-documentation --target TelegramKB \
    --disable-indexing \
    --output-path ./docs \
    --transform-for-static-hosting \
    --hosting-base-path telegram-kb
```

Flag semantics, from the article:

- **`--disable-indexing`** — the plugin builds an IDE navigator index by default; it "isn't
  relevant when hosting online". Pass this for any web build.
- **`--transform-for-static-hosting`** — "removes the need of setting any custom routing
  rules on your website, **as long as you're hosting the documentation at the root**".
- **`--hosting-base-path <path>`** — required when hosting at a sub-path. For GitHub Pages
  at `https://<user>.github.io/telegram-kb/`, the base path is the **repo name**:
  `telegram-kb`.

"Any flag passed after the `generate-documentation` plugin invocation is passed along to the
`docc` command-line tool" — so anything `docc` accepts is available here.

The plugin repo's own publish script `bin/update-gh-pages-documentation-site` uses precisely
this shape: `--allow-writing-to-directory …/gh-pages/docs`, `generate-documentation`,
`--target SwiftDocCPlugin`, `--transform-for-static-hosting`,
`--hosting-base-path swift-docc-plugin`. That is the pattern to copy verbatim.

Help: `swift package plugin generate-documentation --help`.

### `.spi.yml` — verified against SPIManifest's own docs and two live examples

Swift Package Index reads `.spi.yml` at the repo root. Minimum for docs
(`SPIManifest/Sources/SPIManifest/Documentation.docc/CommonUseCases.md`):

```yaml
version: 1
builder:
  configs:
    - documentation_targets: [TelegramKB]
```

Facts from that doc worth carrying:

- Docs build on **macOS by default**; override with `platform: ios` or `linux` (only those
  three are supported).
- "**Targets will appear in the order listed** in the selector dropdown … the first target
  will be the 'landing page target'." → list `TelegramKB` first.
- "Your package manifest `Package.swift` does **not** need to include the DocC plugin in
  order for us to host your DocC documentation. We will automatically inject it."
- Extra `docc` flags go via `custom_documentation_parameters: [--some-flag]`.
- Changes to `.spi.yml` on the default branch "may take up to 24 hours"; releases process
  immediately.
- Alternative if we host elsewhere: `external_links: { documentation: "https://…" }`.

Two live confirmations, both three-line files:
- `swift-docc-plugin/.spi.yml` → `documentation_targets: [SwiftDocCPlugin]`
- `modelcontextprotocol/swift-sdk/.spi.yml` → `documentation_targets: [MCP]`

---

## The docs-only umbrella target — VERIFIED, with the exact layout

**Question:** does the plugin work for a plain library target that has a `.docc` catalog and
essentially no public API?

**Answer: yes, and the swift-docc-plugin repository ships that exact target itself.**

`Package.swift` @ 1.5.0, verbatim, comment included:

```swift
// Empty target that builds the DocC catalog at /SwiftDocCPluginDocumentation/SwiftDocCPlugin.docc.
// The SwiftDocCPlugin catalog includes high-level, user-facing documentation about using
// the Swift-DocC plugin from the command-line.
.target(
    name: "SwiftDocCPlugin",
    path: "Sources/SwiftDocCPluginDocumentation",
    exclude: ["README.md"]
),
```

Its complete contents (GitHub trees API at tag 1.5.0):

```
Sources/SwiftDocCPluginDocumentation/
├── EmptyFile.swift                      (622 B — comments only)
├── README.md                            (excluded from the target)
└── SwiftDocCPlugin.docc/
    ├── Info.plist
    ├── SwiftDocCPlugin.md               ← root article, named after the TARGET
    ├── Generating Documentation for a Specific Target.md
    ├── Generating Documentation for Extended Types.md
    ├── Generating Documentation for Hosting Online.md
    ├── Previewing Documentation.md
    ├── Publishing to GitHub Pages.md
    └── Resources/
        ├── extended-type-example.png
        └── extended-type-example~dark.png
```

**`EmptyFile.swift` in full — note there is no code, and no dummy public symbol:**

```swift
// This source file is part of the Swift.org open source project
// … license header …

// This is an empty source file used to make SwiftDocCPluginDocumentation a valid
// documentation build target.
//
// SwiftDocCPluginDocumentation is an otherwise empty target that includes high-level,
// user-facing documentation about using the Swift-DocC Plugin from the command-line.
```

So the requirement is SwiftPM's ("a target needs at least one source file"), **not** DocC's.
DocC is perfectly happy producing a documentation archive whose symbol graph is empty; the
catalog's articles become the entire content.

`Info.plist` in the catalog — this is how they avoid the page being labelled "Framework":

```xml
<dict>
    <key>CDDefaultCodeListingLanguage</key><string>shell</string>
    <key>CDDefaultModuleKind</key><string>Command Plugin</string>
</dict>
```

Root article `SwiftDocCPlugin.md` begins:

```markdown
# ``SwiftDocCPlugin``

Produce Swift-DocC documentation for Swift Package libraries and executables.

@Metadata {
    @DisplayName("Swift-DocC Plugin")
}

## Overview
…
## Topics
### Getting Started
- <doc:Generating-Documentation-for-a-Specific-Target>
```

Note `<doc:>` links use the article filename with **spaces replaced by hyphens**.

### Recommended layout for `telegram-kb`

```
Sources/TelegramKB/
├── Empty.swift                          // comments only; explain why it exists
└── TelegramKB.docc/
    ├── Info.plist                       // CDDefaultModuleKind = "Project Documentation"
    ├── TelegramKB.md                    // # ``TelegramKB`` + @Metadata + ## Topics
    ├── Design.md
    ├── Roadmap.md
    ├── TechDebt.md
    └── Research.md                      // or a Topics group linking per-dependency notes
```

```swift
.target(name: "TelegramKB"),   // docs-only umbrella; catalog is auto-detected
```

Then `swift package --disable-sandbox preview-documentation --target TelegramKB`.

Two footnotes on this shape:
- The catalog is picked up automatically because it sits in the target's source directory;
  no `resources:` entry is needed.
- Put the `Empty.swift` explanation *in the file*, as Apple did. Someone will otherwise
  "clean up" the empty file and break the docs build. That is exactly the failure mode
  worth a line in `TechDebt.md`.

---

## Unverified

- **The plugin's behavior when a target has zero public symbols but non-comment code** —
  not probed; irrelevant, since the verified pattern has no code at all.
- **Whether `swift package generate-documentation` with no `--target` includes the
  docs-only target automatically.** The README says it generates "for all compatible
  targets defined in your package and its dependencies"; whether an empty target counts as
  "compatible" was not confirmed. Low risk — always pass `--target TelegramKB` explicitly,
  as Apple's own publish script does.
- **`CDDefaultModuleKind` accepted values** — Apple uses `"Command Plugin"`; the string
  appears free-form, but no schema was located. If a custom value renders oddly, fall back
  to omitting the key.
- **Swift 6.3 toolchain compatibility of plugin 1.5.0** — not probed. The package declares
  `swift-tools-version:5.7` and is swiftlang-maintained; low risk.
- **Whether `telegram-kb` will be public / on Swift Package Index at all** — if not, the
  `.spi.yml` section is informational only; SPI does not index private repos.
- **GitHub Pages specifics** — `Publishing to GitHub Pages.md` exists in the catalog
  (5581 B) but was not read; the commands above came from the sibling
  "Generating Documentation for Hosting Online" article and the repo's own publish script.
