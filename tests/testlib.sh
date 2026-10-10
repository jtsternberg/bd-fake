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

# A throwaway dolt sql-server owned by <pid>, for the contract test's real bd; prints its
# port. On a port the kernel picked, never a fixed one: a machine's shared beads server
# is on 3308. A watchdog stops it and removes its data when <pid> exits, however it
# exits.
dolt_start() { # <owner-pid>
  local owner="$1" d port pid i
  command -v dolt >/dev/null 2>&1 || { echo "dolt_start: dolt is required" >&2; return 1; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/bd-fake-dolt-XXXXXX") || return 1
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])') || return 1
  [[ "$port" =~ ^[0-9]+$ && "$port" != 3308 ]] || { echo "dolt_start: bad port '$port'" >&2; return 1; }
  mkdir -p "$d/data"
  # Detached from every inherited fd: a server holding the caller's stdout open keeps
  # a `$(…)` around the test waiting for as long as the server lives.
  (cd "$d/data" && exec dolt sql-server --host 127.0.0.1 --port "$port") \
    >"$d/server.log" 2>&1 </dev/null &
  pid=$!
  for ((i = 0; i < 300; i++)); do
    nc -z 127.0.0.1 "$port" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
    cat "$d/server.log" >&2; kill "$pid" 2>&1; rm -rf "$d"
    echo "dolt_start: dolt sql-server never listened on $port" >&2; return 1
  fi
  (
    while kill -0 "$owner" 2>/dev/null; do sleep 1; done
    kill "$pid"
    for ((i = 0; i < 100; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    rm -rf "$d"
  ) >>"$d/watchdog.log" 2>&1 </dev/null &
  printf '%s\n' "$port"
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
