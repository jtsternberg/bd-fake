#!/usr/bin/env bash
# contract_test.sh — keeps bd-fake honest. One fixed script of bd calls, every verb and
# flag the fake implements, in the order a harness makes them, is played against the
# fake and against the real bd on a throwaway dolt server. Exit codes and JSON, with ids
# and the volatile fields normalized, must match.
#
# THE ONE SLOW TEST, and slow on purpose: it runs the real binary (a dolt server, and a
# Go binary opening a database on every call). Skipped, with the reason, when dolt or a
# real bd is not installed.
#
# tests/contract/BD_VERSION is the bd version this contract last passed against. An
# installed bd of any other version fails the file, loudly, even when every step
# matches: a new bd is a re-probe, not a silent pass. BD_FAKE_ACCEPT_VERSION=1 rewrites
# the pin after a run where everything else is green.
#
# A difference is either the fake being wrong (fix bin/bd-fake) or bd having changed
# (re-probe, then fix the fake). Text output is compared only where a harness reads it.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
need python3 jq
export BD_DISABLE_METRICS=1

# The real binary: the first bd on PATH that is not the fake's.
REAL=""
IFS=: read -ra _PATHS <<<"$PATH"
for d in "${_PATHS[@]}"; do
  [[ -n "$d" && ! "$d" -ef "$_TESTLIB_BIN" && -x "$d/bd" && ! "$d/bd" -ef "$BD_FAKE" ]] || continue
  REAL="$d/bd"; break
done
if [[ -z "$REAL" ]] || ! command -v dolt >/dev/null 2>&1; then
  echo "  (skipped: the contract needs a real bd and dolt; found bd='${REAL:-none}' dolt='$(command -v dolt || echo none)')"
  report; exit 0
fi
PIN_FILE="$_TESTLIB_DIR/contract/BD_VERSION"
PIN=$(tr -d '[:space:]' < "$PIN_FILE" 2>/dev/null)
REAL_VERSION=$("$REAL" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo "real: $("$REAL" --version 2>/dev/null | head -1) at $REAL; pinned: ${PIN:-none}"

T=$(mktemp -d "${TMPDIR:-/tmp}/bd-fake-contract-XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
# From a directory with no store above it: bd answers a call whose store it cannot
# find from the CALLER's database (gastownhall/beads#5756).
cd "$T" || exit 2
PORT=$(dolt_start "$$") || exit 2
mkdir -p "$T/realbin"; ln -s "$REAL" "$T/realbin/bd"

# Every step prints `### <label> rc=<n>` and then what is compared: JSON as bd printed
# it, or a line of facts drawn from text output. `### id <name> <value>` lines teach
# the normalizer which id is which.
step() { # <label> <kind: json|jq:<filter>|rc|first|count|db|has:<text>> <cmd...>; returns the command's rc
  local label="$1" kind="$2" out rc; shift 2
  out=$("$@" 2>/dev/null); rc=$?
  printf '### %s rc=%s\n' "$label" "$rc"
  case "$kind" in
    json)  printf '%s\n' "$out" ;;
    jq:*)  jq -c "${kind#jq:}" <<<"$out" ;;
    rc)    ;;
    first) printf '%s\n' "$out" | head -1 ;;
    count) jq length <<<"$out" ;;
    db)    grep -q '^Database: ' <<<"$out" && echo "has a Database line" ;;
    has:*) [[ "$out" == *"${kind#has:}"* ]] && echo "carries ${kind#has:}" ;;
  esac
  return "$rc"
}
idstep() { # <var> <label> <cmd...>: a json step whose output's .id is set in <var>, by name
  local _out _rc _id
  _out=$("${@:3}" 2>/dev/null); _rc=$?
  _id=$(jq -r .id <<<"$_out" 2>/dev/null)
  printf '### %s rc=%s\n%s\n### id %s %s\n' "$2" "$_rc" "$_out" "$1" "$_id"
  printf -v "$1" '%s' "$_id"
}
calls() { # <root>
  local R="$1" E T1 T2 T3 T4 T5 G H X J1 J2 J3 J4 J6 J7 G3
  B() { bd -C "$R" "$@"; }
  in_dir() { local d="$1"; shift; (cd "$d" && "$@"); }
  mkdir -p "$R"
  # Past a failed init, every call below would be answered from whatever database bd
  # falls back to (gastownhall/beads#5756), so the side stops here instead.
  step init rc in_dir "$R" bd init --non-interactive --init-if-missing --skip-agents --skip-hooks \
    --prefix arun --server --external --server-host 127.0.0.1 --server-port "$PORT" \
    --server-user root --database "t_contract_$$_${RANDOM}" && [[ -f "$R/.beads/metadata.json" ]] || {
    echo "### INIT FAILED in $R"; return 1; }
  step info db B info
  E=$(B create --silent --type epic --priority 1 --title "agentic-run o/r#7" \
    --labels "agentic-run,agentic-run:run,agentic-run:state:starting" \
    --metadata '{"run_kind":"run","origin":"issue","repo_nwo":"o/r","issue_number":"7"}' 2>/dev/null)
  echo "### id E $E"
  mkp() { B create --silent --type task --priority 1 --parent "$E" --no-inherit-labels "$@" 2>/dev/null; }
  T1=$(mkp --title "agentic-run build (round 1)" --labels "agentic-run,agentic-run:phase,agentic-run:state:pending" \
    --metadata '{"run_kind":"phase","phase":"build","round":"1","phase_index":"1"}')
  echo "### id T1 $T1"
  T2=$(mkp --deps "$T1" --title "agentic-run self-review (round 1)" \
    --labels "agentic-run,agentic-run:phase,agentic-run:state:pending" \
    --metadata '{"run_kind":"phase","phase":"self-review","round":"1","phase_index":"2"}')
  echo "### id T2 $T2"
  T3=$(mkp --deps "$T2,$T1" --title "agentic-run handoff (round 1)" \
    --labels "agentic-run,agentic-run:phase,agentic-run:state:pending" \
    --metadata '{"run_kind":"phase","phase":"handoff","round":"1","phase_index":"8"}')
  echo "### id T3 $T3"
  T4=$(B create --silent --type task --priority 2 --parent "$E" --title "inherits its labels" 2>/dev/null)
  echo "### id T4 $T4"
  step "show epic" json B show "$E" --json
  step "show a chained task" json B show "$T3" --json
  step "show two" json B show "$T1" "$T2" --json
  step "list phases" json B list --json --label agentic-run:phase --parent "$E" --all
  step "list by metadata" json B list --json --label agentic-run:run --limit 0 \
    --metadata-field origin=issue --metadata-field issue_number=7
  step "list by a metadata miss" json B list --json --label agentic-run:run --limit 0 --metadata-field origin=pr
  step "ready" json B ready --parent "$E" --label agentic-run:phase --json
  step "set metadata" rc B update "$T1" --set-metadata a=1 --set-metadata 'b=x=y' --set-metadata c=007 \
    --set-metadata d=true --set-metadata 'e={"k":1}' --set-metadata f= --set-metadata g=1e3 \
    --set-metadata 'pr_url=https://github.com/o/r/pull/99' --append-notes "[2026-01-01T00:00:00Z] one"
  step "unset metadata" rc B update "$T1" --append-notes "two" --unset-metadata a --unset-metadata never
  step "move a state label" rc B update "$T1" --remove-label agentic-run:state:pending \
    --add-label agentic-run:state:running --status open
  step "show the written task" json B show "$T1" --json
  step "list by a numeric and a boolean value" json B list --json --parent "$E" --metadata-field g=1000 \
    --metadata-field d=true
  step "set edge values" rc B update "$T1" --set-metadata n=null --set-metadata m=-3 --set-metadata f=2.5 \
    --set-metadata 's= 7 ' --set-metadata big=9007199254740993
  step "show edge values" json B show "$T1" --json
  for mf in s=7 's= 7 ' n=null m=-3 f=2.5 big=9007199254740993; do
    step "list by $mf" json B list --json --all --parent "$E" --metadata-field "$mf"
  done
  step "close past an open blocker" rc B update "$T2" --status closed
  step "close a parent with open children" rc B update "$E" --status closed
  step "--force past both" rc B update "$T2" --status closed --force
  step "show forced" json B show "$T2" --json
  step "reopen it" rc B update "$T2" --status open
  step "block" rc B update "$T1" --status blocked
  step "ready with the head blocked" json B ready --parent "$E" --label agentic-run:phase --json
  step "close the head" rc B update "$T1" --status closed
  step "ready after it" json B ready --parent "$E" --label agentic-run:phase --json
  step "list without --all" json B list --json --parent "$E"
  step "reopen" rc B update "$T1" --status open
  step "show reopened" json B show "$T1" --json
  step "close it again" rc B update "$T1" --status closed
  step note rc B note "$E" "Loop round 2 opened; handoff now waits on $T2."
  step "no comments" json B comments "$T2" --json
  step "no comments, as text" "has:No comments" B comments "$T2"
  step "comments add" rc B comments add "$T2" '{"review_id":1,"findings":[{"fid":"F1","title":"t"}]}'
  step "comments" json B comments "$T2" --json
  step "comments, as text" 'has:"findings"' B comments "$T2"
  step "dep remove" rc B dep remove "$T3" "$T2"
  step "dep remove, nothing there" rc B dep remove "$T3" "$T2"
  step "dep add" rc B dep add "$T3" "$T2"
  step "dep add a missing id" rc B dep add "$T3" arun-nope
  step "dep add the same link again" rc B dep add "$T3" "$T2"
  step "dep add closing a cycle" rc B dep add "$T1" "$T3"
  step "dep add a two-issue cycle" rc B dep add "$T2" "$T3"
  step "dep add self" rc B dep add "$T1" "$T1"
  step "dep add on its own parent" rc B dep add "$T1" "$E"
  step "dep add a parent on its child" rc B dep add "$E" "$T1"
  step "dep add related" rc B dep add "$T1" "$T4" --type related
  step "dep add over it as blocks" rc B dep add "$T1" "$T4"
  step "show after the refused links" json B show "$T1" "$T3" "$E" --json
  G=$(B gate create --type=gh:pr --blocks "$T3" --await-id 2584 2>/dev/null | sed -n 's/^✓ Created gate \([^ ]*\) .*/\1/p')
  echo "### id G $G"
  step "gate create, as text" first B gate create --type=human --blocks "$T2" --reason "scope-creep: 9 files"
  H=$(B gate list --json 2>/dev/null | jq -r --arg g "$G" '[.[] | select(.id != $g)][0].id')
  echo "### id H $H"
  step "show a gated task" json B show "$T3" --json
  step "show a gate" json B show "$G" "$H" --json
  step "gate list" json B gate list --json
  step "list leaves gates out" json B list --json --all --limit 0
  step "ready with a gate open" json B ready --parent "$E" --label agentic-run:phase --json
  step "gate resolve" rc B gate resolve "$G"
  step "gate resolve with a reason" rc B gate resolve "$H" --reason "moot: o/r#99 merged"
  step "gate resolve again" rc B gate resolve "$G"
  step "gate list after" json B gate list --json
  step "show resolved gates" json B show "$G" "$H" --json
  step "ready with the gate resolved" json B ready --parent "$E" --label agentic-run:phase --json
  W=$(B create --silent --type task --priority 2 --title "the epic waits on this" 2>/dev/null)
  echo "### id W $W"
  step "dep add the epic on it" rc B dep add "$E" "$W"
  step "ready with the parent waiting" json B ready --parent "$E" --label agentic-run:phase --json
  step "dep remove it" rc B dep remove "$E" "$W"
  step "parent status blocked" rc B update "$E" --status blocked
  step "ready with the parent's status blocked" json B ready --parent "$E" --label agentic-run:phase --json
  step "parent status open" rc B update "$E" --status open
  step "show found and missing" json B show "$T1" arun-nope --json
  step "show missing and found" json B show arun-nope "$T1" --json
  step "bd close past an open blocker" rc B close "$T3"
  step "bd close a parent with open children" rc B close "$E"
  step "close every id refused" rc B close "$T3" "$E"
  step "close with a missing id" rc B close "$W" arun-nope
  step "show it still open" json B show "$W" --json
  step "close several, one refused" rc B close "$T3" "$T2"
  step "show what closed" json B show "$T2" "$T3" --json
  step "reopen the one that closed" rc B update "$T2" --status open
  step "update several, one missing" rc B update "$W" arun-nope "$T3" --set-metadata multi=1
  step "update several, one refused" rc B update "$T3" "$W" --status closed
  step "show what updated" json B show "$W" "$T3" --json
  step "audit without the env" rc B audit record --kind tier --issue-id "$E" --response small --tool-name agentic-run
  X=$(BD_AUDIT_ENABLED=1 B audit record --kind tier --issue-id "$E" --response "small: one file" \
    --tool-name agentic-run 2>/dev/null)
  echo "### audit id ${X//[0-9a-f]/h}"
  echo "### interactions rc=0"; jq -sc . "$R/.beads/interactions.jsonl"
  step "set-labels" rc B update "$E" --set-labels "agentic-run,agentic-run:run" --set-labels agentic-run:state:handed-off
  T5=$(B create --silent --type task --priority 1 --parent "$E" --no-inherit-labels --title doomed 2>/dev/null)
  echo "### id T5 $T5"
  step "note naming it" rc B note "$E" "waits on $T5"
  step "delete" rc B delete "$T5" --force
  step "show deleted" json B show "$T5" --json
  step "show what named it" json B show "$E" --json
  step "close --force a parent" rc B close --force "$E"
  step "close --force a task" rc B close --force "$T4"
  step "show closed" json B show "$E" "$T4" --json
  step "update a missing id" rc B update arun-nope --set-metadata a=b
  step "comments on a missing id" json B comments arun-nope --json
  step "info via --directory" db bd --directory "$R" info
  step "info via --directory=" db bd --directory="$R" info
  # Its values are the fake's own (no dolt path, no "direct" mode); its shape is bd's.
  step "info --json" 'jq:{keys: keys, issue_count, schema_version, config, path: (.database_path | type), mode: (.mode | type)}' \
    B info --json
  idstep J1 "create --json" B create --json --type task --priority 1 --title "made with --json" \
    --description "a description" --status in_progress --labels "x,y" --metadata '{"k":"v"}'
  step "show what --json created" json B show "$J1" --json
  idstep J2 "create --json --silent prints the JSON" B create --json --silent --title "both flags"
  idstep J3 "create --json, born closed" B create --json --title "born closed" --status closed
  idstep J4 "create --json, a child" B create --json --parent "$J1" --title kid --labels z
  step "update --json to in_progress" json B update "$J2" --json --status in_progress
  step "update --json back to open keeps started_at" json B update "$J2" --json --status open
  step "update --json with nothing to update" first B update "$J2" --json
  step "update --json several, one missing" json B update "$J2" arun-nope --json --set-metadata z=1
  step "update --json with every id refused" json B update "$J1" --json --status closed
  step "close --json --reason" json B close "$J4" --json --reason "done with it"
  step "show the reason" json B show "$J4" --json
  step "close --json a missing id" json B close "$J3" arun-nope --json
  step "dep add --json" json B dep add "$J2" "$J1" --json
  step "dep add --json again" json B dep add "$J2" "$J1" --json
  step "close --json past a blocker" json B close "$J2" --json
  step "dep add --json closing a cycle" json B dep add "$J1" "$J2" --json
  step "dep add --json a missing first id" json B dep add arun-nope "$J1" --json
  step "dep add --json a missing second id" json B dep add "$J1" arun-nope --json
  step "dep remove --json" json B dep remove "$J2" "$J1" --json
  step "dep remove --json, nothing there" json B dep remove "$J2" "$J1" --json
  step "dep remove --json a missing id" json B dep remove "$J2" arun-nope --json
  step "note --json" json B note "$J1" --json "a note"
  step "note --json a missing id" json B note arun-nope --json "x"
  step "comments add --json" json B comments add "$J1" --json "a comment"
  step "comments add --json a missing id" json B comments add arun-nope --json "x"
  idstep G3 "gate create --json" B gate create --type=gh:pr --blocks "$J1" --await-id 5 --reason "why" --json
  step "gate create --json a missing id" json B gate create --type human --blocks arun-nope --json
  step "gate resolve --json prints text" first B gate resolve "$G3" --json
  # bd rewrites a deleted id in the descriptions and notes of the issues linked to it,
  # and leaves titles, and every issue not linked to it, as they were.
  idstep J6 "create one that names another" B create --json --title "names $J2" --description "names $J2"
  idstep J7 "and one linked to it that names it" B create --json --title "waits on $J2" \
    --description "waits on $J2" --deps "$J2"
  step "delete without --force" rc B delete "$J6"
  step "deletes nothing" json B show "$J6" --json
  step "delete without --force, with a dependent" rc B delete "$J1"
  step "delete --force --json" json B delete "$J2" --force --json
  step "show the two that named it" json B show "$J6" "$J7" --json
  step "delete --force --json a missing id" json B delete arun-nope --force --json
  for p in 4 3 2 1 0; do
    echo "### id L$p $(B create --silent --type task --priority "$p" --title "lim $p" --labels lim 2>/dev/null)"
  done
  step "list --limit 2" json B list --json --label lim --limit 2
  step "ready --limit 2" json B ready --json --label lim --limit 2
  step "list everything" json B list --all --limit 0 --json
  for i in $(seq 1 55); do B create --silent --type task --priority 3 --title "bulk $i" --labels bulk >/dev/null 2>&1; done
  step "list past 50 rows, captured" count B list --json --label bulk --all
}

# BEADS_DIR or BEADS_DB in the caller's env would point the real bd at a store of
# the caller's instead of the throwaway one.
( unset BEADS_DIR BEADS_DB; calls "$T/fake" ) > "$T/fake.raw"; FRC=$?
( unset BEADS_DIR BEADS_DB; PATH="$T/realbin:$PATH"; calls "$T/real" ) > "$T/real.raw"; RRC=$?
if (( FRC != 0 || RRC != 0 )); then
  fail "bd init failed (fake rc=$FRC, real rc=$RRC); the contract stopped before any other call" \
    "$(grep -h -A3 '^### init' "$T/fake.raw" "$T/real.raw")"
  report; exit 1
fi

cat > "$T/norm.py" <<'PY'
import json, re, sys
VOLATILE = {"created_at", "updated_at", "closed_at", "started_at", "owner", "created_by", "author", "actor",
            "revision"}
# bd does not specify a list's order, so these
# are compared as sets.
SORTED = {"list phases", "list by metadata", "list leaves gates out", "list without --all",
          "list everything", "gate list", "gate list after", "list by a numeric and a boolean value"}
text = open(sys.argv[1]).read()
ids = re.findall(r"^### id (\S+) (\S+)$", text, re.M)
for name, ident in sorted(ids, key=lambda p: -len(p[1])):
    text = re.sub(r"(?<![\w.-])" + re.escape(ident) + r"(?!\.?\w)", "<%s>" % name, text)
text = re.sub(r"int-[0-9a-f]{32}", "<int>", text)
# A dependencies array is compared sorted: bd's own order is not stable (a gate added
# last is listed first on one issue and last on another), and nothing reads it.
def scrub(v):
    if isinstance(v, dict):
        return {k: ("<v>" if k in VOLATILE else
                    sorted(scrub(v[k]), key=lambda x: json.dumps(x, sort_keys=True))
                    if k == "dependencies" and isinstance(v[k], list) else
                    "<uuid>" if k == "id" and re.fullmatch(r"[0-9a-f-]{36}", str(v[k])) else scrub(v[k]))
                for k in v}
    if isinstance(v, list):
        return [scrub(x) for x in v]
    return v
out = []
for block in re.split(r"^(?=### )", text, flags=re.M):
    if not block.strip():
        continue
    head, _, body = block.partition("\n")
    label = re.sub(r"^### | rc=\d+$", "", head)
    body = body.strip()
    if body and body[0] in "[{":
        try:
            j = scrub(json.loads(body))
        except ValueError:
            out.append(head + "\n(unparseable) " + body)
            continue
        if label in SORTED and isinstance(j, list):
            j.sort(key=lambda x: json.dumps(x, sort_keys=True))
        body = json.dumps(j, indent=1, sort_keys=True, ensure_ascii=False)
    out.append(head + ("\n" + body if body else ""))
print("\n".join(out))
PY
python3 -I "$T/norm.py" "$T/fake.raw" > "$T/fake.norm"
python3 -I "$T/norm.py" "$T/real.raw" > "$T/real.norm"

echo "== the fake answers every call the way bd does"
[[ -f "$T/fake/.bd-fake.json" && ! -e "$T/real/.bd-fake.json" && -d "$T/real/.beads/dolt" ]] &&
  grep -q '^### id E arun-' "$T/real.raw"
check "each side ran on its own bd" $? "$(head -20 "$T/real.raw")"
is "and the real side's store is on the throwaway server" "server 127.0.0.1 $PORT" \
  "$(jq -r '"\(.dolt_mode) \(.dolt_server_host) \(.dolt_server_port)"' "$T/real/.beads/metadata.json" 2>&1)"
is "the same steps on both sides" "$(grep -c '^### ' "$T/real.norm")" "$(grep -c '^### ' "$T/fake.norm")"
D=$(diff -u "$T/real.norm" "$T/fake.norm"); RC=$?
check "and the same answer to each (- real, + fake)" $RC "$(head -150 <<<"$D")"
while IFS= read -r l; do
  lbl=${l#'### '}
  grep -qxF "$l" "$T/fake.norm"; check "$lbl" $?
done < <(grep '^### ' "$T/real.norm" | grep -v '^### id ')

echo "== a real bd pointed at a fake root fails closed and starts no server"
# What a case that execs the real binary past the fake reaches. The second pass drops
# metadata's port, which bd 1.3.0 already calls deprecated, to stand in for a bd that
# reads only the port file.
FR="$T/fenced"; mkdir -p "$FR"
(cd "$FR" && bd init --non-interactive --init-if-missing --skip-agents \
  --skip-hooks --prefix arun >/dev/null 2>&1)
for pass in "with both ports" "with the port file alone"; do
  if [[ "$pass" == *alone ]]; then
    jq 'del(.dolt_server_port)' "$FR/.beads/metadata.json" > "$T/m.json" && mv "$T/m.json" "$FR/.beads/metadata.json"
  fi
  OUT=$(cd "$T" && env -u BEADS_DOLT_AUTO_START -u BEADS_DIR -u BEADS_DB BD_DISABLE_METRICS=1 "$REAL" -C "$FR" list --json 2>&1); RC=$?
  [[ "$RC" -ne 0 ]]; check "$pass: bd exits non-zero" $? "rc=$RC $OUT"
  ! jq -e 'type == "array"' <<<"$OUT" >/dev/null 2>&1; check "$pass: and lists nothing" $? "$OUT"
  [[ ! -e "$FR/.beads/dolt-server.pid" && ! -e "$FR/.beads/dolt" ]]
  check "$pass: and started no server" $? "$(ls -a "$FR/.beads")"
done


echo "== the installed bd is the one this contract was recorded against"
if [[ "$REAL_VERSION" == "$PIN" ]]; then
  pass "bd $REAL_VERSION, as pinned"
elif [[ "${BD_FAKE_ACCEPT_VERSION:-}" == 1 && "$FAIL" == 0 && -n "$REAL_VERSION" ]]; then
  printf '%s\n' "$REAL_VERSION" > "$PIN_FILE"
  pass "re-pinned tests/contract/BD_VERSION from ${PIN:-none} to $REAL_VERSION (BD_FAKE_ACCEPT_VERSION=1, everything else green)"
else
  fail "BD VERSION CHANGED: this contract last passed against bd ${PIN:-none}, and the installed bd is ${REAL_VERSION:-unknown}" \
    "Re-probe whatever the diff above shows, fix bin/bd-fake, then re-run with BD_FAKE_ACCEPT_VERSION=1 to re-pin (only a run with everything else green rewrites it)."
fi

report
