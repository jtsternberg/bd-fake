#!/usr/bin/env bash
# testlib.sh — what bd-fake's tests source: bare [[ ]] then `check`, no framework.
# Sourcing it puts a temp bin dir first on PATH whose `bd` is this checkout's bd-fake,
# the way a harness is meant to alias it, and points BD_FAKE_REFUSAL_LOG at a file
# `report` fails on, so a refused or unsupported call fails the file even when the
# case swallowed its exit code.
_TESTLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BD_FAKE="$_TESTLIB_DIR/../bin/bd-fake"
_TESTLIB_BIN=$(mktemp -d "${TMPDIR:-/tmp}/bd-fake-bin-XXXXXX") || exit 2
ln -s "$BD_FAKE" "$_TESTLIB_BIN/bd"
export PATH="$_TESTLIB_BIN:$PATH"
BD_FAKE_REFUSAL_LOG=$(mktemp "${TMPDIR:-/tmp}/bd-fake-refusals-XXXXXX") || exit 2
export BD_FAKE_REFUSAL_LOG
unset BD_FAKE_LOG BD_FAKE_ALLOWED_ROOTS

# A fake root at <dir>, made the way a harness makes one.
fake_root() { # <dir> [prefix]
  mkdir -p "$1" || exit 2
  (cd "$1" && bd init --non-interactive --init-if-missing --skip-agents --skip-hooks \
    --prefix "${2:-arun}" >/dev/null) || { echo "fake_root: bd init failed in $1" >&2; exit 2; }
}

PASS=0; FAIL=0; FAILED_CASES=()
pass()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail()  { FAIL=$((FAIL+1)); FAILED_CASES+=("$1"); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; return 0; }
check() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }
is()    { [[ "$2" == "$3" ]]; check "$1" $? "wanted '$2', got '$3'"; }
need()  { local b; for b in "$@"; do command -v "$b" >/dev/null 2>&1 || {
            echo "$(basename "$0"): $b absent, skipping"; echo; echo "0 passed, 0 failed"; exit 0; }; done; }
report() {
  [[ -s "$BD_FAKE_REFUSAL_LOG" ]] && fail "a bd call was refused or unsupported" "$(cat "$BD_FAKE_REFUSAL_LOG")"
  rm -rf "$BD_FAKE_REFUSAL_LOG" "$_TESTLIB_BIN"
  echo; echo "$PASS passed, $FAIL failed"
  ((FAIL == 0)) || { printf '  - %s\n' "${FAILED_CASES[@]}"; exit 1; }
}
