# INERT FIXTURE for banned: never import or run.
# Expect: clean by default, rule socket only with -p planner.
import socket


def never_called(host):
    s = socket.socket()
    s.connect((host, 80))
    return s
