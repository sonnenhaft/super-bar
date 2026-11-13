"""Memory-only secret fixtures; importing this module never touches Keychain."""
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Scripts'))
import credential_store


class MemoryVault:
    def __init__(self):
        self.values = {}
        self.reads = 0
        self.writes = 0
        self.failure = None
        self.drop_writes = False

    def read(self, key):
        self.reads += 1
        if self.failure:
            raise self.failure
        return self.values.get(key)

    def write(self, key, data):
        self.writes += 1
        if self.failure:
            raise self.failure
        if not self.drop_writes:
            self.values[key] = data


def isolate_credentials(test):
    backing = MemoryVault()
    cached = credential_store.SessionVault(backing)
    replacement = patch.object(credential_store, 'DEFAULT_VAULT', cached)
    replacement.start()
    test.addCleanup(replacement.stop)
    for method in ('read', 'write'):
        guard = patch.object(credential_store.KeychainVault, method,
                             side_effect=AssertionError('Tests must never access real Keychain'))
        guard.start()
        test.addCleanup(guard.stop)
    test.credential_vault = cached
    test.credential_backing = backing


def clear_credentials(test):
    test.credential_backing.values.clear()
    test.credential_vault._values.clear()
