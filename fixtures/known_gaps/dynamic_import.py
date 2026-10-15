# INERT FIXTURE for banned: never import or run.
# KNOWN GAP: the module name is data, not text in the source. Expect: clean (pinned).
import importlib


def never_called(name):
    return importlib.import_module(name)
