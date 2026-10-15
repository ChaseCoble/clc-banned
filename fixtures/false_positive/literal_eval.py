# INERT FIXTURE for banned: never import or run.
# KNOWN FALSE POSITIVE: the literal-only parser from the ast module is safe
# against code execution, but the eval rule has no word boundary so it fires.
# Accepted on purpose: you are told every time, then you decide.
# Expect: rule eval fires.
import ast


def never_called(raw):
    return ast.literal_eval(raw)
