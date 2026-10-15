#!/usr/bin/env bash
# banned.sh - first-pass tripwire for calls that should never appear in code an
# AI agent wrote.
#
#   banned [-p PROFILE] [PATH]      PATH defaults to .
#   banned --version                prints "banned X.Y.Z" (see CHANGELOG.md)
#
# Two ways to use this file:
#   source it   (from ~/.bash_func): defines the banned function, runs nothing
#   execute it  (./banned.sh [-p PROFILE] [PATH]): runs the scan and exits with
#               its status. Needs the exec bit (chmod +x), which a plain
#               `install -m 644` does not set.
# Executing it used to define the function and silently exit 0. See the
# source/execute guard at the bottom.
#
# Exit status (fail closed; anything unexpected is 2, never 0):
#   0  clean: every rule ran and nothing matched
#   1  found: at least one rule matched
#   2  error: bad rules, bad arguments, grep failure. The result is not
#      trustworthy. An error beats a hit: if both happen you get 2, and the
#      hits are still printed.
#
# ---------------------------------------------------------------------------
# WHAT THIS IS NOT
#
# This is a tripwire, not a sandbox. It matches TEXT with grep, so:
#   - it misses obfuscation: getattr(), string concatenation, importlib,
#     `from os import system`, `os . system`, and so on;
#   - it flags mentions in comments and strings, and harmless lookalikes
#     (eval\( also matches ast.literal_eval, which is safe). That is accepted:
#     the point is to be told every time one of these appears.
# The real controls are code review and OS-level confinement of the agent.
#
# `grep -r` does NOT follow symlinks it meets while recursing (GNU grep man
# page; confirmed on grep 3.11 by test_banned.sh). A symlink handed to banned
# on the command line IS followed. So a symlinked .py is not scanned, and
# neither is anything inside a symlinked directory. banned cannot fix that, but
# it will not let "clean" hide it: it lists every such symlink on stderr under
# "Did not scan the following symlinks:". That is a notice only; the exit
# status is unchanged. The listing needs GNU find (-H, -xtype) and bash >= 4.4
# (mapfile -d), the one dependency beyond bash and grep.
#
# SCOPE: Python only (*.py) for now. Other languages come later.
#
# ---------------------------------------------------------------------------
# INSTALL / TRUST BOUNDARY
#
# Keep this file, and the profile directory, OUTSIDE every project tree, owned
# by dev_operator, and not writable by the agent's user. The agent has write
# access inside projects; the checker must not be editable by what it checks.
#
# ---------------------------------------------------------------------------
# RULES
#
# One entry per rule, as one single-quoted string:
#
#     'name::regex::reason'
#
#   name    short label shown when the rule fires
#   regex   POSIX extended regex (grep -E); must not contain the two
#           characters '::' (they are the field separator)
#   reason  one line, why you care; may contain '::'
#
# Single quotes matter: inside them \. \( and $ reach grep untouched, with no
# shell expansion. That also means a reason cannot contain an apostrophe.
#
# '::' is used instead of '|' because '|' is regex alternation. It is an
# indexed array (not associative) so the report order is the order written.
# To add a rule, add one line below and change nothing else.

BANNED_RULES=(
  'subprocess::subprocess::spawns processes (shell or direct)'
  'os-system::os\.system::runs a command through the shell'
  'eval::eval\(::evaluates a string as code (also hits ast.literal_eval, which is safe)'
  'exec::exec\(::executes a string as code'
  'pickle::pickle::unpickling untrusted data runs arbitrary code'
  'os-popen::os\.popen::runs a shell command and returns a pipe'
  'os-exec::os\.exec::replaces the process image (os.execv, os.execl, ...)'
  'os-spawn::os\.spawn::starts a new process (os.spawnl, os.spawnv, ...)'
)

# Version of this file, shown by `banned --version`. Keep it in step with the
# newest entry in CHANGELOG.md (test_banned.sh fails if they differ).
BANNED_VERSION="0.3.1"

# Named profiles: extra rules for one project (e.g. "planner is offline"),
# kept as BANNED_PROFILE_DIR/NAME.rules and selected with -p NAME. Same record
# format as above, one per line. Blank lines and lines starting with '#' in
# column 0 are skipped. A profile ADDS to the global list, never replaces it.
# Assigned unconditionally on purpose: a variable from the environment must
# not be able to redirect where the rules are read from.
BANNED_PROFILE_DIR="$HOME/.config/banned/profiles"

# ---------------------------------------------------------------------------

# Appends the records of profile $1 to the global _BANNED_PROFILE array.
# Returns 0 on success, 1 on any problem (message already printed).
_banned_load_profile() {
  local name=$1 file line
  local -a lines

  _BANNED_PROFILE=()

  # Letters, digits, _ and - only: no '/', no '..', so the name cannot walk
  # out of BANNED_PROFILE_DIR.
  if [[ ! $name =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "banned: invalid profile name '$name' (letters, digits, _ and - only)" >&2
    return 1
  fi

  file="$BANNED_PROFILE_DIR/$name.rules"
  if [[ ! -f $file || ! -r $file ]]; then
    echo "banned: profile '$name' not found or unreadable: $file" >&2
    return 1
  fi

  mapfile -t lines < "$file" || {
    echo "banned: cannot read profile '$name': $file" >&2
    return 1
  }

  for line in "${lines[@]}"; do
    [[ -z ${line//[[:space:]]/} ]] && continue   # blank
    [[ $line == '#'* ]] && continue              # comment
    _BANNED_PROFILE+=("$line")
  done

  if (( ${#_BANNED_PROFILE[@]} == 0 )); then
    echo "banned: profile '$name' has no rules: refusing to report clean" >&2
    return 1
  fi
  return 0
}

banned() {
  local profile="" have_profile=0 path="." have_path=0
  local -a rules skipped
  local rec rest name regex reason out rc n=0 found=0 errors=0

  # ---- arguments ----------------------------------------------------------
  while (( $# )); do
    case $1 in
      -p)
        if (( $# < 2 )); then echo "banned: -p needs a profile name" >&2; return 2; fi
        profile=$2; have_profile=1; shift 2 ;;
      --)
        shift
        if (( $# > 1 )); then echo "banned: too many arguments" >&2; return 2; fi
        if (( $# == 1 )); then path=$1; have_path=1; shift; fi ;;
      --version)
        echo "banned $BANNED_VERSION"; return 0 ;;
      -*)
        echo "banned: unknown option: $1" >&2; return 2 ;;
      *)
        if (( have_path )); then echo "banned: too many arguments" >&2; return 2; fi
        path=$1; have_path=1; shift ;;
    esac
  done

  # An EMPTY path is an error, not ".": `banned "$proj"` with $proj unset
  # would otherwise scan the wrong tree and report "clean".
  if (( have_path )) && [[ -z $path ]]; then
    echo "banned: empty path argument" >&2; return 2
  fi

  # ---- rules --------------------------------------------------------------
  rules=("${BANNED_RULES[@]}")
  if (( have_profile )); then
    _banned_load_profile "$profile" || return 2
    rules+=("${_BANNED_PROFILE[@]}")
  fi
  if (( ${#rules[@]} == 0 )); then
    echo "banned: no rules loaded: refusing to report clean" >&2
    return 2
  fi

  # ---- scan: one grep per rule so each hit can be attributed ---------------
  for rec in "${rules[@]}"; do
    n=$((n + 1))

    if [[ $rec != *::*::* ]]; then
      echo "banned: malformed rule #$n (want name::regex::reason): $rec" >&2
      errors=1; continue
    fi
    name=${rec%%::*}
    rest=${rec#*::}
    regex=${rest%%::*}
    reason=${rest#*::}
    if [[ -z $name || -z $regex || -z $reason ]]; then
      echo "banned: malformed rule #$n (empty field): $rec" >&2
      errors=1; continue
    fi

    # LC_ALL=C: in a UTF-8 locale, -I silently drops a match whose line holds
    # a byte that is not valid UTF-8 (valid Python, e.g. a latin-1 comment),
    # and still exits 0. In the C locale only NUL bytes make a file binary.
    # -e protects a regex that starts with '-'; -- protects the path.
    # -H: with a single FILE as the operand, grep -r drops the file name, which
    # would break the file:line:text report.
    out=$(LC_ALL=C grep -rnIEH \
            --include='*.py' --exclude-dir=__pycache__ --exclude-dir=.git \
            -e "$regex" -- "$path")
    rc=$?

    case $rc in
      0) found=1
         printf 'RULE %s: %s\n%s\n' "$name" "$reason" "$out" ;;
      1) : ;;   # no match for this rule
      *) errors=1
         echo "banned: grep error on rule '$name' (exit $rc): result not trustworthy" >&2
         if [[ -n $out ]]; then printf 'RULE %s: %s\n%s\n' "$name" "$reason" "$out"; found=1; fi ;;
    esac
  done

  # ---- symlinks that grep -r did not follow --------------------------------
  # Once, not per rule. Reported: symlinks named *.py (including dangling
  # ones) and symlinks to directories (any name). Pruned: real directories
  # named __pycache__ or .git, which grep skips by name too. Matching on
  # -type d keeps a symlink NAMED .git from hiding itself from this list.
  # -H follows a symlink given as PATH itself, as grep does.
  mapfile -d '' -t skipped < <(
    find -H "$path" \
      \( -type d \( -name __pycache__ -o -name .git \) -prune \) -o \
      \( -type l \( -name '*.py' -o -xtype d \) -print0 \)
  )
  # The status of a process substitution is only visible through wait.
  if ! wait $!; then
    echo "banned: find error while listing symlinks: result not trustworthy" >&2
    errors=1
  fi
  if (( ${#skipped[@]} > 0 )); then
    echo "Did not scan the following symlinks:" >&2
    # %q: one line per entry, control characters escaped, so a hostile
    # file name cannot forge extra output lines or inject terminal escapes.
    printf '  %q\n' "${skipped[@]}" >&2
  fi

  # ---- verdict ------------------------------------------------------------
  if (( found )); then echo "BANNED CALLS FOUND" >&2; fi
  if (( errors )); then
    echo "banned: errors occurred: result not trustworthy" >&2
    return 2
  fi
  if (( found )); then return 1; fi
  echo "clean"
  return 0
}

# ---------------------------------------------------------------------------
# Executed rather than sourced: run the scan and pass its status through.
# Without this, `./banned.sh DIR` defined the function, called nothing, printed
# nothing and exited 0, a silent pass from a tool that must fail closed.
# Sourced, BASH_SOURCE[0] is this file but $0 is the caller, so this is skipped.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  banned "$@"
  exit
fi
