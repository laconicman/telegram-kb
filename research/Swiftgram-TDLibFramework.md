# `Swiftgram/TDLibFramework` — prebuilt TDLib XCFramework

**Provenance.** All facts below traced to the GitHub REST API and to files fetched from
`raw.githubusercontent.com/Swiftgram/TDLibFramework/main/...` on **2026-08-23**.
Repo tree read at commit **`3b19a6205abf5aa76a214dc35af0b01d3a12659e`** (branch `main`,
`GET /repos/Swiftgram/TDLibFramework/git/trees/main?recursive=1`, `truncated: false`).

Marker convention: **Verified** = quoted from a repo file or a GitHub API response.
**Unverified** = anything else.

---

## HEADLINE ANSWERS

| Question | Answer | Status |
|---|---|---|
| Real artifact size | **359,822,073 bytes = 343.2 MiB = 359.8 MB** for `TDLibFramework.zip` (tag `1.8.66-022d6020`). The brief's "~300 MB" is **low by ~15–20 %.** | **Verified** — GitHub release asset API |
| OpenSSL + zlib statically vendored? | see §OpenSSL | |
| macOS-slim build feasible? | see §Slim | |

---

## 1. Releases, sizes, and the version-naming scheme — **VERIFIED**

`GET https://api.github.com/repos/Swiftgram/TDLibFramework/releases?per_page=8`, fetched
2026-08-23. Every release is authored by `github-actions[bot]` — i.e. releases are fully
automated, none are hand-cut.

| Tag | Published | `TDLibFramework.zip` size | downloads |
|---|---|---|---|
| **`1.8.66-022d6020`** (latest) | 2026-07-18T00:21:18Z | **359,822,073 B — 343.2 MiB** | 967 |
| `1.8.66-d8d46dfa` | 2026-07-17T00:37:44Z | 359,809,212 B — 343.1 MiB | 95 |
| `1.8.66-1b08c83b` | 2026-07-16T00:18:47Z | 359,790,045 B — 343.1 MiB | 30 |
| `1.8.66-07d3a097` | 2026-07-15T01:22:29Z | 359,793,182 B — 343.1 MiB | 53 |
| `1.8.65-a17f87c4` | 2026-06-13T22:38:09Z | 354,781,804 B — 338.3 MiB | 747 |
| `1.8.65-062f2605` | 2026-06-12T17:35:36Z | 354,781,823 B — 338.3 MiB | 57 |
| `1.8.65-d6debbb2` | 2026-06-11T23:08:33Z | 354,781,996 B — 338.3 MiB | 83 |
| `1.8.64-e0943d06` | 2026-05-22T19:02:08Z | 349,681,235 B — 333.5 MiB | 664 |

**Size correction, stated plainly.** The brief's working assumption of ~300 MB is wrong.
The zip is **343 MiB / 360 MB**, and it is *growing* — 333.5 → 338.3 → 343.2 MiB across
three upstream minor versions in three months, roughly **+5 MiB per TDLib minor release**.
The *unzipped* xcframework is necessarily larger still (an unmeasured figure — see
§Unverified). Budget for **≥ 350 MiB downloaded and ≥ 350 MiB resident per resolved
version** in `~/Library/Caches/org.swift.swiftpm` **plus** a second copy in the build
directory.

**Version-naming scheme — VERIFIED as `<upstream-version>-<upstream-commit-sha8>`.**
Every tag is `1.8.66-022d6020`: TDLib's own version, a hyphen, and the first 8 hex chars of
the `tdlib/td` commit the artifact was built from. There is no independent semver for the
framework repo itself. Release body, verbatim (tag `1.8.66-022d6020`):

```
XCFramework based on TDLib-1.8.66 commit [022d6020](https://github.com/tdlib/td/tree/022d6020)

ZIP Checksum `be9848d3e496582a734f2c6b96e4285ebb1bb468e3d10595a79e82958a5ee48e`

GitHub Actions [Workflow](https://github.com/Swiftgram/TDLibFramework/actions/runs/29622192497)
```

Three things that body proves at once:
1. **The checksum IS published in the release notes** — so a downstream author can write a
   `.binaryTarget(checksum:)` *without downloading 343 MiB to run
   `swift package compute-checksum`*. See §Checksum for whether it is the SPM checksum.
2. **Provenance is machine-recorded** — the exact upstream commit is linked, not merely
   implied by the tag.
3. **The producing CI run is linked by ID**, so the build log for any shipped artifact is
   retrievable as long as GitHub retains it.

**Release cadence is daily-ish and upstream-tracking.** Four releases in four days
(15,16,17,18 July) all on TDLib 1.8.66 with different SHAs — this repo re-releases whenever
`tdlib/td` master moves, not when a TDLib version is tagged. Consequence for us: **pinning
must be to an exact tag, never to a range**, or a `swift package update` will silently pull
a different upstream TDLib commit.

_(continued — research in progress)_

---

## 2. THE NUMBER THAT MATTERS: unzipped size is **1.33 GiB**, not 343 MiB — **VERIFIED**

I read the shipped artifact's **zip central directory** without downloading it, by issuing an
HTTP `Range: bytes=351433465-` request for the last 8 MiB of
`https://github.com/Swiftgram/TDLibFramework/releases/download/1.8.66-022d6020/TDLibFramework.zip`
and parsing the End-Of-Central-Directory record (133 entries, CD at offset 359,801,003).
These are therefore measurements of the **actual bytes Swiftgram shipped**, not estimates.

| Slice | uncompressed | in the zip |
|---|---|---|
| `watchos-arm64_arm64_32_armv7k` | **245.2 MiB** | 68.4 MiB |
| `macos-arm64_x86_64` | **183.4 MiB** | 44.3 MiB |
| `xros-arm64_x86_64-simulator` | 169.7 MiB | 41.4 MiB |
| `watchos-arm64_x86_64-simulator` | 169.7 MiB | 41.4 MiB |
| `ios-arm64_x86_64-simulator` | 169.7 MiB | 41.4 MiB |
| `tvos-arm64_x86_64-simulator` | 169.6 MiB | 41.4 MiB |
| `ios-arm64` | 85.2 MiB | 21.6 MiB |
| `tvos-arm64` | 85.2 MiB | 21.6 MiB |
| `xros-arm64` | 85.2 MiB | 21.6 MiB |
| **TOTAL** | **1362.98 MiB ≈ 1.33 GiB** | **343.11 MiB** |

> **Correct the brief in two places, not one.**
> - The download is **343 MiB (359.8 MB)**, not ~300 MB.
> - **The on-disk cost after SPM unzips it is ~1.33 GiB**, a 3.97× expansion the brief does
>   not account for at all. This is the number that should drive the architecture decision.
>
> And SPM keeps **two** copies: the downloaded `.zip` in
> `~/Library/Caches/org.swift.swiftpm/artifacts/` **and** the extracted `.xcframework` in the
> build directory. Budget **≈1.7 GiB per resolved version**, and multiply by the number of
> versions the cache retains.

**The single largest slice is `watchos` (245 MiB), which we will never run.** Our MCP server
is macOS-only. **`macos-arm64_x86_64` is 183.4 MiB raw / 44.3 MiB zipped — 13.5 % of the
uncompressed bundle and 12.9 % of the download.** A macOS-only artifact would be roughly a
**7.4× reduction in download and 7.4× on disk.** See §6.

## 3. Build pipeline — the actual files — **VERIFIED**

Read directly from the repo at `main` (`3b19a620`). The pipeline is a **three-stage fan-out
per platform, then one merge**, and each stage is a named script.

| File | Role |
|---|---|
| `.github/workflows/ci.yml` | Orchestrator. 9-way `matrix.platform` fan-out → merge → test → release. |
| `.github/workflows/build.yml` | Reusable (`on: workflow_call`) per-platform workflow. Three jobs: `build-openssl` → `build-tdlib` → `build-framework`. |
| `.github/actions/download-and-unpack-xcarchive/action.yml` | Composite action used 9× by the merge job. |
| `.github/actions/install-visionos-runtime/action.yml` | Works around `actions/runner-images#10692` (visionOS runtime absent). |
| `builder/openssl-patches/0001-build-openssl.patch` | Patches TDLib's own `example/ios/build-openssl.sh`. |
| `builder/tdlib-patches/0001-build.patch` | Patches TDLib's own `example/ios/build.sh`. |
| `builder/Project.swift` | **Tuist** manifest — declares one framework target per platform and wires in the static `.a` files. |
| `builder/patch-headers.sh` | `sed`s `#include "td/telegram/X"` → `#include "X"` so headers resolve inside a framework. |
| `builder/build-framework.sh` | `xcodebuild archive` for one platform (maps platform name → SDK). |
| `builder/merge-frameworks.sh` | `xcodebuild -create-xcframework` over all 9 archives. |
| `builder/xcodeproj/module.modulemap`, `td.h`, `Info.plist` | The module map + umbrella header. |
| `scripts/swift_package_generator.py` | **Generates `Package.swift`.** |
| `scripts/extract_td_version.py`, `scripts/extract_os_version.py` | Version/deployment-target extraction. |
| `scripts/test.sh` | Post-merge smoke test per platform. |
| `.gitmodules` | `td` is a git **submodule** of `https://github.com/tdlib/td`. |
| `.mise.toml` | `tuist = "4.10.2"` — pinned. |

**Note what is *not* here: there is no `CMakeLists.txt` or bespoke build of TDLib itself.**
Swiftgram *reuses TDLib's own* `example/ios/build.sh` and `example/ios/build-openssl.sh`,
applying two small patches to make them (a) accept a platform argument and (b) stop
short of building an xcframework, leaving the installed `.a` tree for Tuist to consume.
`builder/tdlib-patches/0001-build.patch`, the removal hunk, verbatim:

```diff
-produced_dylibs=(install-*/lib/libtdjson.dylib)
-xcodebuild_frameworks=()
-...
-# Make xcframework
-xcodebuild -create-xcframework \
-    "${xcodebuild_frameworks[@]}" \
-    -output "libtdjson.xcframework"
```

That is the design decision in one hunk: **upstream's dynamic-`libtdjson.dylib` xcframework
path is deleted, and replaced by a static-archive path of Swiftgram's own.**

## 4. Slice matrix — **VERIFIED from the artifact itself**

Nine slices, exact directory names read out of the shipped zip:

```
ios-arm64
ios-arm64_x86_64-simulator
macos-arm64_x86_64
tvos-arm64
tvos-arm64_x86_64-simulator
watchos-arm64_arm64_32_armv7k
watchos-arm64_x86_64-simulator
xros-arm64
xros-arm64_x86_64-simulator
```

Cross-checked against `ci.yml`'s matrix, which lists the same nine names in Swiftgram's own
spelling:

```yaml
      matrix:
        platform: [iOS, iOS-simulator, macOS, watchOS, watchOS-simulator, tvOS, tvOS-simulator, visionOS, visionOS-simulator]
```

and against `merge-frameworks.sh`'s invocation in `ci.yml`:

```yaml
        run: ./merge-frameworks.sh "iOS iOS-simulator macOS watchOS watchOS-simulator tvOS tvOS-simulator visionOS visionOS-simulator"
```

**Points worth noting:**
- **`macos-arm64_x86_64` is a universal (Intel + Apple silicon) slice.** Our macOS-only
  consumer gets Intel support it does not need — a further slimming lever if we ever build
  our own (drop `x86_64` → roughly halve 183 MiB).
- **watchOS device slice carries three architectures** (`arm64`, `arm64_32`, `armv7k`),
  which is why it is the fattest slice at 245 MiB.
- **Mac Catalyst is NOT shipped.** No `ios-*-maccatalyst` slice exists. A Catalyst consumer
  would hit *"no library for this platform was found"*.
- **DriverKit, Linux, and any non-Apple platform: not applicable / absent.**
- The generated `Package.swift` `platforms:` list declares only `.iOS(.v12) .macOS(.v10_15)
  .watchOS(.v4) .tvOS(.v12)` — **visionOS is absent from the manifest** even though two
  visionOS slices ship, because the manifest is pinned at `swift-tools-version:5.3`, which
  predates `.visionOS`. Harmless, but it means visionOS deployment target comes from
  `extract_os_version.py`'s hardcoded fallback: `if platform == "visionOS": return "1.0"`.

## 5. OpenSSL and zlib — **VERIFIED, and the answer is split**

> **OpenSSL: statically vendored INTO the xcframework. zlib and libc++: NOT vendored —
> taken from the host SDK.**

### OpenSSL — vendored, built from source, linked in as static archives

Three independent pieces of evidence.

**(a) `builder/Project.swift` links `libssl.a` and `libcrypto.a` as target dependencies:**

```swift
    for opensslInstallLib in [
        "libssl.a",
        "libcrypto.a",
    ] {
        tdDeps.append(
            .library(
                path: "\(tdIOSPath)/third_party/openssl/\(platformString + suffix)/lib/\(opensslInstallLib)",
                publicHeaders: "",
                swiftModuleMap: nil
            )
        )
    }
```

**(b) The product is a static Mach-O**, so those archives are *absorbed into* the framework
binary rather than dyld-loaded — `builder/Project.swift`, project-level `base` settings:

```swift
            "MACH_O_TYPE": "staticlib",
```

**(c) CI builds OpenSSL from source in a dedicated job**, `.github/workflows/build.yml`:

```yaml
  build-openssl:
    runs-on: macos-15
    ...
      - name: Build Openssl
        if: steps.cache-openssl.outputs.cache-hit != 'true'
        run: |
          cd td/example/ios
          ./build-openssl.sh $PLATFORM
```

and `builder/openssl-patches/0001-build-openssl.patch` patches that upstream script to take
the platform as `$1`. The OpenSSL provenance is TDLib's own vendored
`Python-Apple-support` build — confirmed by the comment the generator writes into
`Package.swift`: `// Minimum versions for openssl - td/example/ios/Python-Apple-support/Makefile`.

**Consequence — the duplicate-symbol failure mode is real for this artifact.** Because
`libcrypto.a`/`libssl.a` are archived into a **static** framework, a host that *also* links
OpenSSL (BoringSSL via gRPC, `swift-nio-ssl`, another vendored OpenSSL) links two copies of
the same C symbol namespace. Whether it manifests as a hard duplicate-symbol link error or as
silent one-wins-at-random behaviour depends on link order and `-ObjC`/`-all_load` flags.
*Our exposure: `telegram-kb` is macOS-only and does not currently link OpenSSL — but if we
ever add a dependency that does, this is the first thing to check.* **Unverified:** whether
the symbols are prefixed/hidden — I did not download and `nm` the binary. See §Unverified.

### zlib and libc++ — from the host SDK, NOT vendored

`builder/Project.swift`, `getPlatformDependencies`:

```swift
    case .macOS:
        return [
            .sdk(name: "libz.tbd", type: .library),
            .sdk(name: "libc++.tbd", type: .library),
        ] + tdDeps
```

`.tbd` is a **text-based stub** — it links against the OS-provided `libz.dylib` /
`libc++.dylib`, it does not embed anything. Reinforced at the package level in the generated
`Package.swift`, which puts the same two on the *wrapper* target so every platform gets them
(the Tuist manifest only adds them for iOS-device and macOS):

```swift
        .target(
            name: "TDLibFrameworkWrapper",
            dependencies: [.target(name: "TDLibFramework")],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
            ]
        ),
```

**That `TDLibFrameworkWrapper` target exists precisely because `.binaryTarget` cannot carry
`linkerSettings`.** It is a real, empty Swift target (`Sources/TDLibFrameworkWrapper/Empty.swift`,
166 bytes) whose only job is to hang `-lc++ -lz` off something SPM will honour. This is the
canonical wrapper-package workaround, in the wild.

Also note the SQLite question answers itself: `libtdsqlite.a` is in the linked-archive list,
so **TDLib's SQLite is vendored too** and is *not* the system `libsqlite3`.

## 6. A macOS-only / slimmed build — **FEASIBLE, and it is a first-class path in their own scripts**

**Verdict: yes, and it requires no forking of build logic — only running the existing scripts
with one argument.** Every layer of the pipeline is already parameterised by platform,
*because that is how their CI shards the work*.

**(a) The Tuist manifest reads the platform list from an environment variable, with the
full list only as a default** — `builder/Project.swift`:

```swift
func getBuildPlatforms() -> [String] {
return Environment.platform.getString(default: "iOS,iOS-simulator,macOS,watchOS,watchOS-simulator,tvOS,tvOS-simulator,visionOS,visionOS-simulator").components(separatedBy: ",")
}
```

`Environment.platform` is Tuist's `TUIST_PLATFORM`. CI sets it per-shard:

```yaml
          cd builder
          TUIST_PLATFORM=$PLATFORM tuist generate
```

So `TUIST_PLATFORM=macOS tuist generate` produces a project containing **exactly one target**.

**(b) The TDLib and OpenSSL build scripts already take a platform argument** — that is the
entire point of both patches. `0001-build.patch`:

```diff
-platforms="macOS iOS watchOS tvOS visionOS"
+platforms="$1"
+minimum_deployment_version="$2"
```

`0001-build-openssl.patch`:

```diff
-platforms="macOS iOS watchOS tvOS visionOS"
+platforms="$1"
```

**(c) `build-framework.sh` and `merge-frameworks.sh` both take the platform list as `$1`**
and `merge-frameworks.sh` loops over whatever it is given.

**The macOS-only recipe, therefore:**

```sh
git clone --recursive https://github.com/Swiftgram/TDLibFramework
cd TDLibFramework/td && git apply ../builder/openssl-patches/*.patch ../builder/tdlib-patches/*.patch
cd example/ios && ./build-openssl.sh macOS && ./build.sh macOS 10.15
cd ../../../builder && ./patch-headers.sh
TUIST_PLATFORM=macOS tuist generate      # tuist 4.10.2, per .mise.toml
./build-framework.sh macOS
./merge-frameworks.sh "macOS"
python3 ../scripts/swift_package_generator.py --path ./build/TDLibFramework.xcframework
```

The last line is not improvised — **it is exactly what their own test job runs** to point
`Package.swift` at a local artifact instead of a URL:

```yaml
      - name: Update Package.swift with local .xcframework
        run: python3 scripts/swift_package_generator.py --path ${{ env.ARTIFACT_DIR }}/TDLibFramework.xcframework
```

**Expected payoff: ~183 MiB on disk instead of ~1.33 GiB (7.4×), ~44 MiB download instead of
343 MiB.** Drop `x86_64` from the macOS slice and it roughly halves again.

**Cost, stated honestly:** you now own a build. The macOS TDLib compile is the long pole —
CI gives the *test* job a 70-minute timeout and caches both OpenSSL and the TDLib install
tree with `actions/cache` plus `ccache`, which tells you an uncached build is expensive.
*Exact wall-clock for a macOS-only build is **Unverified** — I did not run it.* You also
inherit responsibility for re-running it on every TDLib bump, which Swiftgram currently does
for you daily.

**Is a slimmed build *offered*? No.** There is exactly one published artifact,
`TDLibFramework.zip`, all-platforms. No `-macos` variant, no per-platform assets — confirmed
across all 8 releases inspected via the API (each has exactly one asset). `.binaryTarget`
cannot select a subset of slices at resolve time, so a consumer cannot slim it from the
manifest either.

## 7. Code signing — **VERIFIED, and the answer is "essentially not signed"**

**There is no `codesign` invocation anywhere in the repo.** Neither `ci.yml`, `build.yml`,
`build-framework.sh`, nor `merge-frameworks.sh` calls it, and no signing identity or
certificate secret appears in the workflows. The only secret referenced is
`MISE_GITHUB_TOKEN` (for tool downloads) plus the default `GITHUB_TOKEN`.

Reading the shipped bundle confirms the consequence — only **four** of nine slices contain a
`_CodeSignature` directory:

| Signed (`_CodeSignature/` present) | Unsigned |
|---|---|
| `ios-arm64_x86_64-simulator` | `ios-arm64` |
| `tvos-arm64_x86_64-simulator` | `macos-arm64_x86_64` |
| `watchos-arm64_x86_64-simulator` | `tvos-arm64` |
| `xros-arm64_x86_64-simulator` | `watchos-arm64_arm64_32_armv7k` |
| | `xros-arm64` |

That distribution is the signature of **incidental ad-hoc signing by `xcodebuild` for
simulator destinations**, not of a deliberate signing step — a real signing step would cover
all nine, and would sign the `.xcframework` bundle itself (there is no top-level
`_CodeSignature` either). **The `macos-arm64_x86_64` slice we care about is unsigned.**

**Practical impact for us: low but not zero.** Xcode 15+ can verify an XCFramework's origin
when it *is* signed; this one cannot be verified that way, so the **checksum is the only
integrity control** (§8). For a macOS CLI/MCP binary, an unsigned static framework linked
into our own signed product is fine — our product's signature covers the linked code. It
would matter more for a dynamic framework embedded in an app bundle. **Unverified:** whether
the ad-hoc simulator signatures survive `zip`/`unzip` intact — not probed.

Also absent: **no dSYMs.** Zero entries matching `dSYM` in the 133-entry central directory,
and `merge-frameworks.sh` passes no `-debug-symbols`. Crashes inside TDLib will not
symbolicate beyond exported symbol names. Also no privacy manifest (`PrivacyInfo.xcprivacy`)
anywhere in the bundle — relevant for App Store submission, irrelevant for our macOS tool.

## 8. Checksum and release automation — **VERIFIED, and it is exemplary**

**The published checksum IS the SPM `binaryTarget` checksum, byte-identical.** Proven by
comparing two independent sources:

- Release body for `1.8.66-022d6020`:
  `` ZIP Checksum `be9848d3e496582a734f2c6b96e4285ebb1bb468e3d10595a79e82958a5ee48e` ``
- `Package.swift` on `main`:
  ```swift
        .binaryTarget(
            name: "TDLibFramework",
            url: "https://github.com/Swiftgram/TDLibFramework/releases/download/1.8.66-022d6020/TDLibFramework.zip",
            checksum: "be9848d3e496582a734f2c6b96e4285ebb1bb468e3d10595a79e82958a5ee48e"
        ),
  ```

They match. And it is produced by the sanctioned tool, `ci.yml`:

```yaml
      - name: Get Checksum
        run: |
          ARTIFACT_CHECKSUM=$(swift package compute-checksum ${{ env.ARTIFACT_PATH }})
          echo "ARTIFACT_CHECKSUM=$ARTIFACT_CHECKSUM" >> $GITHUB_ENV
```

**So a downstream author can pin `.binaryTarget(checksum:)` from the release page alone,
without downloading 343 MiB.** That is a genuinely useful property and the strongest
candidate in the §3 addendum.

**The full release automation, in order** (`ci.yml`, job `create-release`):

1. Derive `TDLIB_COMMIT=$(cd td && git rev-parse --short=8 HEAD)` and
   `TDLIB_VERSION=$(python3 scripts/extract_td_version.py td/CMakeLists.txt)`.
2. `BASE_RELEASE_TAG=$TDLIB_VERSION-$TDLIB_COMMIT` — **the version scheme, in code.**
3. **Collision guard** — if the tag already exists, append the run number:
   ```yaml
          if gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$BASE_RELEASE_TAG" > /dev/null 2>&1; then
            RELEASE_TAG=$BASE_RELEASE_TAG-$GITHUB_RUN_NUMBER
            HAS_TAG_SUFFIX=true
          fi
   ```
   So a tag may be `1.8.66-022d6020-1234`. **Do not assume the tag is always exactly two
   hyphen-separated parts.**
4. `swift package compute-checksum`.
5. **Regenerate and self-commit `Package.swift`**, then push to `main`:
   ```yaml
          python3 scripts/swift_package_generator.py --url "…/$RELEASE_TAG/TDLibFramework.zip" --checksum $ARTIFACT_CHECKSUM
          git add Package.swift || true
          git commit -m "[no ci] Bump TDLib ${{ env.RELEASE_TAG }}" || true
          git push origin main || true
   ```
   Note `[no ci]` and the `|| true` on every git step — the bump is best-effort and must not
   fail the release.
6. `gh release create "$RELEASE_TAG" "$ARTIFACT_PATH" --target main --notes-file release.md`
   with the notes template that embeds upstream commit, checksum, and workflow-run link.

**Ordering guarantee worth calling out: `create-release` `needs: [tests]`, and `tests`
`needs: [merge-xcframework]`.** Nothing is published that has not been smoke-tested on
macOS + four simulators. Tests run with a 20-minute timeout and **up to three attempts**:

```yaml
          gtimeout ${{ env.TEST_TIMEOUT }} ./scripts/test.sh … \
            || gtimeout ${{ env.TEST_TIMEOUT }} ./scripts/test.sh … \
            || gtimeout ${{ env.TEST_TIMEOUT }} ./scripts/test.sh …
```

(That retry pattern is a smell — it converts a flaky test into a green one — but it does mean
a *totally* broken artifact cannot ship.)

## 9. Reproducibility aids in CI — **VERIFIED**

Genuinely present:

| Aid | Evidence |
|---|---|
| **Toolchain pinned to an exact Xcode path** | `DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer` in `ci.yml` `env:` — with a maintainer comment that it must be duplicated in the matrix because "envs are not evaluated in matrixes". |
| **Runner image pinned** | `runs-on: macos-15` on every job. |
| **Build tool pinned** | `.mise.toml` → `tuist = "4.10.2"`, installed via `mise install`. |
| **Upstream pinned by submodule** | `.gitmodules` → `td` at a specific commit; the SHA is read back with `git rev-parse --short=8 HEAD` and becomes part of the tag. |
| **Deterministic archive timestamps** | `ZERO_AR_DATE=1 make -j3 install` — inherited from TDLib's `build.sh` and preserved (unmodified) through Swiftgram's patch context. This is the standard `ar` mtime-zeroing knob, and it is the single most important input to byte-reproducible static archives. |
| **Provenance recorded in the release** | upstream commit URL + checksum + workflow-run URL in every release body. |
| **Cache keys are content-hashes, not names** | `key: openssl-v1-${{ env.PLATFORM }}-${{ inputs.developer-dir }}-${{ hashFiles('td/example/ios/build-openssl.sh', 'td/example/ios/Python-Apple-support.patch', 'builder/openssl-patches/**') }}` — and the tdlib cache hashes `td/**` plus the patches. A change to any input invalidates the cache rather than silently reusing a stale artifact. Note `developer-dir` is *in* the key, so an Xcode bump also invalidates. |
| **ccache stats/logs archived per build** | `ccache --show-stats --verbose` and the ccache log are zipped and uploaded as artifacts on `always()`. Observability, not reproducibility as such, but it makes cache-related nondeterminism diagnosable. |
| **Dependabot + auto-merge** | `.github/dependabot.yml` + `dependabot_merge.yml`; and CI explicitly skips dependabot (`if: ${{ github.actor != 'dependabot[bot]' }}`) so a bot cannot trigger a release. |

**What is missing for true reproducibility:** no `SOURCE_DATE_EPOCH`, no deterministic-zip
step (plain `zip --symlinks -r`, which records mtimes — so **the checksum is not
reproducible from source even given identical inputs**), no SBOM, no build attestation /
provenance signing (`actions/attest-build-provenance` is not used), and no signing identity.
The chain of custody is "trust Swiftgram's GitHub account + this checksum".

---

## Verified / Unverified ledger

**Verified** (all from the repo at `3b19a620`, the GitHub REST API, or the artifact's own
zip central directory, fetched 2026-08-23):
- Zip size 359,822,073 B; uncompressed 1362.98 MiB; per-slice sizes.
- The 9 slice names and their architectures.
- OpenSSL vendored as static `.a` into a `MACH_O_TYPE=staticlib` framework; zlib/libc++ from
  SDK `.tbd`; SQLite vendored (`libtdsqlite.a`).
- Version scheme `<td-version>-<td-sha8>`, plus the `-$GITHUB_RUN_NUMBER` collision suffix.
- Published checksum == `Package.swift` checksum == `swift package compute-checksum` output.
- `Package.swift` is generated by `scripts/swift_package_generator.py` and self-committed.
- No `codesign` step; 4/9 slices ad-hoc signed, `macos-*` unsigned; no dSYMs; no privacy manifest.
- Per-platform parameterisation via `TUIST_PLATFORM` + `$1` platform args at every layer.
- Xcode 16.4 / macos-15 / tuist 4.10.2 pinning; `ZERO_AR_DATE=1`; content-hash cache keys.

**Unverified — could not probe:**
1. **Whether OpenSSL symbols are namespaced/hidden** in the shipped binary. Would require
   downloading 343 MiB and running `nm -gU`. The duplicate-symbol risk is therefore
   *structurally* real but its *severity* is unmeasured.
2. **Wall-clock time for a from-scratch macOS-only build.** Not run. The 70-minute test
   timeout and the ccache+actions/cache layering imply "expensive", nothing more precise.
3. **Whether the macOS slice's `x86_64` half can be dropped cleanly** — plausible via
   `ARCHS=arm64` on the archive step, but not tested.
4. **Whether ad-hoc simulator signatures survive the zip round-trip.**
5. **TDLib 1.8.66's own OpenSSL version.** It comes from TDLib's vendored
   `Python-Apple-support`; I did not chase the submodule to a version number.
6. **Whether `swift build` on a macOS-only consumer actually skips downloading non-macOS
   slices.** It does not — `.binaryTarget` fetches the whole zip. Stated as fact in §6 by
   reasoning from the manifest, not from an observed resolve. Treat the 1.33 GiB as the
   operative number until measured locally.
