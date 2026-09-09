#!/usr/bin/env bash
# Runs evals/golden-queries.md against a synced store and prints numbers.
#
# S5 exists so this can run without an MCP client in the loop. G1 and G10 must PASS;
# the rest need numbers so later phases can show movement rather than assert it.
set -uo pipefail
cd "$(dirname "$0")/.."
DB="${1:-$HOME/Library/Application Support/telegram-kb/kb.sqlite}"
TGKB="${TGKB:-./.build/release/tgkb}"
[ -x "$TGKB" ] || TGKB="swift run -q tgkb"

q() { $TGKB query --db "$DB" --quiet --limit 500 "$@" 2>/dev/null | head -1; }
qm() { local m="$1"; shift; $TGKB query --db "$DB" --quiet --limit 500 --mode "$m" "$@" 2>/dev/null | head -1; }

printf "%-5s %-34s %8s  %s\n" "ID" "QUERY" "HITS" "EXPECTATION"
printf -- "-%.0s" {1..92}; echo

g1=$(q навигация)
printf "%-5s %-34s %8s  %s\n" "G1" "навигация (inflection)" "${g1:-0}" \
  "$([ "${g1:-0}" -ge 3 ] && echo "PASS — matches навигации too" || echo "FAIL — TD-4 regression")"

g2=$(qm substring imation)
printf "%-5s %-34s %8s  %s\n" "G2" "imation (substring)" "${g2:-0}" \
  "$([ "${g2:-0}" -ge 1 ] && echo "PASS — trigram only; Telegram returns 0" || echo "FAIL")"

g3=$(q верстка)
printf "%-5s %-34s %8s  %s\n" "G3" "верстка (ё folding)" "${g3:-0}" \
  "$([ "${g3:-0}" -ge 1 ] && echo "PASS — must include вёрстка" || echo "FAIL — TD-10")"

g4=$(q архитектура)
printf "%-5s %-34s %8s  %s\n" "G4" "архитектура (cap-beating)" "${g4:-0}" \
  "$([ "${g4:-0}" -gt 22 ] && echo "PASS — beats Telegram's ~22 cap" || echo "FAIL — no better than Telegram")"

g8=$(q swiftui)
printf "%-5s %-34s %8s  %s\n" "G8" "swiftui (volume)" "${g8:-0}" "ranking signal available"

g9=$(q корутин)
printf "%-5s %-34s %8s  %s\n" "G9" "корутин (sparse term)" "${g9:-0}" "expect a handful, not padding"

g10=$(q гравитационные волны)
printf "%-5s %-34s %8s  %s\n" "G10" "гравитационные волны (no answer)" "${g10:-0}" \
  "$([ "${g10:-0}" -eq 0 ] && echo "PASS — says nothing rather than confabulating" || echo "FAIL — returned matches for an absent topic")"

echo
echo "G5/G6/G7 are natural-language and cross-channel cases; they need the MCP surface (S6)."
