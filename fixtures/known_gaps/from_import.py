# INERT FIXTURE for banned: never import or run.
# KNOWN GAP: the rule looks for the dotted form, so importing the name directly
# slips past. Expect: clean (pinned).
from os import system


def never_called(cmd):
    return system(cmd)
