#!/bin/bash
# Re-runs the mutation checks this project claims: revert a fix, and prove its test FAILS.
#
# A regression test that passes both with and without its fix is not a regression test, and the
# only way to know which kind you have is to break the code on purpose. Review rounds 4 through 7
# each produced one; they were run by hand, which meant the claim in REVIEW.md and <doc:Roadmap>
# could not be checked by anyone else. This script is that claim, executable.
#
# Each mutant is `Scripts/mutants/<name>.patch`, a diff that puts a fixed bug BACK. By default the
# check is `swift test --filter <name>`, so the patch name is the test it must break. A mutant
# whose check is not a Swift test — a CLI exit status, a shell script — carries
# `Scripts/mutants/<name>.verify` instead: a script that exits 0 when the behaviour is CORRECT.
#
# A mutant passes the check when the verification FAILS under it *and* passed before it. Anything
# else is a finding:
#   red at baseline -> the check was already failing, so its red under the mutant proves nothing
#   still green     -> the test does not guard the fix
#   won't build     -> the mutant is invalid and proves nothing (this is not a pass)
#
# The baseline matters: on the run that introduced it, five checks were red before any mutation and
# would have been reported as proofs.
#
# Usage: Scripts/mutation-check.sh [name ...]      (default: every mutant)
set -uo pipefail
cd "$(dirname "$0")/.."

MUTANTS_DIR="Scripts/mutants"
# Per-run logs. Fixed /tmp names let two runs overwrite each other's diagnostics (PR #2, round 2).
# Two runs in ONE checkout remain unsafe for a bigger reason — both apply patches to the same
# files — so this fixes the diagnostics, not concurrency; don't run two harnesses in one tree.
LOGS=$(mktemp -d "${TMPDIR:-/tmp}/mutation-check.XXXXXX")
applied=""
# Whatever happens — a failure, a Ctrl-C — the working tree goes back. A harness that leaves a
# deliberate bug in the tree would be worse than no harness.
restore() { [ -n "$applied" ] && git apply -R "$applied" 2>/dev/null; applied=""; }
trap 'restore; rm -rf "$LOGS"; exit 130' INT TERM

if ! git diff --quiet; then
  echo "refusing to run: the working tree has uncommitted changes, and this script edits files." >&2
  echo "commit or stash first." >&2
  exit 2
fi

# Baseline first. A mutant's red means nothing unless the same check is green with the fix in
# place, and the cheapest way to establish that for every Swift test at once is to run the suite.
echo "baseline: running the test suite before mutating anything..."
if ! swift test >"$LOGS/baseline.log" 2>&1; then
  echo "refusing to run: the test suite is RED before any mutation, so no mutant could prove anything." >&2
  grep -m3 'recorded an issue' "$LOGS/baseline.log" | sed 's/^/    /' >&2
  exit 2
fi
echo "baseline: $(grep -o 'Test run with [0-9]* tests' "$LOGS/baseline.log" | tail -1) pass"
echo

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
  for p in "$MUTANTS_DIR"/*.patch; do names+=("$(basename "$p" .patch)"); done
fi

pass=0; fail=0
for name in "${names[@]}"; do
  patch="$MUTANTS_DIR/$name.patch"
  if [ ! -f "$patch" ]; then echo "no such mutant: $name" >&2; fail=$((fail + 1)); continue; fi
  # An empty patch mutates nothing, so its test stays green and the report would blame the TEST.
  # It happens when the generator's anchor misses — it did, once — so name the real cause.
  if [ ! -s "$patch" ]; then
    printf '%-42s %s\n' "$name" "ERROR — the patch is empty; it mutates nothing"
    fail=$((fail + 1)); continue
  fi

  verify="$MUTANTS_DIR/$name.verify"
  if [ -f "$verify" ] && ! bash "$verify" >"$LOGS/baseline-verify.log" 2>&1; then
    printf '%-42s %s\n' "$name" "ERROR — its check already fails with the fix in place"
    fail=$((fail + 1)); continue
  fi

  if ! git apply "$patch" 2>/dev/null; then
    printf '%-42s %s\n' "$name" "ERROR — patch does not apply; the code moved under it"
    fail=$((fail + 1)); continue
  fi
  applied="$patch"

  if ! swift build --build-tests >"$LOGS/build.log" 2>&1; then
    printf '%-42s %s\n' "$name" "ERROR — mutant does not compile, so it proves nothing"
    grep -m1 'error:' "$LOGS/build.log" | sed 's/^/    /'
    restore; fail=$((fail + 1)); continue
  fi

  if [ -f "$verify" ]; then bash "$verify" >"$LOGS/verify.log" 2>&1
  else swift test --filter "$name" >"$LOGS/verify.log" 2>&1; fi
  status=$?

  restore
  if [ $status -ne 0 ]; then
    printf '%-42s %s\n' "$name" "RED — the check fails without the fix, as it must"
    pass=$((pass + 1))
  else
    printf '%-42s %s\n' "$name" "STILL GREEN — the check does not guard the fix"
    fail=$((fail + 1))
  fi
done

# Leave the tree as it was found, and say so out loud.
git diff --quiet || { echo "PANIC: the working tree was not restored — inspect it before committing." >&2; exit 3; }
echo
echo "$pass mutant(s) red, $fail problem(s); working tree restored."
[ "$fail" -eq 0 ]
