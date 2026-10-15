# INERT FIXTURE for banned: never import or run. Expect: rule os-popen.
import os


def never_called(cmd):
    return os.popen(cmd).read()
