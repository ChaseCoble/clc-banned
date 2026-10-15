# INERT FIXTURE for banned: never import or run.
# Expect: clean by default, rule urllib only with -p planner.
import urllib.request


def never_called(url):
    return urllib.request.urlopen(url)
