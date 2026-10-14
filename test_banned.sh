#!/usr/bin/env bash
# test_banned.sh - tests for banned() (see banned.sh).
#
#   bash test_banned.sh
#
# Exit status: 0 = every assertion passed, 1 = at least one failed.
# SKIPs are printed loudly and never count as passes.
#
# Everything runs under mktemp -d with synthetic content. The "banned calls"
# below are only text inside .py files that grep reads; nothing here ever
# executes them.

SRC="${BANNED_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/banned.sh}"
[[ -r $SRC ]] || { echo "cannot read $SRC" >&2; exit 2; }

PASS=0
FAIL=0
SKIP=0
SCRATCH=$(mktemp -d) || { echo "cannot create scratch dir" >&2; exit 2; }
# chmod first: the unreadable-directory tests leave mode-000 dirs behind.
trap 'chmod -R u+rwx "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

# ---- tiny harness ----------------------------------------------------------

ok()   { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s (%s)\n' "$1" "$2"; }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$1"
  if [[ -n ${2-} ]]; then printf '        %s\n' "$2"; fi
}

# Fresh state for every case: re-source the code under test (this resets
# BANNED_RULES), point profiles at a scratch dir, make an empty scratch tree.
fresh() {
  # shellcheck source=/dev/null
  source "$SRC"
  BANNED_PROFILE_DIR="$SCRATCH/profiles"
  mkdir -p "$BANNED_PROFILE_DIR"
  T=$(mktemp -d "$SCRATCH/tree.XXXXXX")
}

CASE=""
begin() { CASE=$1; fresh; }

mkfile() { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1"; }
write_profile() { printf '%s\n' "${@:2}" > "$BANNED_PROFILE_DIR/$1.rules"; }

# run CMD...      -> sets out, err, rc
run() {
  out=$("$@" 2>"$SCRATCH/err"); rc=$?
  err=$(<"$SCRATCH/err")
}
# run_in DIR CMD... -> same, but with DIR as the working directory
run_in() {
  local dir=$1; shift
  out=$(cd "$dir" && "$@" 2>"$SCRATCH/err"); rc=$?
  err=$(<"$SCRATCH/err")
}

is_rc() {  # want [note]
  local label="$CASE${2:+ ($2)}: rc=$1"
  if [[ $rc == "$1" ]]; then ok "$label"
  else bad "$label" "got rc=$rc | stdout=[$out] | stderr=[$err]"; fi
}
out_is()    { if [[ $out == "$1" ]];   then ok "$CASE: stdout is '$1'";    else bad "$CASE: stdout is '$1'" "stdout=[$out]"; fi; }
out_has()   { if [[ $out == *"$1"* ]]; then ok "$CASE: stdout has '$1'";   else bad "$CASE: stdout has '$1'" "stdout=[$out]"; fi; }
out_lacks() { if [[ $out != *"$1"* ]]; then ok "$CASE: stdout lacks '$1'"; else bad "$CASE: stdout lacks '$1'" "stdout=[$out]"; fi; }
err_has()   { if [[ $err == *"$1"* ]]; then ok "$CASE: stderr has '$1'";   else bad "$CASE: stderr has '$1'" "stderr=[$err]"; fi; }
err_lacks() { if [[ $err != *"$1"* ]]; then ok "$CASE: stderr lacks '$1'"; else bad "$CASE: stderr lacks '$1'" "stderr=[$err]"; fi; }

# ---- one sample line per shipped rule --------------------------------------
# Adding a rule to banned.sh means adding a line here too: the coverage check
# below fails until you do. That is deliberate (a rule nobody has seen fire is
# a rule you cannot trust), but it is the one place a new rule costs a second edit.

declare -A SAMPLE=(
  [subprocess]='import subprocess'
  [os-system]='os.system("true")'
  [eval]='x = eval(s)'
  [exec]='exec(s)'
  [pickle]='import pickle'
  [os-popen]='os.popen("true")'
  [os-exec]='os.execv(p, a)'
  [os-spawn]='os.spawnl(0, p)'
)

# ---- 1. every shipped rule fires and names itself --------------------------

fresh
shipped=()
for rec in "${BANNED_RULES[@]}"; do shipped+=("${rec%%::*}"); done

if (( ${#shipped[@]} == 0 )); then
  bad "shipped rule list is non-empty" "BANNED_RULES is empty after sourcing $SRC"
fi

# Every expected rule must actually be shipped (so a stub with no rules fails).
for want in "${!SAMPLE[@]}"; do
  found=0
  for have in "${shipped[@]}"; do [[ $have == "$want" ]] && found=1; done
  if (( found )); then ok "rule '$want' is shipped"; else bad "rule '$want' is shipped"; fi
done

for name in "${shipped[@]}"; do
  begin "shipped rule '$name'"
  if [[ -z ${SAMPLE[$name]+x} ]]; then
    bad "$CASE: has a test sample" "add [$name]='...' to SAMPLE in this file"
    continue
  fi
  mkfile "$T/pkg/mod.py" $'x = 1\n'"${SAMPLE[$name]}"$'\ny = 2'
  run banned "$T"
  is_rc 1
  out_has "RULE $name:"
  out_has "mod.py:2:${SAMPLE[$name]}"
done

# ---- 2. clean tree ----------------------------------------------------------

begin "clean tree"
mkfile "$T/a.py" 'print("hello")'
mkfile "$T/sub/b.py" 'x = 1'
run banned "$T"
is_rc 0
out_is "clean"

# ---- 3. scope: ignored locations -------------------------------------------

begin "hits in __pycache__, .git and non-.py files are ignored"
mkfile "$T/ok.py" 'x = 1'
mkfile "$T/__pycache__/x.py" 'import pickle'
mkfile "$T/pkg/__pycache__/y.py" 'import pickle'
mkfile "$T/.git/hooks/z.py" 'import pickle'
mkfile "$T/notes.txt" 'import pickle'
mkfile "$T/run.sh" 'os.system x'
run banned "$T"
is_rc 0 "only ignored locations contain hits"
out_is "clean"
# Non-vacuous half: add one real hit and make sure ONLY it is reported.
mkfile "$T/real.py" 'import pickle'
run banned "$T"
is_rc 1 "one real hit added"
out_has "real.py:1:"
out_lacks "__pycache__"
out_lacks ".git/"
out_lacks "notes.txt"
out_lacks "run.sh"

# ---- 4. two rules, one file -------------------------------------------------

begin "two rules matching one file both report"
mkfile "$T/both.py" $'import subprocess\nimport pickle'
run banned "$T"
is_rc 1
out_has "RULE subprocess:"
out_has "RULE pickle:"

# ---- 5. rule-list failures fail closed -------------------------------------

begin "empty rule list"
mkfile "$T/a.py" 'x = 1'
BANNED_RULES=()
run banned "$T"
is_rc 2
out_lacks "clean"
err_has "no rules"

begin "unset rule list"
mkfile "$T/a.py" 'x = 1'
unset BANNED_RULES
run banned "$T"
is_rc 2
out_lacks "clean"

begin "invalid regex"
mkfile "$T/a.py" 'x = 1'
BANNED_RULES=('broken::(::unbalanced paren')
run banned "$T"
is_rc 2
out_lacks "clean"
err_has "broken"

begin "invalid regex is not masked by a valid rule next to it"
mkfile "$T/a.py" 'x = 1'
BANNED_RULES=('good::pickle::fine' 'broken::(::unbalanced paren')
run banned "$T"
is_rc 2
out_lacks "clean"

for rec in 'justaword' 'name::onlytwo' '::re::why' 'n::::why' 'n::re::'; do
  begin "malformed rule [$rec]"
  mkfile "$T/a.py" 'x = 1'
  BANNED_RULES=("$rec")
  run banned "$T"
  is_rc 2
  out_lacks "clean"
done

# ---- 6. filesystem failures fail closed ------------------------------------

begin "unreadable directory"
if (( EUID == 0 )); then
  skip "$CASE" "running as root: permission bits are not enforced"
else
  mkfile "$T/ok.py" 'x = 1'
  mkfile "$T/locked/a.py" 'import pickle'
  chmod 000 "$T/locked"
  run banned "$T"
  is_rc 2
  out_lacks "clean"
  # An error dominates: a real hit elsewhere must not turn this into rc 1,
  # but the hit is still shown.
  mkfile "$T/hit.py" 'import pickle'
  run banned "$T"
  is_rc 2 "error plus a real hit elsewhere"
  out_has "hit.py"
  chmod 755 "$T/locked"
fi

begin "nonexistent path"
run banned "$T/nope"
is_rc 2
out_lacks "clean"

begin "empty path argument is an error, never silently '.'"
mkfile "$T/a.py" 'x = 1'
run_in "$T" banned ""
is_rc 2
out_lacks "clean"
err_has "empty path"

begin "'--' ends options (dash-prefixed directory)"
mkfile "$T/-d/a.py" 'import pickle'
run_in "$T" banned -- -d
is_rc 1

# ---- 7. path handling -------------------------------------------------------

begin "path argument honoured, no argument means ."
mkfile "$T/clean/a.py" 'x = 1'
mkfile "$T/dirty/b.py" 'import pickle'
run banned "$T/clean";      is_rc 0 "explicit clean path"
run banned "$T/dirty";      is_rc 1 "explicit dirty path"
run_in "$T/dirty" banned;   is_rc 1 "no argument, cwd dirty"
run_in "$T/clean" banned;   is_rc 0 "no argument, cwd clean"

# ---- 8. extensibility -------------------------------------------------------

begin "adding one array entry makes a new rule fire, nothing else edited"
mkfile "$T/a.py" 'r = requests.get(u)'
run banned "$T"
is_rc 0 "before adding the rule"
BANNED_RULES+=('requests::requests\.::makes HTTP calls')
run banned "$T"
is_rc 1 "after adding the rule"
out_has "RULE requests: makes HTTP calls"
out_has "a.py:1:r = requests.get(u)"

# ---- 9. grep behaviour we depend on ----------------------------------------

begin "non-UTF-8 .py file is still scanned"
# Valid Python (PEP 263 coding line), but invalid UTF-8 on the SAME line as the
# match. Verified on grep 3.11: in a UTF-8 locale, -I drops that match from the
# output (exit status is still 0), so the hit would be invisible. A bad byte on
# a different line does not trigger this; only the matching line counts.
printf '# coding: latin-1\nimport pickle  # caf\xe9\n' > "$T/latin.py"
loc=$(locale -a 2>/dev/null | grep -iE '^(c|en_us)\.utf-?8$' | head -1)
if [[ -z $loc ]]; then
  skip "$CASE" "no UTF-8 locale installed: test would be vacuous"
else
  LC_ALL=$loc run banned "$T"
  is_rc 1 "caller locale $loc"
  out_has "latin.py:2:import pickle"
fi

begin "NUL-containing .py file is skipped (binary), per spec"
printf 'import pickle\0\n' > "$T/bin.py"
mkfile "$T/ok.py" 'x = 1'
run banned "$T"
is_rc 0
out_is "clean"

begin "recursion does not follow symlinks (KNOWN GAP, pinned on purpose)"
mkfile "$T/outside/evil.py" 'import pickle'
mkfile "$T/scan/ok.py" 'x = 1'
ln -s "$T/outside/evil.py" "$T/scan/link.py"
ln -s "$T/outside" "$T/scan/linkdir"
ln -s "$T/outside" "$T/cli"
run banned "$T/scan"
is_rc 0 "symlinked file and dir found during recursion are not followed"
run banned "$T/outside"
is_rc 1 "scanning the real directory finds it"
run banned "$T/cli"
is_rc 1 "a symlink given on the command line IS followed"

# ---- 9b. symlink notice -----------------------------------------------------
# grep -r skips symlinks it meets while recursing, so those files are never
# read. banned cannot scan them, but it must not let "clean" hide that: it
# lists them on stderr. Notify only; exit codes are unchanged.

HDR="Did not scan the following symlinks:"

begin "symlink notice: unscanned symlinks are listed once, exit code unchanged"
mkfile "$T/outside/evil.py" 'import pickle'
mkfile "$T/outside/notes.txt" 'hello'
mkfile "$T/scan/ok.py" 'x = 1'
ln -s "$T/outside/evil.py"   "$T/scan/link.py"         # symlinked .py file
ln -s "$T/outside"           "$T/scan/linkdir"         # symlinked directory (any name)
ln -s "$T/nowhere.py"        "$T/scan/dangling.py"     # dangling .py symlink
ln -s "$T/outside/notes.txt" "$T/scan/notes-link.txt"  # not Python: out of scope
run banned "$T/scan"
is_rc 0 "the notice does not change the exit code"
out_is "clean"
err_has "$HDR"
err_has "scan/link.py"
err_has "scan/linkdir"
err_has "scan/dangling.py"
err_lacks "notes-link.txt"
n=$(grep -c 'Did not scan' <<<"$err")
if (( n == 1 )); then ok "$CASE: header printed once, not once per rule"
else bad "$CASE: header printed once, not once per rule" "count=$n"; fi

begin "symlink notice: no symlinks, no notice"
mkfile "$T/ok.py" 'x = 1'
run banned "$T"
is_rc 0
out_is "clean"
err_lacks "Did not scan"
err_lacks "symlink"

begin "symlink notice: shown alongside real hits"
mkfile "$T/scan/real.py" 'import pickle'
mkfile "$T/outside/x.py" 'x = 1'
ln -s "$T/outside/x.py" "$T/scan/link.py"
run banned "$T/scan"
is_rc 1
out_has "RULE pickle:"
err_has "$HDR"
err_has "scan/link.py"
err_has "BANNED CALLS FOUND"

begin "symlink notice: skips __pycache__ and .git, but a symlink NAMED .git is reported"
mkfile "$T/outside/x.py" 'x = 1'
mkdir -p "$T/__pycache__" "$T/.git/hooks" "$T/sub"
ln -s "$T/outside/x.py" "$T/__pycache__/a.py"
ln -s "$T/outside/x.py" "$T/.git/hooks/b.py"
ln -s "$T/outside"      "$T/sub/.git"      # would hide itself if matched by name alone
mkfile "$T/ok.py" 'x = 1'
run banned "$T"
is_rc 0
err_has "sub/.git"
err_lacks "__pycache__/a.py"
err_lacks "hooks/b.py"

begin "symlink notice: a symlink given AS the path is scanned, not reported"
mkfile "$T/outside/evil.py" 'import pickle'
ln -s "$T/outside" "$T/cli"
run banned "$T/cli"
is_rc 1
err_lacks "Did not scan"

begin "symlink notice: hostile names cannot forge output lines or inject escapes"
mkfile "$T/ok.py" 'x = 1'
ln -s "$T/nowhere" "$T/"$'evil\n\e[31mFAKE.py'
run banned "$T"
is_rc 0
err_lacks $'\e'
mapfile -t errlines <<<"$err"
if (( ${#errlines[@]} == 2 )); then ok "$CASE: header plus exactly one entry line"
else bad "$CASE: header plus exactly one entry line" "got ${#errlines[@]} lines: [$err]"; fi

begin "symlink notice: a failing find is an error, not clean"
# grep fails on the same unreadable trees find does, so the real find cannot be
# made to fail on its own. A stub find that exits 1 proves the status is checked.
mkfile "$T/ok.py" 'x = 1'
mkdir -p "$SCRATCH/shim"
printf '#!/bin/sh\necho "find: simulated failure" >&2\nexit 1\n' > "$SCRATCH/shim/find"
chmod +x "$SCRATCH/shim/find"
PATH="$SCRATCH/shim:$PATH" run banned "$T"
is_rc 2
out_lacks "clean"
err_has "find error"
rm -rf "$SCRATCH/shim"

# ---- 10. usage errors -------------------------------------------------------

begin "usage errors are rc 2"
mkfile "$T/a.py" 'x = 1'
run banned -p;               is_rc 2 "-p with no value"
run banned -z "$T";          is_rc 2 "unknown option"
run banned "$T" "$T";        is_rc 2 "two paths"

# ---- 11. profiles -----------------------------------------------------------

begin "profile adds rules on top of the global list"
mkfile "$T/a.py" 'import socket'
write_profile planner '# network is banned for the planner' '' 'socket::socket::planner must stay offline'
run banned "$T"
is_rc 0 "no -p: profile rules are not applied"
out_is "clean"
run banned -p planner "$T"
is_rc 1 "-p planner"
out_has "RULE socket: planner must stay offline"
mkfile "$T/b.py" 'import pickle'
run banned -p planner "$T"
is_rc 1 "global rules still apply under a profile"
out_has "RULE pickle:"
run banned "$T" -p planner
is_rc 1 "-p after the path"
out_has "RULE socket:"

begin "profile: missing profile"
mkfile "$T/a.py" 'x = 1'
run banned -p nosuch "$T"
is_rc 2
out_lacks "clean"
err_has "nosuch"

begin "profile: missing profile directory"
mkfile "$T/a.py" 'x = 1'
BANNED_PROFILE_DIR="$SCRATCH/no-such-dir"
run banned -p planner "$T"
is_rc 2
out_lacks "clean"

begin "profile: comments-only profile is an error, not clean"
mkfile "$T/a.py" 'x = 1'
write_profile hollow '# nothing here' ''
run banned -p hollow "$T"
is_rc 2
out_lacks "clean"
err_has "no rules"

begin "profile: zero-byte profile is an error, not clean"
mkfile "$T/a.py" 'x = 1'
: > "$BANNED_PROFILE_DIR/zero.rules"
run banned -p zero "$T"
is_rc 2
out_lacks "clean"

begin "profile: malformed record"
mkfile "$T/a.py" 'x = 1'
write_profile broken 'justaword'
run banned -p broken "$T"
is_rc 2
out_lacks "clean"

begin "profile: unreadable profile file"
if (( EUID == 0 )); then
  skip "$CASE" "running as root: permission bits are not enforced"
else
  mkfile "$T/a.py" 'x = 1'
  write_profile locked 'socket::socket::x'
  chmod 000 "$BANNED_PROFILE_DIR/locked.rules"
  run banned -p locked "$T"
  is_rc 2
  out_lacks "clean"
fi

# A valid profile planted OUTSIDE the profile dir: if '../evil' were allowed to
# resolve, this would load and the call would return 1 or 0 instead of 2.
printf 'socket::socket::x\n' > "$SCRATCH/evil.rules"
for nm in '../evil' 'a/b' '' 'has space' '.hidden'; do
  begin "profile: invalid name [$nm]"
  mkfile "$T/a.py" 'x = 1'
  run banned -p "$nm" "$T"
  is_rc 2
  out_lacks "clean"
done

# ---- 12. static checks ------------------------------------------------------

CASE="static"
if bash -n "$SRC"; then ok "$CASE: bash -n banned.sh"; else bad "$CASE: bash -n banned.sh"; fi
if bash -n "${BASH_SOURCE[0]}"; then ok "$CASE: bash -n test_banned.sh"; else bad "$CASE: bash -n test_banned.sh"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SRC"; then ok "$CASE: shellcheck banned.sh"; else bad "$CASE: shellcheck banned.sh"; fi
  if shellcheck "${BASH_SOURCE[0]}"; then ok "$CASE: shellcheck test_banned.sh"; else bad "$CASE: shellcheck test_banned.sh"; fi
else
  skip "$CASE: shellcheck" "not installed"
fi

# ---- summary ----------------------------------------------------------------

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
