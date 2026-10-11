#!/usr/bin/env bash
# fake_test.sh — bd-fake on its own. The shapes asserted here are the ones
# contract_test.sh checks against a real bd.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
need python3 jq

T=$(mktemp -d "${TMPDIR:-/tmp}/bd-fake-test-XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
fake_root "$T/beads"
R="$T/beads"
B() { bd -C "$R" "$@"; }
has() { [[ "$3" == *"$2"* ]]; check "$1" $? "wanted '$2' in: $3"; }

echo "== init and info"
[[ -f "$R/.bd-fake.json" && -d "$R/.beads" ]]; check "init makes the store and a .beads dir" $?
# A real bd pointed at this root must fail closed rather than fall back to the
# caller's database: the metadata names a port nothing listens on.
is "metadata.json names a dead server" "server 1" \
  "$(jq -r '"\(.dolt_mode) \(.dolt_server_port)"' "$R/.beads/metadata.json")"
# The port file is what bd now reads first; metadata's port is deprecated there.
is "and so does the port file" "1" "$(cat "$R/.beads/dolt-server.port" 2>/dev/null)"
# An unreachable configured port is what makes bd try starting a server of its own.
grep -qx '  auto-start: false' "$R/.beads/config.yaml" 2>/dev/null
check "config.yaml turns bd's server auto-start off" $? "$(cat "$R/.beads/config.yaml" 2>/dev/null)"
(cd "$R" && bd init --non-interactive --init-if-missing --skip-agents --skip-hooks --prefix arun >/dev/null 2>&1)
is "a second init is a no-op" "0" "$?"
mkdir -p "$T/realroot/.beads"; echo '{"dolt_mode":"server","dolt_server_port":3308}' > "$T/realroot/.beads/metadata.json"
(cd "$T/realroot" && BD_FAKE_REFUSAL_LOG="$T/init.log" bd init --non-interactive --init-if-missing \
  --skip-agents --skip-hooks --prefix arun >/dev/null 2>&1)
is "init over a real bd's metadata.json is refused" "97" "$?"
is "and leaves it as it was" '{"dolt_mode":"server","dolt_server_port":3308}' "$(cat "$T/realroot/.beads/metadata.json")"
grep -q 'real bd store' "$T/init.log"; check "and is logged" $? "$(cat "$T/init.log" 2>/dev/null)"
OUT=$(B info); is "info exits 0" "0" "$?"
grep -q '^Database: ' <<<"$OUT"; check "and prints the Database line" $? "$OUT"
mkdir -p "$T/nostore"
BD_FAKE_REFUSAL_LOG="$T/guard.log" bd -C "$T/nostore" info >/dev/null 2>&1
is "a root with no store is refused" "97" "$?"
grep -q 'no beads store' "$T/guard.log"; check "and logged" $? "$(cat "$T/guard.log" 2>/dev/null)"
mkdir -p "$HOME/.bd-fake-never-$$" 2>/dev/null && {
  BD_FAKE_REFUSAL_LOG="$T/guard2.log" bd -C "$HOME/.bd-fake-never-$$" info >/dev/null 2>&1
  is "by default a dir outside the temp dirs is refused" "97" "$?"
  grep -q 'outside BD_FAKE_ALLOWED_ROOTS' "$T/guard2.log"; check "naming the setting" $? "$(cat "$T/guard2.log" 2>/dev/null)"
  rmdir "$HOME/.bd-fake-never-$$"; }

echo "== version flags work anywhere"
# A requirements check runs them from wherever it is, outside every temp dir.
OUT=$(cd / && bd --version 2>&1); is "--version outside the fence exits 0" "0" "$?"
is "and names bd's version" "bd version 1.3.0 (bd-fake)" "$OUT"
OUT=$(cd / && bd version 2>&1); is "so does the version verb" "0 bd version 1.3.0 (bd-fake)" "$? $OUT"
OUT=$(cd / && bd --bd-fake-version 2>&1); is "--bd-fake-version exits 0" "0" "$?"
is "and prints the package's own version" "bd-fake $(jq -r .version "$_TESTLIB_DIR/../package.json")" "$OUT"

echo "== BD_FAKE_ALLOWED_ROOTS"
mkdir -p "$T/allowed/r" "$T/other/r"
BD_FAKE_ALLOWED_ROOTS="$T/allowed" fake_root "$T/allowed/r"
BD_FAKE_ALLOWED_ROOTS="$T/allowed" bd -C "$T/allowed/r" info >/dev/null 2>&1
is "a root under one of its prefixes is allowed" "0" "$?"
BD_FAKE_ALLOWED_ROOTS="$T/allowed" BD_FAKE_REFUSAL_LOG="$T/ar.log" bd -C "$R" info >/dev/null 2>&1
is "and one outside every prefix is refused, the temp dir included" "97" "$?"
BD_FAKE_ALLOWED_ROOTS="$T/nope:$T/allowed" bd -C "$T/allowed/r" info >/dev/null 2>&1
is "the prefixes are colon-separated" "0" "$?"
BD_FAKE_ALLOWED_ROOTS="$T/allowed" BD_FAKE_REFUSAL_LOG="$T/ar.log" bd -C "$T/allowed" info >/dev/null 2>&1
is "the prefix itself is not a root under it" "97" "$?"
BD_FAKE_ALLOWED_ROOTS="$T/allow" BD_FAKE_REFUSAL_LOG="$T/ar.log" bd -C "$T/allowed/r" info >/dev/null 2>&1
is "a prefix matches whole path components only" "97" "$?"
ln -s "$HOME" "$T/home-link"
BD_FAKE_REFUSAL_LOG="$T/ar.log" bd -C "$T/home-link" info >/dev/null 2>&1
is "a symlink out of the fence is resolved before the check" "97" "$?"

if [[ "$(uname -s)" == Darwin ]]; then
  # What mktemp uses with no TMPDIR set: a clean shell's temp dir is still a temp dir.
  DT=$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)bd-fake-dt-XXXXXX")
  (cd "$DT" && env -u TMPDIR bd init --quiet --prefix dt >/dev/null 2>&1)
  is "with TMPDIR unset, macOS's per-user temp dir is allowed by default" "0" "$?"
  rm -rf "$DT"
fi

echo "== BD_FAKE_LOG records every call"
BD_FAKE_LOG="$T/calls.log" B show --json "$R-none" >/dev/null 2>&1
(cd "$R" && BD_FAKE_LOG="$T/calls.log" bd list --json --label 'a b' >/dev/null)
is "one line per call" "2" "$(wc -l < "$T/calls.log" | tr -d ' ')"
is "with the argv as given and the cwd" "$(jq -nc --arg c "$PWD" --arg r "$R" '[[$c, ["-C",$r,"show","--json",($r+"-none")]]]')" \
  "$(head -1 "$T/calls.log" | jq -c '[[.cwd, .argv]]')"
is "argv words keep their spaces" '["list","--json","--label","a b"]' "$(sed -n 2p "$T/calls.log" | jq -c .argv)"
is "each line carries the call's exit code" "1 0" "$(jq -rs '[.[].exit] | join(" ")' "$T/calls.log")"
BD_FAKE_LOG="$T/c64.log" BD_FAKE_REFUSAL_LOG="$T/u0.log" B frobnicate >/dev/null 2>&1
is "an unsupported call is one line" "1" "$(wc -l < "$T/c64.log" | tr -d ' ')"
is "with its exit and why" "64 frobnicate unsupported: verb 'frobnicate'" \
  "$(jq -r '"\(.exit) \(.argv[2]) \(.error)"' "$T/c64.log")"
BD_FAKE_LOG="$T/c97.log" BD_FAKE_REFUSAL_LOG="$T/u0.log" bd -C "$T/nostore" info >/dev/null 2>&1
is "and so is a refused one" "1 97" "$(wc -l < "$T/c97.log" | tr -d ' ') $(jq -r .exit "$T/c97.log")"
BD_FAKE_LOG="$T/c0.log" B info >/dev/null
is "a call that ran logs exit 0 and no error" "1 0 null" \
  "$(wc -l < "$T/c0.log" | tr -d ' ') $(jq -r '"\(.exit) \(.error)"' "$T/c0.log")"

echo "== unknown verbs and flags fail loudly"
BD_FAKE_REFUSAL_LOG="$T/u.log" B frobnicate >/dev/null 2>"$T/err"; is "an unknown verb is exit 64" "64" "$?"
has "with the argv on stderr" "frobnicate" "$(cat "$T/err")"
BD_FAKE_REFUSAL_LOG="$T/u.log" B list --json --bogus >/dev/null 2>"$T/err"; is "an unknown flag is exit 64" "64" "$?"
has "naming it" "--bogus" "$(cat "$T/err")"
has "and both go to the refusal log, so a harness can fail a case that swallowed them" "--bogus" "$(grep frobnicate -A1 "$T/u.log" 2>/dev/null)"

echo "== create and show"
E=$(B create --silent --type epic --priority 1 --title "Epic one" \
  --labels "agentic-run,agentic-run:run,agentic-run:state:starting" --metadata '{"origin":"issue","n":"7"}')
[[ "$E" =~ ^arun-[0-9a-z]+$ ]]; check "--silent prints a <prefix>-<base36> id" $? "$E"
T1=$(B create --silent --type task --priority 1 --parent "$E" --no-inherit-labels --title build \
  --labels "agentic-run:phase,agentic-run:state:pending" --metadata '{"run_kind":"phase","phase_index":"1"}')
is "a child is <parent>.1" "$E.1" "$T1"
T2=$(B create --silent --type task --priority 1 --parent "$E" --no-inherit-labels --title sr \
  --labels "agentic-run:phase,agentic-run:state:pending" --metadata '{"run_kind":"phase","phase_index":"2"}' \
  --deps "$T1")
is "the next is <parent>.2" "$E.2" "$T2"
T3=$(B create --silent --type task --priority 1 --parent "$E" --title inherits)
is "without --no-inherit-labels a child takes the parent's labels" \
  '["agentic-run","agentic-run:run","agentic-run:state:starting"]' "$(B show "$T3" --json | jq -c '.[0].labels')"
J=$(B show "$E" --json)
is "show is an array of one" "1" "$(jq length <<<"$J")"
is "with the issue's fields" "Epic one|open|1|epic|7" \
  "$(jq -r '.[0] | "\(.title)|\(.status)|\(.priority)|\(.issue_type)|\(.metadata.n)"' <<<"$J")"
is "labels sorted" '["agentic-run","agentic-run:run","agentic-run:state:starting"]' "$(jq -c '.[0].labels' <<<"$J")"
is "an epic with no dependencies has no dependencies key" "false" "$(jq '.[0] | has("dependencies")' <<<"$J")"
is "show counts every dependent, children included" "3" "$(jq '.[0].dependent_count' <<<"$J")"
J=$(B show "$T2" --json)
is "show carries each dependency as the full issue" "$T1 blocks build|$E parent-child Epic one" \
  "$(jq -r '[.[0].dependencies[] | "\(.id) \(.dependency_type) \(.title)"] | join("|")' <<<"$J")"
is "and the parent" "$E" "$(jq -r '.[0].parent' <<<"$J")"
is "and the timestamps" "true" \
  "$(jq '.[0] | (.created_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and (.updated_at != null)' <<<"$J")"
is "several ids in one show" "$T1 $T2" "$(B show "$T1" "$T2" --json | jq -r '[.[].id]|join(" ")')"
OUT=$(B show "$T1" arun-nope --json 2>"$T/err"); is "show with one id missing exits 0" "0" "$?"
is "with the ids it found" "$T1" "$(jq -r '[.[].id]|join(" ")' <<<"$OUT")"
has "and names the missing one on stderr" "Issue arun-nope not found" "$(cat "$T/err")"
OUT=$(B show arun-nope --json 2>/dev/null); is "a missing id is exit 1" "1" "$?"
jq -e '.[0]' <<<"$OUT" >/dev/null 2>&1; is "and its stdout is no issue" "5" "$?"

echo "== list"
J=$(B list --json --label agentic-run:phase --parent "$E" --all)
is "list --parent is that parent's children, by label" "$T1 $T2" "$(jq -r '[.[].id]|sort|join(" ")' <<<"$J")"
is "list carries dependencies as link rows" "$T1 blocks|$E parent-child" \
  "$(jq -r '.[] | select(.id=="'"$T2"'") | [.dependencies[] | "\(.depends_on_id) \(.type)"] | join("|")' <<<"$J")"
is "and its counts leave parent-child out" "1 0" \
  "$(jq -r '.[] | select(.id=="'"$T2"'") | "\(.dependency_count) \(.dependent_count)"' <<<"$J")"
is "--label is AND" "$E" "$(B list --json --label agentic-run:run --label agentic-run:state:starting --limit 0 \
  | jq -r '[.[].id | select(. == "'"$E"'")] | join(" ")')"
is "a comma in --label is AND too" "2" "$(B list --json --label 'agentic-run:run,agentic-run' | jq length)"
is "--metadata-field matches the stored value" "$E" \
  "$(B list --json --label agentic-run:run --limit 0 --metadata-field origin=issue --metadata-field n=7 | jq -r '.[].id')"
is "and a mismatch matches nothing" "0" \
  "$(B list --json --label agentic-run:run --metadata-field origin=pr | jq length)"
is "--limit caps the list" "2" "$(B list --json --limit 2 | jq length)"
for i in $(seq 1 55); do B create --silent --title "bulk$i" --labels bulk >/dev/null; done
is "captured, list has no 50-row default" "55" "$(B list --json --label bulk | jq length)"

echo "== update"
B update "$T1" --set-metadata a=1 --set-metadata 'b=x=y' --set-metadata 'c=007' --set-metadata 'd=true' \
  --set-metadata 'e={"k":1}' --set-metadata 'f=' --set-metadata 'g=1e3' --append-notes "note one" >/dev/null
is "update exits 0" "0" "$?"
B update "$T1" --append-notes "note two" --unset-metadata a --unset-metadata never >/dev/null
J=$(B show "$T1" --json | jq -c '.[0]')
# bd stores a value that parses as a JSON number, boolean or null as that, and
# everything else as the string it was given.
is "set-metadata stores JSON scalars as JSON, the rest as strings" \
  '{"b":"x=y","c":"007","d":true,"e":"{\"k\":1}","f":"","g":1000,"phase_index":"1","run_kind":"phase"}' \
  "$(jq -c '.metadata' <<<"$J")"
is "append-notes joins with a newline" "note one
note two" "$(jq -r '.notes' <<<"$J")"
B update "$T1" --remove-label agentic-run:state:pending --add-label agentic-run:state:blocked --status blocked >/dev/null
is "labels move and status sets" '["agentic-run:phase","agentic-run:state:blocked"] blocked' \
  "$(B show "$T1" --json | jq -c '.[0] | [.labels, .status]' | jq -r '"\(.[0]|tojson) \(.[1])"')"
B update "$T1" --set-labels 'x,y' --set-labels z >/dev/null
is "set-labels replaces them all" '["x","y","z"]' "$(B show "$T1" --json | jq -c '.[0].labels')"
B update "$T1" --set-metadata noeq >/dev/null 2>&1; is "a set-metadata with no = is exit 1" "1" "$?"
B update arun-nope --set-metadata a=b >/dev/null 2>&1; is "a missing id is exit 1" "1" "$?"
B update "$T2" --status closed >/dev/null 2>"$T/err"; is "closing an issue with an open blocker is refused" "1" "$?"
has "naming the blocker" "$T1" "$(cat "$T/err")"
B update "$E" --status closed >/dev/null 2>"$T/err"; is "closing a parent with open children is refused" "1" "$?"
has "saying why" "open child" "$(cat "$T/err")"
B update "$T1" --status closed >/dev/null; is "an unblocked issue closes" "0" "$?"
J=$(B show "$T1" --json | jq -c '.[0]')
is "with a closed_at" "closed true" "$(jq -r '"\(.status) \(.closed_at != null)"' <<<"$J")"
is "and list leaves it out without --all" "" \
  "$(B list --json --parent "$E" | jq -r '.[] | select(.id=="'"$T1"'") | .id')"
B update "$T1" --status open >/dev/null
is "reopening clears closed_at" "open false" "$(B show "$T1" --json | jq -r '.[0] | "\(.status) \(has("closed_at"))"')"
B update "$E" --status closed --force >/dev/null; is "--force closes a parent anyway" "0" "$?"
B update "$E" --status open >/dev/null

echo "== ready, dep, note, comments, close, delete"
E2=$(B create --silent --type epic --priority 1 --title E2 --labels agentic-run:run)
mkp() { B create --silent --type task --priority 1 --parent "$E2" --no-inherit-labels --title "$1" \
  --labels agentic-run:phase ${2:+--deps "$2"}; }
P0=$(mkp zero); P1=$(mkp one); P2=$(mkp two "$P1"); P3=$(mkp three "$P2,$P0")
RD() { B ready --parent "$E2" --label agentic-run:phase --json | jq -r '[.[].title]|join(" ")'; }
is "ready is every open, unblocked descendant, oldest first" "zero one" "$(RD)"
B update "$P0" --status blocked >/dev/null
is "a blocked status is not ready" "one" "$(RD)"
B update "$P0" --status open >/dev/null
B update "$P1" --status closed >/dev/null
is "closing a blocker readies what waited on it" "zero two" "$(RD)"
B dep remove "$P3" "$P2" >/dev/null; is "dep remove exits 0" "0" "$?"
B dep remove "$P3" "$P2" >/dev/null; is "and again, with nothing to remove" "0" "$?"
B update "$P0" --status closed >/dev/null
is "a removed link no longer blocks" "two three" "$(RD)"
B dep add "$P3" "$P2" >/dev/null; is "dep add exits 0" "0" "$?"
B dep add "$P3" "$P2" >/dev/null
is "and adding the same link twice keeps one" "1" \
  "$(B show "$P3" --json | jq --arg b "$P2" '[.[0].dependencies[] | select(.id==$b)] | length')"
B dep add "$P3" arun-nope >/dev/null 2>&1; is "a missing id is exit 1" "1" "$?"
# P3 waits on P2, which waits on P1: P1 waiting on P3 closes the loop.
B dep add "$P1" "$P3" >/dev/null 2>"$T/err"; is "a link that closes a cycle is refused" "1" "$?"
has "as bd words it" "would create a cycle" "$(cat "$T/err")"
B dep add "$P2" "$P3" >/dev/null 2>&1; is "and so is a two-issue cycle" "1" "$?"
B dep add "$P1" "$P3" --type related >/dev/null; is "a related link is not a cycle" "0" "$?"
B dep add "$P1" "$P3" >/dev/null 2>"$T/err"; is "a link already there with another type is refused" "1" "$?"
has "naming both types" 'already exists with type "related" (requested "blocks")' "$(cat "$T/err")"
B dep add "$P1" "$P1" >/dev/null 2>&1; is "an issue cannot depend on itself" "1" "$?"
B dep add "$P1" "$E2" >/dev/null 2>"$T/err"; is "nor on its own parent" "1" "$?"
has "which it already waits on" "already a child of $E2" "$(cat "$T/err")"
B dep add "$E2" "$P1" >/dev/null 2>"$T/err"; is "and a parent cannot be blocked by its child" "1" "$?"
has "saying why" "cannot be blocked by its descendant" "$(cat "$T/err")"
# bd cascades a parent's open blockers to its descendants; a parent's own blocked
# status does not.
W1=$(B create --silent --title w1)
B dep add "$E2" "$W1" >/dev/null
is "a parent waiting on an open issue readies none of its children" "" "$(RD)"
B update "$W1" --status closed >/dev/null
B update "$E2" --status blocked >/dev/null
is "a parent whose status is blocked still readies them" "two" "$(RD)"
B update "$E2" --status open >/dev/null
is "ready leaves out an issue outside --parent" "" \
  "$(B ready --parent "$E2" --json | jq -r '.[] | select(.id=="'"$E"'") | .id')"
B note "$E2" "hello" >/dev/null; B note "$E2" "again" >/dev/null
is "note appends to notes" "hello
again" "$(B show "$E2" --json | jq -r '.[0].notes')"
is "no comments is an empty array" "[]" "$(B comments "$P2" --json | jq -c .)"
has "and says so as text" "No comments on $P2" "$(B comments "$P2")"
B comments add "$P2" '{"findings":[{"fid":"F1"}]}' >/dev/null; is "comments add exits 0" "0" "$?"
B comments add "$P2" 'two
lines' >/dev/null
is "comments are text, oldest first" '["{\"findings\":[{\"fid\":\"F1\"}]}","two\nlines"]' \
  "$(B comments "$P2" --json | jq -c '[.[].text]')"
is "each with bd's fields" "author,created_at,id,issue_id,text" \
  "$(B comments "$P2" --json | jq -r '.[0] | keys | join(",")')"
has "the text form carries the comment" '"findings"' "$(B comments "$P2")"
is "show counts them, and says it left them out" "2 true" \
  "$(B show "$P2" --json | jq -r '.[0] | "\(.comment_count) \(.comments_omitted)"')"
B comments arun-nope --json >/dev/null 2>&1; is "comments on a missing id is exit 1" "1" "$?"
B close "$P3" >/dev/null 2>&1; is "close refuses an issue with an open blocker" "1" "$?"
B close "$E2" >/dev/null 2>&1; is "and a parent with open children" "1" "$?"
# bd closes what it can and exits 0 when any of the ids closed; a missing id fails the
# whole call before anything closes.
Q1=$(B create --silent --title q1); Q2=$(B create --silent --title q2); Q3=$(B create --silent --title q3)
B close "$Q1" "$P3" "$Q2" >/dev/null 2>"$T/err"; is "close with one refusal among several exits 0" "0" "$?"
is "and closes the rest" "closed open closed" "$(B show "$Q1" "$P3" "$Q2" --json | jq -r '[.[].status]|join(" ")')"
has "saying which it refused" "cannot close blocked issue: $P3" "$(cat "$T/err")"
B close "$P3" "$E2" >/dev/null 2>&1; is "close with every id refused is exit 1" "1" "$?"
B close "$Q3" arun-nope >/dev/null 2>&1; is "close with a missing id is exit 1" "1" "$?"
is "and closes nothing" "open" "$(B show "$Q3" --json | jq -r '.[0].status')"
B close --force "$E2" >/dev/null 2>&1; is "close --force closes it anyway" "0" "$?"
is "with bd's reason" "closed Closed" "$(B show "$E2" --json | jq -r '.[0] | "\(.status) \(.close_reason)"')"
B delete "$P0" --force >/dev/null; is "delete --force exits 0" "0" "$?"
B show "$P0" --json >/dev/null 2>&1; is "and the issue is gone" "1" "$?"
is "with its links" "" "$(B show "$P3" --json | jq -r --arg z "$P0" '.[0].dependencies[] | select(.id==$z) | .id')"

echo "== --json on the verbs that write"
J=$(B create --json --silent --title "both")
is "create --json wins over --silent, as in bd" "both 1" "$(jq -r '"\(.title) \(.schema_version)"' <<<"$J")"
JI=$(jq -r .id <<<"$J")
is "update --json is an array of what it changed" "$JI in_progress true" \
  "$(B update "$JI" --json --status in_progress | jq -r '.[0] | "\(.id) \(.status) \(has("started_at"))"')"
is "started_at survives a move back to open" "true" "$(B update "$JI" --json --status open | jq '.[0] | has("started_at")')"
is "dep add --json says what it added" "added blocks" \
  "$(B dep add "$JI" "$T1" --json | jq -r '"\(.status) \(.type)"')"
is "a refusal under --json is a JSON error on stdout" "1 resolving arun-nope: no issue found matching \"arun-nope\"" \
  "$(OUT=$(B note arun-nope --json x 2>/dev/null); echo "$? $(jq -r .error <<<"$OUT")")"
BD_FAKE_REFUSAL_LOG="$T/dj.log" B delete "$JI" --json >/dev/null 2>&1
is "delete --json without --force (bd's preview) is unsupported" "64" "$?"
BD_FAKE_REFUSAL_LOG="$T/dj.log" B delete "$JI" "$T1" --force --json >/dev/null 2>&1
is "and so is delete --json with several ids" "64" "$?"
is "delete --force --json with one id" "$JI 1" "$(B delete "$JI" --force --json | jq -r '"\(.deleted) \(.dependencies_removed)"')"

echo "== gate and audit"
G=$(B gate create --type=gh:pr --blocks "$P3" --await-id 7 | sed -n 's/^✓ Created gate \([^ ]*\) .*/\1/p')
[[ "$G" =~ ^arun-[0-9a-z]+$ ]]; check "gate create names a top-level gate" $? "$G"
J=$(B show "$P3" --json | jq -c --arg g "$G" '.[0].dependencies[] | select(.id==$g)')
is "it blocks the task as a gate issue" "gate blocks gh:pr 7 open" \
  "$(jq -r '"\(.issue_type) \(.dependency_type) \(.await_type) \(.await_id) \(.status)"' <<<"$J")"
B update "$P2" --status closed --force >/dev/null
is "an open gate keeps the task out of ready" "" "$(RD)"
H=$(B gate create --type human --blocks "$P2" --reason "why not" | sed -n 's/^✓ Created gate \([^ ]*\) .*/\1/p')
is "a human gate's reason is in its description" "Ad-hoc gate blocking $P2

Reason: why not" "$(B show "$H" --json | jq -r '.[0].description')"
is "and it has no await_id" "false" "$(B show "$H" --json | jq '.[0] | has("await_id")')"
is "gate list has the open gates" "$(printf "%s\n" "$G" "$H" | sort | paste -sd" " -)" "$(B gate list --json | jq -r '[.[].id] | sort | join(" ")')"
is "gates are not in list" "" "$(B list --all --limit 0 --json | jq -r '.[] | select(.issue_type=="gate") | .id')"
B gate resolve "$G" --reason "merged" >/dev/null; is "gate resolve exits 0" "0" "$?"
is "and closes the gate with the reason" "closed merged" "$(B show "$G" --json | jq -r '.[0] | "\(.status) \(.close_reason)"')"
B gate resolve "$G" >/dev/null; is "resolving it again is not an error" "0" "$?"
is "a resolved gate leaves gate list" "$H" "$(B gate list --json | jq -r '[.[].id] | join(" ")')"
is "and ready again" "three" "$(RD)"
B audit record --kind tier --issue-id "$E2" --response small --tool-name agentic-run >/dev/null 2>&1
is "audit record without BD_AUDIT_ENABLED is refused" "1" "$?"
ID=$(BD_AUDIT_ENABLED=1 B audit record --kind tier --issue-id "$E2" --response small --tool-name agentic-run)
[[ "$ID" =~ ^int-[0-9a-f]{32}$ ]]; check "with it, it prints the entry id" $? "$ID"
is "and appends one line to .beads/interactions.jsonl" "tier $E2 small agentic-run $ID" \
  "$(jq -r '"\(.kind) \(.issue_id) \(.response) \(.tool_name) \(.id)"' "$R/.beads/interactions.jsonl")"

echo "== a required contract cannot be skipped"
# CI sets BD_FAKE_REQUIRE_CONTRACT=1, so a broken bd or dolt install fails the run
# instead of passing it on the fake's own tests alone.
mkdir -p "$T/nobd-bin"; ln -s "$(command -v python3)" "$(command -v jq)" "$T/nobd-bin/"
OUT=$(env PATH="$T/nobd-bin:/usr/bin:/bin" bash "$_TESTLIB_DIR/contract_test.sh" 2>&1)
is "with no bd and no dolt the contract skips, exit 0" "0" "$?"
OUT=$(env PATH="$T/nobd-bin:/usr/bin:/bin" BD_FAKE_REQUIRE_CONTRACT=1 bash "$_TESTLIB_DIR/contract_test.sh" 2>&1)
is "with BD_FAKE_REQUIRE_CONTRACT=1 it is exit 1" "1" "$?"
has "saying why" "BD_FAKE_REQUIRE_CONTRACT" "$OUT"
OUT=$(env PATH="$T/nobd-bin:/usr/bin:/bin" BD_FAKE_REQUIRE_CONTRACT=1 bash "$_TESTLIB_DIR/run.sh" --list 2>&1)
has "and run.sh runs it rather than skipping it" "contract_test.sh" "$OUT"

echo "== concurrent writers do not lose each other's writes"
for i in 1 2 3 4 5 6 7 8; do B create --silent --type task --priority 2 --title "c$i" >/dev/null & done; wait
is "eight parallel creates are eight issues" "8" "$(B list --json --limit 0 | jq '[.[] | select(.title|startswith("c"))] | length')"

report
