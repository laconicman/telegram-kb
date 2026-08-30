# Proposed addendum to the `xcframework-distribution` skill

**Status: a proposal for review, not an edit.** Nothing here has been applied to the skill.

Source of evidence: `Swiftgram/TDLibFramework` and `Swiftgram/TDLibKit`, examined against the
skill as it stands (`SKILL.md`, 156 lines, plus six `references/`). Findings in
`research/Swiftgram-TDLibFramework.md` and `research/Swiftgram-TDLibKit.md`; the traits result is
mine, in `research/spm-traits-binarytarget.md`.

---

## What I'd add, and what I'd reject

| # | Candidate | Verdict |
|---|---|---|
| 6 | **Large-artifact ergonomics** — unzip expansion, SPM's double storage, traits gating, slim builds | **ADD — the biggest real gap.** The skill covers large binaries *committed to a repo* and says nothing about large binaries *served as release assets*. |
| 4 | **Codegen ↔ artifact coupling via `.exact(...)`** | **ADD.** The most transferable single idea in either repo, and the *reason* is what makes it a rule. |
| 2 | **Upstream-tracking version scheme**, plus the pre-release pinning trap | **ADD.** The trap is not in the skill and silently breaks `from:` requirements. |
| — | **The DocC plugin bypasses trait gating** (folded into ADD 2) | **ADD.** Verified with an isolated probe; not documented anywhere I could find. |
| 7 | **CI reproducibility** | **ADD, selectively** — two concrete knobs and one honest limitation. |
| 1 | Vendored static C deps + duplicate symbols | **MOSTLY COVERED.** Add only the *vendor-vs-SDK decision rule*, which is missing. |
| 3 | Checksum published in release notes | **MOSTLY COVERED.** One clause, not a section. |
| 5 | Full slice matrix as a coverage checklist | **REJECT — already an iron rule** ("Rebuild slices when platforms add architectures; the artifact only serves what it contains"). Adding a checklist would restate it at greater length. |

Everything below is written to be general. Where the evidence is TDLib-specific I have said so
and cut it.

---

## ADD 1 — Large-artifact ergonomics → new subsection under **Distributing via SPM**

**Why it's a gap.** `references/spm-distribution.md` addresses size only for the
*commit-the-binary* route ("GitHub warns >50 MB and blocks >100 MB per file", "not for 200 MB
ones"). The GitHub-Release route — the one the skill recommends for versioned public artifacts —
has no size guidance at all. Yet that is exactly the route where size hurts most, and the costs
are non-obvious.

**The evidence.** I read the shipped `TDLibFramework.zip` central directory via an HTTP range
request, so these are measured bytes, not estimates:

- Download: **343 MiB**.
- Unzipped: **1.33 GiB** — a **3.97× expansion**.
- SwiftPM keeps **both** the `.zip` in `~/Library/Caches/org.swift.swiftpm/artifacts/` **and**
  the extracted `.xcframework`. Budget **≈1.7 GiB per resolved version**, times however many
  versions the cache retains.

**Proposed text:**

> **Size is a design input for a release-hosted `binaryTarget`, and the download figure
> understates it.** Consumers pay three times: the download, the unzipped bundle, and SwiftPM's
> cache — which retains the `.zip` *and* the extracted `.xcframework`. A 4× compressed-to-
> unzipped ratio is normal for fat static libraries, so a 350 MB release asset can cost a
> consumer ~1.7 GB per resolved version. Measure the unzipped total, publish it, and treat it as
> a number your consumers budget against — not an implementation detail.
>
> You can read a remote zip's uncompressed sizes **without downloading it** by range-requesting
> the tail and parsing the End-Of-Central-Directory record. Worth doing before you commit to an
> artifact you cannot easily shrink later.
>
> **Three levers, in order of leverage:**
>
> 1. **Ship per-platform artifacts alongside the universal one.** Parameterise the build by
>    platform *from the start* — if CI already shards per platform to parallelise, the slim
>    artifacts are a by-product, not new work. In the case studied, the single largest slice was
>    `watchOS` (245 MiB uncompressed) and the macOS-only slice was 13.5% of the bundle: a **7.4×
>    reduction** for a consumer who needs one platform.
> 2. **Gate the dependency behind a SwiftPM trait** (see ADD 2 below) so consumers who do not
>    need it never download it.
> 3. **Prune slices you cannot justify.** The artifact only serves what it contains, so this is
>    a deliberate trade against the existing iron rule, not a free win.

## ADD 2 — Traits gate `binaryTarget` downloads → new entry under **Distributing via SPM**

**Why it's a gap.** The word "trait" does not appear anywhere in the skill. Traits landed in
Swift 6.1 and are the cleanest available answer to "my package offers an optional feature backed
by a huge artifact".

**The evidence is mine and it has a control** (`research/spm-traits-binarytarget.md`). I gated a
`binaryTarget` pointing at an unreachable URL behind a trait:

| Command | Result | Artifacts |
|---|---|---|
| `swift build` | Build complete | 0 |
| `swift package show-dependencies` | `No external dependencies found` | — |
| `swift build --traits X` | `error: failed downloading …` | attempted |

The trait-enabled row is the control: it proves the artifact really would be fetched but for the
trait. Without it the passing rows would prove nothing.

**Proposed text:**

> **A SwiftPM trait (6.1+) gates a `binaryTarget` download completely.** With the trait off the
> dependency is not resolved, the artifact is not fetched, and `swift package show-dependencies`
> reports it **absent from the graph** — pruned, not merely unlinked. This is the sanctioned way
> to offer an optional feature backed by a large artifact without taxing every consumer:
>
> ```swift
> traits: [.trait(name: "Feature", description: "…; pulls a large prebuilt XCFramework.")],
> targets: [
>     .target(name: "Wrapper", dependencies: [
>         .product(name: "Big", package: "BigBinary", condition: .when(traits: ["Feature"]))
>     ])
> ]
> ```
>
> Verify it rather than assuming it, and **verify with a control** — point the `binaryTarget` at
> an unreachable URL and confirm the trait-*on* build fails to download. A trait-off build that
> merely succeeds proves nothing on its own; SwiftPM might simply be deferring the fetch.
>
> **The gating is not total, and the exception is easy to miss.** Verified with an isolated
> probe: `swift build`, `swift test` and `swift package resolve` all honour the trait, but
> **anything that extracts a symbol graph downloads the artifact anyway** — `swift package
> dump-symbol-graph`, `PackageManager.getSymbolGraph`, and therefore
> `swift package generate-documentation`. Both SwiftPM call sites hardcode
> `enableAllTraits: true` (deliberately, so docs cover trait-gated API), which un-prunes the
> dependency before binary artifacts are enumerated for download — and there is no opt-out. A docs CI job therefore pays the whole
> download even for a feature it is not documenting. Plan for it: run docs on release only, or
> keep that job's cache warm.
>
> Two more things the trait does **not** do:
> - **The dependency is still git-cloned.** Only the artifact download is gated; source checkout
>   is not. In the case measured, 119 MB of checkouts arrived with the trait off.
> - **Zero-byte placeholder directories still appear** under `.build/artifacts/<name>/`. A CI
>   check written as "is the artifact directory absent" will report a false violation. Assert on
>   *files* or on an extracted `.xcframework`, never on directory presence. (This cost me a
>   false alarm before I looked closely.)
>
> And note the real artifact lands in the **global** cache
> (`~/Library/Caches/org.swift.swiftpm/artifacts/`), not the package's `.build/` — so a
> per-package check cannot see it, and a global check cannot attribute it to one package.
>
> Caveats: Xcode resolves packages with its own logic and default-trait handling — check it
> separately. And a downstream package that enables the trait transitively reintroduces the
> artifact.

## ADD 3 — The codegen ↔ artifact coupling contract → **Distributing via SPM**, near the wrapper-package pattern

**Why it's a gap.** The skill covers the wrapper-package pattern but not the *version contract*
between a generated wrapper and the binary it wraps.

**Proposed text:**

> **When a Swift wrapper is generated from the same source revision that produced the binary,
> pin the binary with `.exact(...)` — never a range.**
>
> ```swift
> .package(url: "https://…/BigBinary", .exact("1.8.66-022d6020")),
> ```
>
> The failure mode is what makes this a rule rather than a preference. The generated Swift
> encodes a schema from one upstream commit; the binary implements that same commit's protocol.
> Mismatch them and **there is no compile error** — you get runtime decode failures, because a
> field the generated type requires is missing from what the library emits. `.exact` converts a
> silent runtime failure class into a resolver-level guarantee.
>
> If the wrapper's manifest is itself generated, interpolate the version into it from the same
> variable that tagged the binary, so the two cannot drift by hand.

## ADD 4 — Upstream-tracking tags, and the pre-release trap → **Distributing via SPM**, versioning

**Why it's a gap.** The skill's iron rules already say to "record provenance (source ref+commit,
flags, toolchain, checksums) beside the artifact". What is missing is putting that provenance
**in the tag**, and the SwiftPM consequence of doing so — which is a genuine trap.

**Proposed text:**

> **For an artifact that mirrors an upstream source of truth, encode the provenance in the tag:**
> `<upstream-version>-<upstream-short-sha>`, derived in CI rather than typed:
>
> ```yaml
> TDLIB_COMMIT=$(cd upstream && git rev-parse --short=8 HEAD)
> BASE_RELEASE_TAG=$UPSTREAM_VERSION-$TDLIB_COMMIT
> ```
>
> Add a collision guard (append the CI run number if the tag exists) so a rebuild of the same
> upstream commit cannot silently overwrite a published artifact whose checksum consumers have
> already pinned.
>
> **The trap: such tags are pre-release-shaped, and SwiftPM excludes pre-release versions from
> range requirements.** `from: "1.5.2"` or `.upToNextMinor` will **not** select
> `1.5.2-tdlib-1.8.66-022d6020` — resolution fails or silently picks nothing. Consumers must use
> `.exact(...)`. That is compatible with ADD 3 and usually correct anyway, but it must be stated,
> because the symptom (a version requirement that matches no version) does not point at the
> cause. Say so in your README; consumers will otherwise file it as a bug.

## ADD 5 — Two reproducibility knobs, and one honest limit → **the CI asset / `creating.md`**

**Proposed text:**

> - **`ZERO_AR_DATE=1`** when building static archives. `ar` records mtimes by default; zeroing
>   them is the single highest-value input to byte-reproducible `.a` files.
> - **Make CI cache keys content-hashes, not names** — hash the build scripts and patches, and
>   include the toolchain identifier (e.g. `DEVELOPER_DIR`) so an Xcode bump invalidates the
>   cache instead of silently reusing an artifact built by a different compiler.
> - **Know what you have not achieved.** Pinning the runner image, the Xcode path and the build
>   tool gets you a *repeatable* build, not a *reproducible* one. If the final step is a plain
>   `zip` — which records mtimes — **the published checksum cannot be reproduced from source even
>   with identical inputs.** The checksum then authenticates *those exact bytes from that
>   publisher*, which is a weaker claim than "anyone can rebuild this and get the same hash".
>   Don't let a pinned toolchain imply the stronger claim. Closing the gap needs a deterministic
>   zip step (`SOURCE_DATE_EPOCH`, sorted entries, zeroed timestamps) and ideally build
>   attestation.

## ADD 6 — Vendor-vs-SDK decision rule → one paragraph in **Wrapping prebuilt C/C++ static libraries**

**Why only a paragraph.** The duplicate-symbol *hazard* is already covered — `spm-distribution.md`
warns that "Two *independent* binary packages embedding the same static lib still collide at link
time", and `c-cpp-wrapping.md` even carries an OpenSSL-vs-Darwin-TLS verification check. What is
absent is guidance on **which** dependencies to vendor.

**Proposed text:**

> **Vendor a C dependency only when its exact version is part of your ABI; otherwise take it from
> the SDK.** The case studied vendors OpenSSL as static `libssl.a`/`libcrypto.a` built from
> source — its struct layouts are baked into the compiled code — but takes **zlib and libc++ from
> the platform SDK** via `libz.tbd`/`libc++.tbd`. The rule that produces this split: vendor what
> is version-sensitive and not guaranteed present; link what the OS ships and keeps
> ABI-stable. Every vendored library is a future duplicate-symbol collision with whatever the
> host app links.

## ADD 7 — One clause on checksum publication → **Distributing via SPM**

> Publish the `swift package compute-checksum` output **in the release body**, not only in your
> own `Package.swift`. It lets a downstream author — or a code generator writing a manifest —
> pin `.binaryTarget(checksum:)` from the release page without downloading the artifact first.
> For a 343 MiB asset that is the difference between a manifest edit and a coffee break.

---

## Rejected, with reasons

- **Slice-matrix coverage checklist.** Already carried by the iron rule about rebuilding slices.
  A checklist restates it at greater length and would date faster than the rule.
- **Anything about TDLib's JSON protocol, `tl2swift`, or Tuist specifics.** Project-specific.
  The general form of the codegen point is ADD 3; the general form of the platform-parameterised
  build is inside ADD 1.
- **"Widely-used artifacts ship essentially unsigned."** True in this case — only the four
  simulator slices carry `_CodeSignature` — but it is an observation about one publisher, not
  guidance. The skill's `signing-and-privacy.md` should not be softened on the strength of it.

## Unverified

- I have not run the skill's own evals against these changes.
- The traits result is verified for a **path** dependency; a remote `.package(url:)` may still
  perform a git checkout even when products are pruned. The *artifact* download is confirmed
  gated, which is the part that matters for size, but the wording above should not be read as
  covering checkout cost.
- Slim-build feasibility is read from `Project.swift` and CI configuration; I did not execute a
  macOS-only build to confirm the artifact it produces is usable.
