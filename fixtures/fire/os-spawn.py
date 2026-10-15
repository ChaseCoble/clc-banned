# INERT FIXTURE for banned: never import or run. Expect: rule os-spawn.
import os


def never_called():
    return os.spawnl(os.P_WAIT, "/bin/true", "true")
