# INERT FIXTURE for banned: never import or run.
# Expect: clean by default, rule http-client only with -p planner.
import http.client


def never_called(host):
    return http.client.HTTPSConnection(host)
