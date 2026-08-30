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
d = json.load(open("/tmp/tgkb-describe.json"))
tgts = {t["name"]: t for t in d["targets"]}

seen, stack = set(), ["tgkb-mcp"]
while stack:
    n = stack.pop()
    if n in seen or n not in tgts: continue
    seen.add(n)
    stack += [x for x in tgts[n].get("target_dependencies", []) or []]

extra = seen - ALLOWED
missing = ALLOWED - seen
ok = not extra and not missing
print(f"  {'closure == allowlist':<58} {'OK' if ok else 'FAIL'}")
print(f"    closure: {sorted(seen)}")
if extra:   print(f"    UNEXPECTED: {sorted(extra)}")
if missing: print(f"    MISSING:    {sorted(missing)}")
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

[ "$fail" -eq 0 ] && echo "all invariants hold" || echo "INVARIANT VIOLATION"
exit $fail
