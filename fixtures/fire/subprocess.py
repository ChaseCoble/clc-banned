# INERT FIXTURE for banned: never import or run. Expect: rule subprocess.
import subprocess


def never_called(cmd):
    return subprocess.run(cmd, shell=True)
