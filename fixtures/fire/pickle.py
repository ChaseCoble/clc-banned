# INERT FIXTURE for banned: never import or run. Expect: rule pickle.
import pickle


def never_called(blob):
    return pickle.loads(blob)
