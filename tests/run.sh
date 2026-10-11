#!/usr/bin/env bash
# run.sh [--list] — every bd-fake test file, one summary line each, then the total. The
# contract test runs last, and only when a real bd and dolt are on PATH or
# BD_FAKE_REQUIRE_CONTRACT=1, in which case its own skip is a failure; it says so when
# it does not run. A file that prints no "N passed, M failed" line is a failure.
# --list prints the files it would run and runs none.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES=("$DIR/fake_test.sh" "$DIR/schema_test.sh")
real_bd() { # the first bd on PATH that is not bd-fake
  local d; IFS=: read -ra ds <<<"$PATH"
  for d in "${ds[@]}"; do
    [[ -n "$d" && -x "$d/bd" && ! "$d/bd" -ef "$DIR/../bin/bd-fake" ]] && { echo "$d/bd"; return 0; }
  done; return 1
}
if [[ "${BD_FAKE_REQUIRE_CONTRACT:-}" == 1 ]] || { real_bd >/dev/null && command -v dolt >/dev/null 2>&1; }; then
  FILES+=("$DIR/contract_test.sh")
else echo "contract_test.sh: SKIPPED — needs a real bd and dolt on PATH (bd: $(real_bd || echo none), dolt: $(command -v dolt || echo none))"; fi
if [[ "${1:-}" == --list ]]; then printf '%s\n' "${FILES[@]##*/}"; exit 0; fi
LOGDIR=$(mktemp -d "${TMPDIR:-/tmp}/bd-fake-tests-XXXXXX") || exit 2
P=0; F=0; BAD=0
for f in "${FILES[@]}"; do
  b=$(basename "$f"); log="$LOGDIR/$b.log"; s=$(date +%s)
  bash "$f" > "$log" 2>&1
  line=$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$log" | tail -1)
  if [[ -z "$line" ]]; then echo "$b: NO TOTAL ($(( $(date +%s) - s ))s) · $log"; BAD=$((BAD + 1)); continue; fi
  n=${line%% *}; m=${line##*passed, }; m=${m%% *}; P=$((P + n)); F=$((F + m))
  if (( m == 0 )); then echo "$b: $line ($(( $(date +%s) - s ))s)"
  else echo "$b: $line ($(( $(date +%s) - s ))s) · $log"; grep -E '^  ✗|^    ' "$log" | head -40; BAD=$((BAD + 1)); fi
done
echo; echo "TOTAL: $P passed, $F failed across ${#FILES[@]} file(s)"
(( BAD == 0 )) || exit 1
rm -rf "$LOGDIR"
