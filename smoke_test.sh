#!/usr/bin/env bash
# smoke_test.sh - run banned against the sample files in fixtures/.
#
#   bash smoke_test.sh
#   BANNED_SMOKE_SRC=~/.local/share/banned/banned.sh bash smoke_test.sh
#
# The second form tests the copy you actually installed, which is the point:
# test_banned.sh tests the code, this checks that YOUR install behaves, both
# sourced (the function) and executed (the file run as a command).
#
# Exit status: 0 all passed, 1 at least one failed, 2 stopped early or could
# not start. Like banned itself, anything unexpected is never a silent pass.
#
# The sample files are inert: valid Python whose banned calls sit inside
# functions that are never called. banned only reads them as text.
#
# Layout (see fixtures/README.md):
#   fixtures/fire/NAME.py            rule NAME must fire (global rules)
#   fixtures/network/NAME.py         rule NAME must fire only with -p planner
#   fixtures/clean/                  must stay clean, with and without -p planner
#   fixtures/false_positive/         known harmless lookalikes that DO fire
#   fixtures/known_gaps/             known evasions that are NOT caught (pinned)

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="${BANNED_SMOKE_SRC:-$HERE/banned.sh}"
FIX="$HERE/fixtures"
PROFILE_SRC="$HERE/network.rules.example"

PASS=0
FAIL=0
COMPLETED=0

[[ -r $SRC ]]         || { echo "smoke_test.sh: cannot read $SRC" >&2; exit 2; }
[[ -d $FIX ]]         || { echo "smoke_test.sh: no fixtures directory: $FIX" >&2; exit 2; }
[[ -r $PROFILE_SRC ]] || { echo "smoke_test.sh: cannot read $PROFILE_SRC" >&2; exit 2; }

SCRATCH=$(mktemp -d) || { echo "smoke_test.sh: cannot create scratch dir" >&2; exit 2; }
cleanup() {
  local rc=$?
  rm -rf "$SCRATCH"
  if (( ! COMPLETED )); then
    echo "smoke_test.sh: stopped before the summary (status $rc): this is NOT a pass" >&2
    exit 2
  fi
}
trap cleanup EXIT

# A private HOME holding the profile under test, so the real ~/.config is never
# read or touched. banned.sh derives its profile directory from HOME at source
# time, and the executed path inherits the same HOME.
export HOME="$SCRATCH/home"
mkdir -p "$HOME/.config/banned/profiles" || exit 2
cp "$PROFILE_SRC" "$HOME/.config/banned/profiles/planner.rules" || exit 2

# shellcheck source=/dev/null
source "$SRC"

# ---- harness ---------------------------------------------------------------

ok()  { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"
  if [[ -n ${2-} ]]; then printf '        %s\n' "$2"; fi
}
run() { out=$("$@" 2>"$SCRATCH/err"); rc=$?; err=$(<"$SCRATCH/err"); }

# expect LABEL WANT_RC [NEEDLE...]: check the last run
expect() {
  local label=$1 want=$2 needle; shift 2
  if [[ $rc != "$want" ]]; then
    bad "$label: rc=$want" "got rc=$rc | stdout=[$out] | stderr=[$err]"; return
  fi
  for needle in "$@"; do
    if [[ $out != *"$needle"* ]]; then
      bad "$label: stdout has '$needle'" "stdout=[$out]"; return
    fi
  done
  ok "$label"
}

# Both ways a person can invoke it: the sourced function, and the file executed.
both() {  # label want_rc file [-p profile] -- needle...
  local label=$1 want=$2 file=$3; shift 3
  local -a args=()
  while (( $# )) && [[ $1 != -- ]]; do args+=("$1"); shift; done
  shift   # the --
  run banned "${args[@]}" "$file"
  expect "$label (function)" "$want" "$@"
  run bash "$SRC" "${args[@]}" "$file"
  expect "$label (executed)" "$want" "$@"
}

# ---- rule names from the code under test and from the profile --------------

global_names=()
for rec in "${BANNED_RULES[@]}"; do global_names+=("${rec%%::*}"); done

profile_names=()
while IFS= read -r line || [[ -n $line ]]; do
  if [[ -z ${line//[[:space:]]/} || $line == '#'* ]]; then continue; fi
  profile_names+=("${line%%::*}")
done < "$PROFILE_SRC"

if (( ${#global_names[@]} == 0 )); then bad "banned.sh ships at least one rule"; fi
if (( ${#profile_names[@]} == 0 )); then bad "the profile defines at least one rule"; fi

# ---- 1. coverage, both directions ------------------------------------------
# Every rule needs a fixture, and every fixture needs a rule. Stale or missing
# fixtures fail here instead of passing vacuously.

check_coverage() {  # dir label names...
  local dir=$1 label=$2; shift 2
  local name f base found
  for name in "$@"; do
    if [[ -f $dir/$name.py ]]; then ok "$label: fixture exists for rule '$name'"
    else bad "$label: fixture exists for rule '$name'" "missing $dir/$name.py"; fi
  done
  for f in "$dir"/*.py; do
    [[ -e $f ]] || { bad "$label: directory has fixtures" "no .py files in $dir"; return; }
    base=$(basename "$f" .py); found=0
    for name in "$@"; do [[ $name == "$base" ]] && found=1; done
    if (( found )); then ok "$label: fixture '$base' maps to a rule"
    else bad "$label: fixture '$base' maps to a rule" "no rule named '$base'; stale fixture?"; fi
  done
}
check_coverage "$FIX/fire"    "global rules" "${global_names[@]}"
check_coverage "$FIX/network" "network profile" "${profile_names[@]}"

# ---- 2. each global rule fires on its own fixture ---------------------------

for name in "${global_names[@]}"; do
  both "fire/$name" 1 "$FIX/fire/$name.py" -- "RULE $name:" "$name.py:"
done
run banned "$FIX/fire"
all=()
for name in "${global_names[@]}"; do all+=("RULE $name:"); done
expect "fire/ as a whole reports every rule" 1 "${all[@]}"

# ---- 3. network rules fire only under the profile ---------------------------

for name in "${profile_names[@]}"; do
  both "network/$name with -p planner" 1 "$FIX/network/$name.py" -p planner -- "RULE $name:"
  both "network/$name without -p is clean" 0 "$FIX/network/$name.py" -- "clean"
done

# ---- 4. clean controls ------------------------------------------------------

both "clean/ without a profile" 0 "$FIX/clean" -- "clean"
both "clean/ with -p planner"   0 "$FIX/clean" -p planner -- "clean"

# ---- 5. known false positives: harmless, but they fire (accepted) -----------

both "false_positive/literal_eval fires the eval rule" 1 \
  "$FIX/false_positive/literal_eval.py" -- "RULE eval:"

# ---- 6. known gaps: evasions banned does NOT catch, pinned on purpose -------
# If one of these starts firing, banned got better: move the fixture, update
# the README limitations and the changelog. If it was never meant to, look.

for f in "$FIX"/known_gaps/*.py; do
  if [[ ! -e $f ]]; then bad "known_gaps/ has fixtures" "no .py files in $FIX/known_gaps"; break; fi
  both "known_gap/$(basename "$f" .py) stays unflagged" 0 "$f" -- "clean"
done

# ---- 7. the whole tree ------------------------------------------------------

run banned "$FIX"
expect "whole fixtures/ tree" 1 "RULE eval:"
if [[ $err == *"BANNED CALLS FOUND"* ]]; then ok "whole fixtures/ tree: stderr says BANNED CALLS FOUND"
else bad "whole fixtures/ tree: stderr says BANNED CALLS FOUND" "stderr=[$err]"; fi
run banned -p planner "$FIX"
expect "whole fixtures/ tree with -p planner" 1 "RULE socket:"

# ---- summary ----------------------------------------------------------------

if (( PASS + FAIL == 0 )); then bad "ran at least one assertion"; fi
COMPLETED=1
printf '\n%d passed, %d failed  (source: %s)\n' "$PASS" "$FAIL" "$SRC"
(( FAIL == 0 ))
