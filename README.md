# banned

A fail-closed `grep` tripwire for dangerous calls in AI-written Python.

`banned` is a small bash function that scans a Python tree for calls that should never appear in code an AI agent wrote: shell execution, dynamic code evaluation, unsafe deserialisation. It is a first-pass check run *before* a human reviews the diff. It tells you which rule fired and where, so you learn why something matched, not just that it did.

> **This is a tripwire, not a sandbox.** It matches text. It misses obfuscation and it flags harmless lookalikes. It does not replace code review or OS-level confinement of the agent. See [Limitations](#limitations).

## Why this exists

When an agent writes code inside a project directory, the person reviewing it needs a fast, boring, trustworthy first filter. A one-line `grep` works until it doesn't, and the ways it fails are the dangerous ones:

- an empty or broken rule list silently reports "clean";
- a bad regex makes `grep` exit 2, which a careless wrapper treats as "no matches";
- a typo'd path scans the wrong tree and reports "clean";
- the checker lives inside the project, so the agent can edit the thing that checks it.

`banned` is built around those failure modes. The rule is simple: **anything unexpected is an error, never "clean".**

## Example

```console
$ banned
```

stdout:

```text
RULE subprocess: spawns processes (shell or direct)
./app/run.py:1:import subprocess
RULE eval: evaluates a string as code (also hits ast.literal_eval, which is safe)
./app/util.py:2:data = ast.literal_eval(raw)
./app/run.py:2:result = eval(user_input)
```

stderr:

```text
Did not scan the following symlinks:
  ./app/helper_link.py
BANNED CALLS FOUND
```

Exit status `1`. On a tree with nothing to report it prints `clean` and returns `0`.

Note the `ast.literal_eval` hit: that is a known false positive, and a deliberate one. The rule is broad because the goal is to be told every time one of these appears, then decide.

## Usage

```bash
banned [-p PROFILE] [PATH]
```

| Argument | Meaning |
|---|---|
| `PATH` | Directory (or file) to scan. Defaults to `.`. An **empty** string is an error, not `.`. |
| `-p PROFILE` | Also load extra rules from `PROFILE.rules` (see [Profiles](#profiles)). Adds to the global list, never replaces it. |
| `--version` | Print `banned X.Y.Z` and exit `0`. Scans nothing. See [Versioning](#versioning). |

Scope: Python only (`*.py`). `__pycache__` and `.git` directories are skipped. Binary files are skipped.

### Exit status

| Code | Meaning |
|---|---|
| `0` | Clean: every rule ran and nothing matched. |
| `1` | Found: at least one rule matched. |
| `2` | Error: bad rules, bad arguments, `grep`/`find` failure. The result is not trustworthy. |

An error beats a hit: if a rule fails *and* another rule matches, you get `2`, and the hits are still printed. A symlink notice (below) does not change the exit status.

## Install

Keep `banned.sh` and the profile directory **outside every project tree**, owned by the account that runs the check, and not writable by whatever it checks. That is the whole trust model: the agent can write inside projects, so the checker must not live there.

```bash
install -d -m 755 ~/.local/share/banned ~/.config/banned/profiles
install -m 644 banned.sh ~/.local/share/banned/banned.sh
LINE='source ~/.local/share/banned/banned.sh'
grep -qxF "$LINE" ~/.bash_func 2>/dev/null || echo "$LINE" >> ~/.bash_func   # or ~/.bashrc; safe to re-run
source ~/.bash_func && banned --version
```

Sourcing the file only defines the `banned` function and runs nothing. You can also execute it directly, which runs the scan and exits with the same status as the function. That needs the exec bit, which the `install -m 644` above does not set:

```bash
install -m 755 banned.sh ~/.local/share/banned/banned.sh
~/.local/share/banned/banned.sh [-p PROFILE] [PATH]
```

The profile directory is fixed at `~/.config/banned/profiles` and is assigned unconditionally in `banned.sh`; it is not read from the environment, so a stray variable cannot redirect where rules are loaded from.

## Upgrading

From the repo, after pulling the new version:

```bash
D=~/.local/share/banned
bash test_banned.sh && bash smoke_test.sh                  # as a normal user, before touching the install
cp -p "$D/banned.sh" "$D/banned.sh.prev"                   # rollback copy
install -m 644 banned.sh "$D/banned.sh.new" && mv -f "$D/banned.sh.new" "$D/banned.sh"
BANNED_SMOKE_SRC="$D/banned.sh" bash smoke_test.sh \
  || { mv -f "$D/banned.sh.prev" "$D/banned.sh"; echo "rolled back"; }
source ~/.bash_func && banned --version
```

- The copy goes to a temporary name and is then moved into place, so an interrupted upgrade cannot leave a half-written `banned.sh` that your shell sources.
- The smoke test runs against the *installed* file. If it fails, the previous copy is restored.
- **An already-open shell keeps the old function** until you `source ~/.bash_func` again (or open a new shell). `banned --version` in that shell reports the old version. `bash ~/.local/share/banned/banned.sh --version` reports what is on disk.
- Upgrading never touches your profiles in `~/.config/banned/profiles/`; they are your data. Check the changelog for a rule or profile-format change before assuming an old profile still matches.

## Rules

Rules live in one array in `banned.sh`, one single-quoted string per rule:

```text
'name::regex::reason'
```

| Field | Notes |
|---|---|
| `name` | Short label shown when the rule fires. |
| `regex` | POSIX extended regex (`grep -E`). Must not contain `::`. |
| `reason` | One line saying why you care. May contain `::`, but not an apostrophe. |

`::` is the separator because `|` is regex alternation. Single quotes mean `\.`, `\(` and `$` reach `grep` untouched. It is an indexed array, not an associative one, so output order is the order written.

**To add a rule, add one line and change nothing else:**

```bash
'requests::requests\.::makes HTTP calls'
```

Shipped rules:

| Name | Regex | Why |
|---|---|---|
| `subprocess` | `subprocess` | spawns processes |
| `os-system` | `os\.system` | runs a command through the shell |
| `eval` | `eval\(` | evaluates a string as code (also hits `ast.literal_eval`) |
| `exec` | `exec\(` | executes a string as code |
| `pickle` | `pickle` | unpickling untrusted data runs arbitrary code |
| `os-popen` | `os\.popen` | runs a shell command, returns a pipe |
| `os-exec` | `os\.exec` | replaces the process image (`os.execv`, ...) |
| `os-spawn` | `os\.spawn` | starts a new process (`os.spawnl`, ...) |

Each rule is a separate `grep`, so every hit is attributed to the rule that caused it.

### Profiles

A profile is extra rules for one project, stored as `~/.config/banned/profiles/NAME.rules` and selected with `-p NAME`. Same record format, one per line. Blank lines and lines starting with `#` (column 0) are skipped.

```bash
banned -p planner ~/projects/planner
```

`planner.rules.example` is a ready-to-use profile that bans network use (`socket`, `urllib`, `http.client`) for a project that must stay offline. It also lists a few optional rules, disabled, that you can enable by removing the leading `# `. Its known noise is noted in the file: `urllib` also matches the offline-safe `urllib.parse`.

Profile names are restricted to letters, digits, `_` and `-`, so `-p ../x` cannot walk out of the profile directory. A missing, unreadable, empty, or comments-only profile is an error (`2`), never "clean": a profile that silently loads nothing would give a false sense of coverage.

## Design decisions

- **Fail closed everywhere.** Empty or unset rule list, malformed record, invalid regex, missing path, unreadable directory, missing profile, a `find` failure: all exit `2`.
- **An empty path is an error.** `banned "$proj"` with `$proj` unset must not quietly scan the current directory and say "clean".
- **Error beats hit.** A result you cannot trust is reported as such, even when something also matched.
- **`LC_ALL=C` on the `grep` call.** See the finding below.
- **Symlinks are reported, not silently skipped.** See below.
- **Executing the file runs the scan.** An earlier version only defined the function, so `./banned.sh DIR` printed nothing and exited `0`: a silent pass from a tool built to fail closed. Found by using it, not by the tests, which only ever sourced it. The file now checks whether it is being sourced or executed and behaves accordingly, and the suite exercises both paths.
- **Output is safe to read.** Symlink names are printed with `printf %q`, so a hostile file name cannot forge output lines or inject terminal escape sequences.

### Finding: `grep -I` can silently drop a match in a UTF-8 locale

In a UTF-8 locale, if the *matching line* contains a byte that is not valid UTF-8, `grep -I` treats the match as binary data, prints nothing, and still exits `0`. Valid Python can contain such a line (a Latin-1 comment under a PEP 263 coding declaration), so a naive `grep -rnI` wrapper can miss a hit without any error.

Reproduce (GNU grep 3.11):

```bash
mkdir t && printf '# coding: latin-1\nimport pickle  # caf\xe9\n' > t/latin.py
LC_ALL=C.UTF-8 grep -rnIE --include='*.py' pickle t; echo "rc=$?"   # no output, rc=0
LC_ALL=C       grep -rnIE --include='*.py' pickle t; echo "rc=$?"   # prints the match
```

Python 3.13 compiles that file without complaint. `banned` runs `grep` with `LC_ALL=C` so only NUL bytes make a file "binary". A bad byte on a *different* line does not trigger the problem; only the matching line matters. A regression test covers this.

### Symlinks

`grep -r` does not follow symlinks it meets while recursing, so a symlinked `.py` file, and everything inside a symlinked directory, is never read. `banned` cannot scan those, but it will not let `clean` hide that: it lists them on stderr under `Did not scan the following symlinks:`.

- Listed: symlinks named `*.py` (including dangling ones) and symlinks to directories under any name.
- Not listed: symlinks inside `__pycache__`/`.git`, and symlinks to non-Python files.
- A symlink *named* `.git` is still listed, so it cannot hide itself by name.
- A symlink given as `PATH` itself is followed (as `grep` does) and is not reported.
- This is a notice only. The exit status is unchanged.

## Limitations

Read these before trusting it.

- **Text matching, not analysis.** It misses `getattr(...)`, string concatenation, `importlib`, `from os import system`, `os . system`, and anything else that avoids the literal text.
- **False positives by design.** It matches comments, strings, and lookalikes such as `ast.literal_eval`.
- **Symlinked code is not scanned**, only reported. Whether that should be an error is a policy decision; today it is not.
- **A tree with no `.py` files reports `clean`.** A typo'd path to a real directory that contains no Python gives a vacuous all-clear. Not yet addressed.
- **Python only.** Other languages are out of scope for now.
- **Not a sandbox.** It cannot stop anything from running. Real controls are code review and confining the agent at the OS level.
- **Trust is enforced by file permissions, not by the script.** `banned` does not check that its rule files are unwritable by the agent.
- **Per-rule `grep` passes.** One pass over the tree per rule. Fine for project-sized trees; an unreadable directory prints its error once per rule.

## Versioning

```console
$ banned --version
banned 0.3.1
```

[Semantic Versioning](https://semver.org/), pre-1.0. The version lives in one place (`BANNED_VERSION` in `banned.sh`), and [CHANGELOG.md](CHANGELOG.md) records every change. The test suite fails if the changelog's newest entry and `banned --version` disagree.

Worth knowing if you used an early copy: **before 0.2.1, running the file as a command (`./banned.sh DIR`) printed nothing and exited `0`.** Sourcing it and calling `banned` was never affected. Treat any `0` from that invocation on an older copy as "no scan happened", not "clean". Details are in the changelog.

## Requirements

Linux, bash 4.4+ (`mapfile -d`), GNU grep, GNU find (`-H`, `-xtype`). Developed and tested on bash 5.2, grep 3.11, findutils 4.9, Python 3.13.

## Tests

```bash
bash test_banned.sh
```

Plain bash, no framework. Each case builds a scratch tree under `mktemp -d` from synthetic content; nothing in the suite executes the sample code, it is only ever text that `grep` reads. Exit status is `0` if every assertion passes.

- Covers each shipped rule firing and naming itself, scope (ignored directories and file types), multiple rules on one file, every fail-closed path above, path handling, profiles, symlink reporting, and the `LC_ALL` regression.
- Tests that depend on file permissions (unreadable directory, unreadable profile) **skip loudly when run as root**, because permission bits are not enforced for root. Run the suite as a normal user for full coverage.
- Includes a coverage check: a rule added to `banned.sh` fails the suite until it has a sample line in the test file, so no rule ships without being seen to fire.
- Runs `bash -n` and `shellcheck` if available.
- The runner fails closed too: if it stops before printing its summary, for any reason, it exits `2` with a "NOT a pass" message instead of a silent `0`.

### Sample files and smoke test

`fixtures/` holds small **inert** Python files: one per shipped rule, one per network-profile rule, clean controls, known false positives, and known evasions the tool does not catch. `smoke_test.sh` runs `banned` over them, both as the sourced function and as the executed file, and checks the results.

```bash
bash smoke_test.sh                                                      # the copy in this repo
BANNED_SMOKE_SRC=~/.local/share/banned/banned.sh bash smoke_test.sh     # your installed copy
```

The second form is the useful one: it checks that the copy you actually installed behaves, not just the code in the repo. Rules and fixtures are checked in both directions, so a rule with no sample file fails, and so does a sample file with no rule. The known-gap fixtures are pinned: if `banned` starts catching one, the smoke test says so and you update the docs. See [fixtures/README.md](fixtures/README.md). The smoke test found a real bug on its first run (see 0.3.1 in the changelog).

### How it was developed

The tests were written first and run against a deliberately broken stand-in that always prints `clean`, to confirm they go red. Afterwards the real implementation was mutated by hand on the fail-closed paths (empty-rule check removed, `-I` dropped, `--exclude-dir=.git` dropped, `LC_ALL=C` removed, symlink pruning by name only, and others) to confirm a test fails for each. A few mutants initially survived. They led to one tightened assertion, one new test (a stub `find` that exits 1), and a reminder that the permission tests only mean something when run as a non-root user.

## Repository layout

| File | Purpose |
|---|---|
| `banned.sh` | The function, the rule list, the design notes. Source it to get the function, or execute it to run a scan. |
| `test_banned.sh` | Test suite. |
| `smoke_test.sh` | Runs `banned` over `fixtures/`; can target an installed copy. |
| `fixtures/` | Inert sample files for every rule, plus controls, false positives and known gaps. |
| `CHANGELOG.md` | Version history, including the bug fixes. |
| `planner.rules.example` | Example profile banning network use. |
