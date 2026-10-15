# Sample files for `banned`

Small Python files that `banned` should (or deliberately should not) flag. They are **inert**: valid Python whose dangerous calls sit inside functions that are never called, so nothing happens on import. `banned` only reads them as text. Do not import, run, or add them to a test runner's collection path.

`smoke_test.sh` (one directory up) runs `banned` over these and checks the results, both as the sourced function and as the executed file:

```bash
bash smoke_test.sh                                                      # the copy in this repo
BANNED_SMOKE_SRC=~/.local/share/banned/banned.sh bash smoke_test.sh     # your installed copy
```

| Directory | Meaning | Expected |
|---|---|---|
| `fire/` | One file per global rule, named after it (`os-system.py` is rule `os-system`) | The named rule fires, exit `1` |
| `network/` | One file per rule in `planner.rules.example` | Clean by default; the rule fires only with `-p planner` |
| `clean/` | Look-alikes that must not trip anything (`os.path`, `json.loads`, `re.compile`) | Clean, with or without a profile |
| `false_positive/` | Harmless code that fires anyway (`ast.literal_eval` matches the `eval` rule) | Fires; accepted on purpose |
| `known_gaps/` | Evasions `banned` does **not** catch (runtime-built names, `from os import system`, dynamic import) | Clean; pinned so a change is noticed |

Rules and fixtures are checked in both directions: a rule with no fixture fails, and so does a fixture with no rule. Adding a rule to `banned.sh` or a profile means adding its sample file here.

Because these files contain the very text `banned` looks for, scanning the whole repository will report them. Scan a project directory, or `fixtures/` on purpose.
