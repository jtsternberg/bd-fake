# bd-fake

A drop-in fake [`bd`](https://github.com/gastownhall/beads) (Beads) for test suites. Scripts that shell out to `bd` hundreds of times run in seconds instead of minutes: a real `bd` call opens a Dolt database (100–500 ms each), and bd-fake answers from one JSON file per root (about 40 ms, most of it Python starting).

It implements only the verbs and flags below, with the `--json` shapes bd 1.3.0 prints. Anything else exits **64** with the argv on stderr, so a new use fails loudly instead of faking a pass. A contract test keeps it honest against a real bd (see [Drift protection](#drift-protection)).

Requires `python3` (3.7+) at runtime. Stdlib only. macOS and Linux.

## Install

```sh
npm install -g github:jtsternberg/bd-fake        # or: npm install -D github:jtsternberg/bd-fake
composer require --dev jtsternberg/bd-fake        # once it is on Packagist; until then add the repo as a vcs repository
```

Either one installs a `bd-fake` command (`node_modules/.bin/bd-fake`, `vendor/bin/bd-fake`).

## Use it as `bd` in a harness

The command is named `bd-fake`, never `bd`: a `bd` in `node_modules/.bin` or `vendor/bin` would shadow the real one for everything else on that PATH. A harness aliases it for its own processes only, with a temp bin dir first on PATH:

```sh
BIN=$(mktemp -d)
ln -s "$(command -v bd-fake)" "$BIN/bd"          # a symlink: no extra process per call
# or a one-line shim, when the harness needs to set something per call:
#   printf '#!/bin/sh\nexec bd-fake "$@"\n' > "$BIN/bd" && chmod +x "$BIN/bd"
export PATH="$BIN:$PATH"

root=$(mktemp -d)
(cd "$root" && bd init --prefix test --quiet)
id=$(bd -C "$root" create --silent --title "first" --labels a,b)
bd -C "$root" show "$id" --json
```

Composer's `vendor/bin/bd-fake` is a shell proxy, so symlink `vendor/jtsternberg/bd-fake/bin/bd-fake` instead to keep the per-call cost down.

## Environment

| Variable | Effect |
|---|---|
| `BD_FAKE_ALLOWED_ROOTS` | Colon-separated prefixes a root (`-C <dir>`, or the cwd) must resolve under. Default: `$TMPDIR`, `/tmp`, and on macOS the per-user temp dir `mktemp` falls back to. Anything else exits **97**, so a test can never write into a real checkout. |
| `BD_FAKE_LOG` | When set, each call appends exactly one JSON line as it exits: `{"cwd": ..., "argv": [...], "exit": N}`, plus `"error"` on a refused (97) or unsupported (64) call. Tests assert exact command shape with it. |
| `BD_FAKE_REFUSAL_LOG` | When set, each refused or unsupported call appends one text line here. A harness that fails a test on a non-empty file catches the call even when the caller swallowed the exit code. |
| `BD_AUDIT_ENABLED` | As in bd: `audit record` is refused without it. |
| `BD_FAKE_REAL_BD` | For `--check-schema`: the real bd to read `bd schema` from, instead of the first `bd` on PATH that is not bd-fake. |

## Exit codes

`0` success, `1` what bd itself would refuse (missing id, cycle, closing a blocked issue, …), **`64`** a verb or flag bd-fake does not implement, **`97`** a root outside `BD_FAKE_ALLOWED_ROOTS`, a directory with no store, or `init` over a real bd store, `141` broken pipe.

## What it implements

Every call may carry `-C <dir>` / `--directory`. `--db` and `--global` are refused (97): both name a store around the root the fence checks.

| Verb | Flags |
|---|---|
| `init` | `--non-interactive --init-if-missing --skip-agents --skip-hooks --server --external --quiet --prefix --server-host --server-port --server-user --database` |
| `info` | `--json` |
| `version`, `--version` | Answers from any directory, fenced or not. `--bd-fake-version` prints bd-fake's own version (`bd-fake 0.1.0`). |
| `create` | `--silent --json --no-inherit-labels --type --priority --title --description --parent --status --labels --metadata --deps` |
| `show <id>...` | `--json` (required) |
| `list` | `--json` (required) `--all --label --metadata-field --parent --limit` (no 50-row default unless stdout is a terminal, as bd) |
| `update <id>...` | `--json --force --set-metadata --unset-metadata --append-notes --status --add-label --remove-label --set-labels` |
| `close <id>...` | `--json --force --reason` |
| `delete <id>...` | `--json --force` |
| `note <id> <text>` | `--json` |
| `comments <id>`, `comments add <id> <text>` | `--json` |
| `gate create`, `gate resolve <id>`, `gate list` | `--json --type --blocks --await-id --reason` |
| `dep add <a> <b>`, `dep remove <a> <b>` | `--json`, `--type` on add |
| `ready` | `--json` (required) `--parent --label --limit` |
| `audit record` | `--kind --issue-id --response --tool-name` |

The store is `<root>/.bd-fake.json`, locked with `flock` on `<root>/.bd-fake.lock`, so parallel writers do not lose each other's writes. `init` also writes `.beads/metadata.json` and `.beads/dolt-server.port` naming port 1, and `dolt.auto-start: false` in `.beads/config.yaml`: a real bd that ends up pointed at a fake root gets "connection refused" instead of falling back to the caller's database (gastownhall/beads#5756) or starting a server.

## Drift protection

- **Contract test** (`tests/contract_test.sh`): one fixed script of calls, every verb and flag above, played against bd-fake and a real bd on a throwaway dolt server. Exit codes and JSON, with ids and timestamps normalized, must match.
- **Version pin** (`tests/contract/BD_VERSION`): the bd the contract last passed against. Any other installed version fails the contract loudly, even when every step matches. After re-probing and fixing the fake, `BD_FAKE_ACCEPT_VERSION=1 bash tests/contract_test.sh` rewrites the pin, and only on a run where everything else is green.
- **Schema check** (`bd-fake --check-schema`): validates the fake's show, list, ready, gate and comment records against a real bd's `bd schema`. A keyword it does not implement, a `format` other than `date-time`, or tuple-form `items` fails the check instead of passing unchecked. With no real bd on PATH it prints a skip and exits 0.

## Tests

```sh
bash tests/run.sh
```

Runs `fake_test.sh` and `schema_test.sh` always, and `contract_test.sh` (about a minute) when a real `bd` and `dolt` are on PATH; it says so when it skips. CI installs the pinned bd and dolt from their release tarballs on Ubuntu and macOS.

## License

MIT
