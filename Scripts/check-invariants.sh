#!/usr/bin/env bash
# Invariants for the two-executable split.
#
# Stated POSITIVELY: `tgkb-mcp`'s transitive target closure must be exactly the allowlist below.
# A negative check ("TelegramKBIngestTDLib is absent") passes for the wrong reasons as the graph
# grows — it would still pass if someone added a heavyweight target that merely isn't that one.
# An allowlist fails loudly on any addition, which is the point.
#
# NOTE: `swift package generate-documentation` downloads the binary artifact REGARDLESS of traits
# (verified: research/spm-traits-binarytarget.md), so the global SPM cache is not a usable signal.
# Assert on this package's own build tree.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
note() { printf '  %-58s %s\n' "$1" "$2"; }

echo "== tgkb-mcp target closure (allowlist) =="
swift package describe --type json > /tmp/tgkb-describe.json 2>/dev/null || {
  echo "  swift package describe failed"; exit 1; }

python3 - <<'PY' || fail=1
import json, sys
ALLOWED = {"tgkb-mcp", "TelegramKBMCP", "TelegramKBStore", "TelegramKBModel"}
# A build-tool plugin runs at build time and links nothing into the binary, so it is not part of the
# closure. `describe` lists one among `target_dependencies` all the same (Swift 6.4), so plugins are
# told apart by type and allowlisted separately: a second plugin still fails loudly. Unlike the
# closure, the plugin list may come up short — a toolchain that left plugins out of the walk would
# otherwise fail here — and losing StampVersion fails the build-version check below instead.
ALLOWED_PLUGINS = {"StampVersion"}
d = json.load(open("/tmp/tgkb-describe.json"))
tgts = {t["name"]: t for t in d["targets"]}

seen, plugins, stack = set(), set(), ["tgkb-mcp"]
while stack:
    n = stack.pop()
    if n in seen or n in plugins or n not in tgts: continue
    if tgts[n].get("type") == "plugin":
        plugins.add(n)
        continue
    seen.add(n)
    stack += [x for x in tgts[n].get("target_dependencies", []) or []]

def check(label, found, allowed, exact=True):
    extra, missing = found - allowed, (allowed - found if exact else set())
    ok = not extra and not missing
    print(f"  {label + ' == allowlist':<58} {'OK' if ok else 'FAIL'}")
    print(f"    {label}: {sorted(found)}")
    if extra:   print(f"    UNEXPECTED: {sorted(extra)}")
    if missing: print(f"    MISSING:    {sorted(missing)}")
    return ok

ok = check("closure", seen, ALLOWED)
ok = check("build plugins", plugins, ALLOWED_PLUGINS, exact=False) and ok
sys.exit(0 if ok else 1)
PY

echo "== traits-off build hygiene =="
swift build >/dev/null 2>&1 || { echo "  build failed"; exit 1; }

xcf=$(find .build -name '*.xcframework' -maxdepth 6 2>/dev/null | wc -l | tr -d ' ')
[ "$xcf" -eq 0 ] && note "no xcframework extracted into .build" "OK" \
                 || { note "no xcframework extracted into .build" "FAIL ($xcf)"; fail=1; }

# Match the distinctive module name, never a bare `tdlib`: a case-insensitive `tdlib` grep
# matches Swift runtime symbols such as `_$ss26_stdlib_isOSVersionAtLeast…` ("s-tdlib-…").
for b in tgkb-mcp tgkb; do
  n=$(nm ".build/debug/$b" 2>/dev/null | grep -c 'TelegramKBIngestTDLib' || true)
  [ "$n" -eq 0 ] && note "$b free of TelegramKBIngestTDLib symbols" "OK" \
                 || { note "$b free of TelegramKBIngestTDLib symbols" "FAIL ($n)"; fail=1; }
done

echo "== build version =="
# Both binaries carry the string the StampVersion plugin generated for this build (#12), and it
# names this tree: the package version, HEAD's short hash, and -dirty when anything is uncommitted —
# so before a commit, -dirty is expected, and outside a git checkout, unknown. `serverInfo.version`
# is the same string, passed in by tgkb-mcp's main and pinned by the `serverInfoNamesTheBuild` test.
# The suffix is computed as the plugin computes it, git believed only when its worktree root is this
# package; keep the two in step.
top=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$(pwd -P)" ] \
   && commit=$(git rev-parse --short HEAD 2>/dev/null); then
  tree="$commit$([ -n "$(git status --porcelain | head -n 1)" ] && echo -dirty)"
else
  tree=unknown
fi
cli=$(.build/debug/tgkb --version 2>/dev/null); mcp=$(.build/debug/tgkb-mcp --version 2>/dev/null)
[ -n "$cli" ] && [ "$cli" = "$mcp" ] && note "tgkb --version == tgkb-mcp --version" "OK ($cli)" \
  || { note "tgkb --version == tgkb-mcp --version" "FAIL (${cli:-nothing} vs ${mcp:-nothing})"; fail=1; }
case "$cli" in
  *"+$tree") note "the version names this tree" "OK" ;;
  *) note "the version names this tree" "FAIL (expected …+$tree)"; fail=1 ;;
esac

echo "== seam contract =="
# The spec file is the source of truth; the test target needs its own copy as a resource.
# Two copies can drift, which is the TD-16 failure class, so police it here rather than hope.
if diff -q Spec/url-canonical/fixtures.json \
        Tests/TelegramKBModelTests/Fixtures/url-canonical-fixtures.json >/dev/null 2>&1; then
  note "spec fixtures == test resource" "OK"
else
  note "spec fixtures == test resource" "FAIL (drifted — re-copy from Spec/)"; fail=1
fi

# The golden file is self-contained (column 1 is the input), so this needs no corpus.
# It catches implementation drift that the 42 hand-written fixtures would not — which is
# exactly how the utm_refcode and IDN bugs were found in the first place.
if swiftc -O -o "$TMPDIR/check-golden" Sources/TelegramKBModel/URLCanonicaliser.swift \
        Scripts/GoldenCheck/main.swift 2>/dev/null; then
  if out=$("$TMPDIR/check-golden" Spec/url-canonical/corpus-canonical.tsv 2>&1); then
    note "golden corpus file" "OK$(printf '%s' "$out" | grep -oE '[0-9]+ rows' | head -1 | sed 's/^/ (/;s/$/)/')"
  else
    printf '%s\n' "$out" | head -20; note "golden corpus file" "FAIL"; fail=1
  fi
else
  swiftc -O -o "$TMPDIR/check-golden" Sources/TelegramKBModel/URLCanonicaliser.swift \
      Scripts/GoldenCheck/main.swift 2>&1 | head -5
  note "golden corpus file" "FAIL (compile error)"; fail=1
fi

[ "$fail" -eq 0 ] && echo "all invariants hold" || echo "INVARIANT VIOLATION"
exit $fail
