# INERT FIXTURE for banned: never import or run. Expect: rule exec.


def never_called(s):
    exec(s)
