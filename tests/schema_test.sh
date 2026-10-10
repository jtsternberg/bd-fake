#!/usr/bin/env bash
# schema_test.sh — `bd-fake --check-schema`, against a recorded `bd schema` and, when
# one is installed, the real one.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
need python3 jq

T=$(mktemp -d "${TMPDIR:-/tmp}/bd-fake-schema-XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
FIX="$_TESTLIB_DIR/fixtures/bd-schema-1.3.0.json"
stub() { # <dir> <schema-file>: a `bd` that answers `schema` and `version` only
  mkdir -p "$1"
  printf '#!/bin/sh\ncase "$1" in schema) cat "%s" ;; version|--version) echo "bd version 9.9.9 (stub)" ;; *) exit 3 ;; esac\n' "$2" > "$1/bd"
  chmod +x "$1/bd"
}

echo "== against bd 1.3.0's recorded schema"
stub "$T/ok" "$FIX"
OUT=$(BD_FAKE_REAL_BD="$T/ok/bd" "$BD_FAKE" --check-schema 2>&1); RC=$?
is "the fake's output validates" "0" "$RC"
grep -q '^bd-fake --check-schema: ok against bd version 9.9.9 (stub)' <<<"$OUT"; check "and says against which bd" $? "$OUT"
# Every record kind the fake prints is in the count, so a kind that went unchecked shows.
[[ "$OUT" =~ \(([0-9]+)\ records ]] && (( BASH_REMATCH[1] >= 12 )); check "covering show, list, ready, gate list and comments rows" $? "$OUT"

echo "== a schema the fake no longer matches fails, naming the field"
jq '.types.issue.properties.priority.type = "string"' "$FIX" > "$T/prio.json"; stub "$T/prio" "$T/prio.json"
OUT=$(BD_FAKE_REAL_BD="$T/prio/bd" "$BD_FAKE" --check-schema 2>&1); is "a changed type is exit 1" "1" "$?"
grep -q 'priority: wanted string' <<<"$OUT"; check "naming the field and the type" $? "$OUT"
jq '.types.issue.properties.status.enum -= ["blocked"]' "$FIX" > "$T/enum.json"; stub "$T/enum" "$T/enum.json"
OUT=$(BD_FAKE_REAL_BD="$T/enum/bd" "$BD_FAKE" --check-schema 2>&1); is "a value the enum dropped is exit 1" "1" "$?"
grep -q 'status: "blocked" not in' <<<"$OUT"; check "naming it" $? "$OUT"
jq 'del(.types.issue.properties.await_id)' "$FIX" > "$T/gone.json"; stub "$T/gone" "$T/gone.json"
OUT=$(BD_FAKE_REAL_BD="$T/gone/bd" "$BD_FAKE" --check-schema 2>&1); is "a field bd dropped is exit 1" "1" "$?"
grep -q 'await_id: not in the schema' <<<"$OUT"; check "naming it" $? "$OUT"
jq '.types.issue.required += ["assignee"]' "$FIX" > "$T/req.json"; stub "$T/req" "$T/req.json"
OUT=$(BD_FAKE_REAL_BD="$T/req/bd" "$BD_FAKE" --check-schema 2>&1); is "a newly required field is exit 1" "1" "$?"
grep -q 'assignee: required' <<<"$OUT"; check "naming it" $? "$OUT"
jq '.types.dependency.properties.type.pattern = "x"' "$FIX" > "$T/kw.json"; stub "$T/kw" "$T/kw.json"
OUT=$(BD_FAKE_REAL_BD="$T/kw/bd" "$BD_FAKE" --check-schema 2>&1); is "a keyword the checker does not know is exit 1" "1" "$?"
grep -q "keyword 'pattern'" <<<"$OUT"; check "rather than a silent pass" $? "$OUT"
echo 'not json' > "$T/junk.json"; stub "$T/junk" "$T/junk.json"
OUT=$(BD_FAKE_REAL_BD="$T/junk/bd" "$BD_FAKE" --check-schema 2>&1); is "a bd whose schema is not JSON is exit 1" "1" "$?"

echo "== with no real bd it skips, and says so"
mkdir -p "$T/nobd"; ln -s "$BD_FAKE" "$T/nobd/bd"
printf '#!/bin/sh\nexec bd-fake "$@"\n' > "$T/nobd/bd2"; chmod +x "$T/nobd/bd2"
mkdir -p "$T/shim"; cp "$T/nobd/bd2" "$T/shim/bd"
OUT=$(env -u BD_FAKE_REAL_BD PATH="$T/nobd:$T/shim:/usr/bin:/bin" "$BD_FAKE" --check-schema 2>&1)
is "exit 0" "0" "$?"
grep -q '^bd-fake --check-schema: skipped: no real bd on PATH' <<<"$OUT"
check "passing over itself and a shim that execs it" $? "$OUT"

echo "== against the installed bd"
REAL=$(env -u BD_FAKE_REAL_BD "$BD_FAKE" --check-schema 2>&1); RC=$?
if [[ "$REAL" == *skipped* ]]; then echo "  (skipped: no real bd on PATH)"
else is "the installed bd's schema validates the fake" "0" "$RC"; [[ "$RC" == 0 ]] || echo "$REAL"; fi

report
