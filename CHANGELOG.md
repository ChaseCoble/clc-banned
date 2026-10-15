# Changelog

All notable changes to `banned`. Format follows [Keep a Changelog](https://keepachangelog.com/), versions follow [Semantic Versioning](https://semver.org/) (pre-1.0: minor bumps may change behaviour).

The newest entry must match `BANNED_VERSION` in `banned.sh` and the output of `banned --version`; `test_banned.sh` checks this.

Versions 0.1.0 to 0.2.1 are labelled retroactively: no version string existed before 0.3.0, and all of this work happened on the same day.

## [0.3.1] - 2026-10-15

### Fixed
- **A single file as the path lost its file name in the report.** `banned some.py` printed `6:    return os.system(cmd)` instead of `some.py:6:    return os.system(cmd)`, because `grep -r` omits the file name when its only operand is a file. `grep` now runs with `-H`. The rule still fired and the exit status was correct; only the report was incomplete. Directory scans were never affected.
  - Found by the new sample-file smoke test; the existing suite only ever scanned directories.

### Added
- `fixtures/`: inert sample Python files, one per shipped rule plus clean controls, known false positives and known gaps. See `fixtures/README.md`.
- `smoke_test.sh`: runs `banned` over the fixtures, both as the sourced function and as the executed file. Point it at an installed copy with `BANNED_SMOKE_SRC=...`.
- `planner.rules.example` now documents optional, disabled network rules (`requests`, `httpx`, `aiohttp`, `ftplib`, `smtplib`) and its known noise (`urllib.parse`, `websocket`).

## [0.3.0] - 2026-10-15

### Added
- `banned --version` and `BANNED_VERSION`.
- This changelog, with a test that keeps it in step with the version string.

## [0.2.1] - 2026-10-15

### Fixed
- **Executing the file ran no scan and reported nothing.** `./banned.sh DIR` defined the `banned` function, called nothing, printed nothing and exited `0`: a silent pass from a tool that is meant to fail closed. The file now has a shebang and checks whether it is being sourced or executed. Executed, it runs the scan and exits with the scan's status; sourced, it only defines the function, as before.
  - **Impact:** any `0` from running `./banned.sh` (or `bash banned.sh`) on a version before 0.2.1 was not a result. Sourcing the file and calling `banned` was never affected.
  - Found by running it, not by the tests, which only ever sourced the file.
- **The test runner could exit `0` without running.** If the code under test called `exit` while being sourced, the runner died silently with status `0`, which looks like a pass. It now exits `2` with a "NOT a pass" message if it stops before printing its summary.

### Added
- Tests for the executed path (via `bash`, and as `./banned.sh` with the exec bit), for sourcing staying side-effect free, and for the default profile location under `$HOME`.

## [0.2.0] - 2026-10-15

### Added
- Symlink notice: `Did not scan the following symlinks:` on stderr for symlinks `grep -r` does not follow (symlinked `.py` files, including dangling ones, and symlinks to directories). Notice only; exit status unchanged.
- If the `find` pass that lists them fails, the result is exit `2`.

### Security
- Symlink names are printed with `printf %q`, so a hostile file name cannot forge output lines or inject terminal escape sequences.
- A symlink named `.git` or `__pycache__` is still listed; only real directories of those names are skipped.

## [0.1.0] - 2026-10-15

### Added
- Rules as one array of `name::regex::reason` records; adding a rule is one line. Per-rule reporting: each hit is printed under the rule that fired.
- Initial rules: `subprocess`, `os-system`, `eval`, `exec`, `pickle`, `os-popen`, `os-exec`, `os-spawn`.
- Named profiles (`-p NAME`) loaded from `~/.config/banned/profiles/NAME.rules`, outside every project tree. Profile names are restricted to `[A-Za-z0-9_-]` so they cannot traverse out of the profile directory.
- Fail-closed exit codes: `0` clean, `1` found, `2` error. Empty or unset rule list, malformed record, invalid regex, missing path, unreadable directory and missing or empty profile are all `2`.
- Test suite (`test_banned.sh`), written before the implementation.

### Fixed
- `grep -I` in a UTF-8 locale silently dropped a match when the matching line held a byte that is not valid UTF-8 (valid Python under a PEP 263 coding line), while still exiting `0`. `grep` now runs with `LC_ALL=C`.

### Changed (compared with the original one-line function)
- An empty path argument is an error, not `.`.
- An error beats a hit: the exit status is `2` when both occur, and the hits are still printed.
