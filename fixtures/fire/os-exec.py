# INERT FIXTURE for banned: never import or run. Expect: rule os-exec.
import os


def never_called():
    os.execv("/bin/true", ["true"])
