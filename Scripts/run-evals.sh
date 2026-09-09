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

# Echoes the hit count, or "ERR" — never a silent zero.
run() {
  local out status
  out=$("$@" 2>&1); status=$?
  if [ $status -ne 0 ]; then
    printf '%s' "$out" | tail -1 >> /tmp/tgkb-eval-errors.$$
    echo "ERR"
    return
  fi
  printf '%s' "$out" | head -1
}
q()  { run $TGKB query --db "$DB" --quiet --limit 500 "$@"; }
qm() { local m="$1"; shift; run $TGKB query --db "$DB" --quiet --limit 500 --mode "$m" "$@"; }

# PASS only when the query actually ran AND met its expectation.
verdict() { # <hits> <test> <pass-text> <fail-text>
  if [ "$1" = "ERR" ]; then echo "ERR — the query failed; this is NOT zero hits"
  elif eval "[ $1 $2 ]"; then echo "$3"
  else echo "$4"; fi
}
row() {
  [ "$3" = "ERR" ] && errors=$((errors + 1))
  printf "%-5s %-28s %6s  %s\n" "$1" "$2" "$3" "$4"
}

printf "%-5s %-28s %6s  %s\n" "ID" "QUERY" "HITS" "EXPECTATION"
printf -- "-%.0s" {1..92}; echo

h=$(q навигация)
row G1 "навигация (inflection)" "$h" "$(verdict "$h" "-ge 3" "PASS — matches навигации too" "FAIL — TD-4 regression")"
h=$(qm substring imation)
row G2 "imation (substring)" "$h" "$(verdict "$h" "-ge 1" "PASS — trigram only; Telegram returns 0" "FAIL")"
h=$(q верстка)
row G3 "верстка (ё folding)" "$h" "$(verdict "$h" "-ge 1" "PASS — must include вёрстка" "FAIL — TD-10")"
h=$(q архитектура)
row G4 "архитектура (cap-beating)" "$h" "$(verdict "$h" "-gt 22" "PASS — beats Telegram's ~22 cap" "FAIL — no better than Telegram")"
h=$(q swiftui)
row G8 "swiftui (volume)" "$h" "$(verdict "$h" "-ge 0" "ranking signal available" "-")"
h=$(q корутин)
row G9 "корутин (sparse term)" "$h" "$(verdict "$h" "-ge 0" "expect a handful, not padding" "-")"
h=$(q гравитационные волны)
row G10 "гравитационные волны (none)" "$h" "$(verdict "$h" "-eq 0" "PASS — says nothing rather than confabulating" "FAIL — matched an absent topic")"

echo
if [ "$errors" -gt 0 ]; then
  echo "$errors quer(y|ies) FAILED TO RUN — results above are NOT a pass." >&2
  [ -s /tmp/tgkb-eval-errors.$$ ] && echo "last error: $(tail -1 /tmp/tgkb-eval-errors.$$)" >&2
  rm -f /tmp/tgkb-eval-errors.$$
  exit 1
fi
rm -f /tmp/tgkb-eval-errors.$$
echo "G5/G6/G7 are natural-language and cross-channel cases; they need the MCP surface (S6)."
