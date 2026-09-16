#!/usr/bin/env bash
# Runs evals/golden-queries.md against a synced store and prints numbers.
#
# S5 exists so this can run without an MCP client in the loop. G1 and G10 must PASS;
# the rest need numbers so later phases can show movement rather than assert it.
#
# A FAILED QUERY IS NOT ZERO HITS. An earlier version sent stderr to /dev/null and let an empty
# result default to 0 — so a broken binary, a missing database or a bad flag reported "G10: 0 —
# PASS", the eval passing precisely because nothing ran. Every query's exit status is now
# checked, failures print ERR with the diagnostic, and any ERR makes the whole run exit non-zero.
set -uo pipefail
cd "$(dirname "$0")/.."
DB="${1:-$HOME/Library/Application Support/telegram-kb/kb.sqlite}"
TGKB="${TGKB:-./.build/release/tgkb}"
[ -x "$TGKB" ] || TGKB="swift run -q tgkb"

[ -f "$DB" ] || { echo "no store at $DB — run 'tgkb sync' first" >&2; exit 2; }

# NB: counted in the PARENT shell. An earlier attempt incremented a counter inside `run`, which
# executes in a subshell via `h=$(q …)` — so the count was always zero and the script still
# exited 0 after printing ERR everywhere. The same class of bug being fixed, reintroduced by the
# fix. Count the ERR values instead, where they are actually visible.
errors=0
failures=0
misses=0
ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG"' EXIT

# Echoes the hit count, or "ERR" — never a silent zero, and never a diagnostic mistaken for one.
#
# stdout and stderr are captured SEPARATELY. Merging them with 2>&1 meant a successful query that
# also wrote a warning could return that warning as its "count": `row` only tests for ERR, so the
# script exited 0 with a non-numeric result printed as a number. A successful command whose first
# stdout line is not a number is therefore also an error.
run() {
  local out err status
  err=$(mktemp)
  out=$("$@" 2>"$err"); status=$?
  if [ $status -ne 0 ]; then
    tail -1 "$err" >> "$ERRLOG" 2>/dev/null
    rm -f "$err"; echo "ERR"; return
  fi
  rm -f "$err"
  out=$(printf '%s' "$out" | head -1 | tr -d '[:space:]')
  case "$out" in
    ''|*[!0-9]*) echo "non-numeric result: '$out'" >> "$ERRLOG"; echo "ERR"; return ;;
  esac
  printf '%s' "$out"
}
# The limit is far above any expected result set on purpose: at --limit 500 the G4 count came
# back as exactly "500", a capped number masquerading as a measurement.
LIMIT=5000
q()  { run $TGKB query --db "$DB" --quiet --limit $LIMIT "$@"; }
qm() { local m="$1"; shift; run $TGKB query --db "$DB" --quiet --limit $LIMIT --mode "$m" "$@"; }
# The ids themselves, for criteria that name a post or a channel rather than a bare count.
#
# Both of these check the query's EXIT STATUS first. Reading ids from a failed query and counting
# them yields 0 — a failure that reads as a measurement, which is the bug class this whole script
# exists to avoid. It bit here: a store one migration behind made every query fail, and the
# channel filter reported "0 hits in @iosgr" rather than ERR.
qids() {
  local out status
  out=$($TGKB query --db "$DB" --quiet --limit $LIMIT "$@" 2>/dev/null); status=$?
  [ $status -ne 0 ] && { echo "ERR"; return 1; }
  printf '%s' "$out" | tail -n +2
}
returns() { # <id> <query…>
  local ids; ids=$(qids "${@:2}") || { echo ERR; return; }
  echo "$ids" | grep -qx "$1" && echo yes || echo no
}
# G1's criterion is "36 posts in @iosgr", and the query searches the whole store: hits from the
# other three channels were covering for a regression in the one the criterion is about.
qin() { # <channel> <query…>
  local ids; ids=$(qids "${@:2}") || { echo ERR; return; }
  echo "$ids" | grep -c "^$1/"
}

# PASS only when the query actually ran AND met its expectation.
verdict() { # <hits> <test> <pass-text> <fail-text>
  if [ "$1" = "ERR" ]; then echo "ERR — the query failed; this is NOT zero hits"
  elif eval "[ $1 $2 ]"; then echo "$3"
  else echo "$4"; fi
}
# The acceptance criteria, named here rather than inferred from the verdict text: G1 guards TD-4's
# discharge (Russian lemmas), G3 guards TD-10's (ё folding), G10 is the confabulation bar. The rest
# are measurements — a miss is reported loudly and does not fail the run.
REQUIRED="G1 G3 G10"
row() {
  [ "$3" = "ERR" ] && errors=$((errors + 1))
  case " $REQUIRED " in
    *" $1 "*) case "$4" in FAIL*) failures=$((failures + 1)) ;; esac ;;
    *)        case "$4" in FAIL*) misses=$((misses + 1)) ;; esac ;;
  esac
  printf "%-5s %-28s %6s  %s\n" "$1" "$2" "$3" "$4"
}

printf "%-5s %-28s %6s  %s\n" "ID" "QUERY" "HITS" "EXPECTATION"
printf -- "-%.0s" {1..92}; echo

h=$(qin iosgr навигация)
row G1 "навигация in @iosgr" "$h" "$(verdict "$h" "-ge 36" "PASS — matches навигации too" "FAIL — TD-4 regression; the criterion is >= 36 in @iosgr, prefix-only finds 11")"
h=$(qm substring imation)
row G2 "imation (substring)" "$h" "$(verdict "$h" "-ge 1" "PASS — trigram only; Telegram returns 0" "FAIL")"
# G3 names a post, not a count: the criterion is that a ё-WRITTEN post comes back for an е-spelled
# query. `iosdev/530` is the case that holds today; `iosgr/2081`, which golden-queries.md called
# canonical, does NOT — see TD-23, and read that entry before weakening this check.
h=$(q верстка)
case "$(returns iosdev/530 верстка)" in
  yes) g3="PASS — returns the ё-written iosdev/530" ;;
  ERR) g3="ERR — the query failed; this is NOT a folding failure" ;;
  *)   g3="FAIL — TD-10: an е-spelled query no longer returns the ё-written iosdev/530" ;;
esac
row G3 "верстка (ё folding)" "$h" "$g3"
h=$(q архитектура)
row G4 "архитектура (cap-beating)" "$h" "$(verdict "$h" "-ge 150" "PASS — beats Telegram's ~22 cap" "FAIL — the criterion is >= 150 corpus-wide")"
h=$(q swiftui)
row G8 "swiftui (volume)" "$h" "$(verdict "$h" "-ge 0" "ranking signal available" "-")"
h=$(q корутин)
# Exactly four, not "at least": the criterion is the complete corpus set, so padding is as much
# a failure as a miss. Re-baseline the number in golden-queries.md when the corpus grows.
row G9 "корутин (sparse term)" "$h" "$(verdict "$h" "-eq 4" "all 4 corpus-wide, no padding" "FAIL — expected exactly 4 corpus-wide")"
h=$(q гравитационные волны)
row G10 "гравитационные волны (none)" "$h" "$(verdict "$h" "-eq 0" "PASS — says nothing rather than confabulating" "FAIL — matched an absent topic")"

echo
if [ "$errors" -gt 0 ]; then
  echo "$errors quer(y|ies) FAILED TO RUN — results above are NOT a pass." >&2
  [ -s "$ERRLOG" ] && echo "last error: $(tail -1 "$ERRLOG")" >&2
fi
if [ "$failures" -gt 0 ]; then
  echo "$failures REQUIRED quer(y|ies) ($REQUIRED) missed their threshold — this is a FAIL." >&2
fi
if [ "$misses" -gt 0 ]; then
  echo "note: $misses measured quer(y|ies) missed their target; not required, but worth reading." >&2
fi
if [ "$errors" -gt 0 ] || [ "$failures" -gt 0 ]; then exit 1; fi
echo "G5/G6/G7 are natural-language and cross-channel cases; they need the MCP surface (S6)."
