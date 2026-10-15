# INERT FIXTURE for banned: never import or run.
# KNOWN GAP: the dangerous name is assembled at runtime, so the text never
# contains it. A text matcher cannot see this. Expect: clean (pinned).
import os


def never_called(cmd):
    return getattr(os, "sys" + "tem")(cmd)
