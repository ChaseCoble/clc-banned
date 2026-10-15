# INERT FIXTURE for banned: never import or run. Expect: rule os-system.
import os


def never_called(cmd):
    return os.system(cmd)
