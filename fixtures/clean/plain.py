# INERT FIXTURE for banned: never import or run. Expect: clean, with or without
# a profile. Look-alikes that must NOT trip any rule are deliberate here.
import json
import os
import re

PATTERN = re.compile(r"[a-z]+")


def never_called(base, name, raw):
    path = os.path.join(base, name)
    data = json.loads(raw)
    return path, data, PATTERN.findall(name)
