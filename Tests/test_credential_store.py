"""Credential persistence checks use synthetic data and never call SecItem."""
import concurrent.futures
import ctypes
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from credential_fixtures import MemoryVault, isolate_credentials
import credential_store as storage


class CredentialTests(unittest.TestCase):
    def setUp(self):
        isolate_credentials(self)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'legacy.json'
        self.value = {'token': 'synthetic-access', 'refresh_token': 'synthetic-refresh',
                      'password_hash': 'synthetic-hash'}

    def store(self, **kwargs):
        return storage.JSONCredentialStore(self.path, 'test-session', **kwargs)

    def legacy(self):
        self.path.write_text(json.dumps(self.value))
        self.path.chmod(0o600)

    def test_save_all_secrets_without_creating_a_file(self):
        self.store().save(self.value)
        self.assertEqual(self.store().load(), self.value)
        self.assertFalse(self.path.exists())
        self.assertEqual(list(self.path.parent.iterdir()), [])

    def test_verified_migration_deletes_owned_legacy_file(self):
        self.legacy()
        self.assertEqual(self.store().load(), self.value)
        self.assertFalse(self.path.exists())
        self.assertEqual(json.loads(self.credential_backing.values[self.store().key]), self.value)

    def test_failed_write_keeps_legacy_file_and_stops_retries(self):
        self.legacy()
        self.credential_backing.drop_writes = True
        for _ in range(3):
            with self.assertRaises(storage.CredentialError):
                self.store().load()
        self.assertEqual(self.credential_backing.writes, 1)
        self.assertEqual(json.loads(self.path.read_text()), self.value)

    def test_read_failure_does_not_use_legacy_fallback(self):
        self.legacy()
        self.credential_backing.failure = storage.CredentialError('synthetic denial')
        for _ in range(3):
            with self.assertRaises(storage.CredentialError):
                self.store().load()
        self.assertEqual(self.credential_backing.reads, 1)
        self.assertEqual(self.credential_backing.writes, 0)
        self.assertTrue(self.path.exists())

    def test_valid_keychain_wins_and_removes_stale_owned_file(self):
        self.store().save(self.value)
        self.path.write_text('{old malformed legacy data')
        self.path.chmod(0o600)
        self.assertEqual(self.store().load(), self.value)
        self.assertFalse(self.path.exists())

    def test_invalid_keychain_data_does_not_replace_from_legacy(self):
        self.legacy()
        self.credential_backing.values[self.store().key] = b'invalid'
        with self.assertRaises(storage.CredentialError):
            self.store().load()
        self.assertTrue(self.path.exists())
        self.assertEqual(self.credential_backing.writes, 0)

    def test_validation_runs_before_legacy_migration(self):
        self.legacy()
        def invalid(value):
            raise ValueError('synthetic failure')
        with self.assertRaises(storage.CredentialError):
            self.store(validate=invalid).load()
        self.assertTrue(self.path.exists())
        self.assertEqual(self.credential_backing.writes, 0)

    def test_rejects_symlinks_public_files_and_fifo_without_blocking(self):
        self.legacy()
        self.path.chmod(0o644)
        with self.assertRaises(storage.CredentialError):
            self.store().load()
        self.path.unlink()
        target = self.path.with_name('target')
        target.write_text('{}')
        self.path.symlink_to(target)
        with self.assertRaises(storage.CredentialError):
            self.store().load()
        self.path.unlink()
        os.mkfifo(self.path, 0o600)
        with self.assertRaises(storage.CredentialError):
            self.store().load()
        self.assertTrue(self.path.exists())

    def test_modified_legacy_file_is_preserved_after_verification(self):
        self.legacy()
        original_write = self.credential_backing.write
        def mutate(key, data):
            original_write(key, data)
            self.path.write_text('{"token":"newer-external-value"}')
        with patch.object(self.credential_backing, 'write', side_effect=mutate):
            with self.assertRaises(storage.CredentialError):
                self.store().load()
        self.assertEqual(json.loads(self.path.read_text())['token'], 'newer-external-value')

    def test_path_identity_is_stable_and_accounts_are_separate(self):
        alias = self.path.parent / 'unused' / '..' / self.path.name
        self.assertEqual(self.store().key, storage.JSONCredentialStore(alias, 'test-session').key)
        self.assertNotEqual(self.store().key, storage.JSONCredentialStore(self.path, 'other-session').key)
        self.assertNotEqual(self.store().key, storage.JSONCredentialStore(self.path.with_name('other'), 'test-session').key)

    def test_process_cache_coalesces_parallel_reads_and_failures(self):
        self.credential_backing.values['first'] = b'synthetic'
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            values = list(pool.map(lambda _: self.credential_vault.read('first'), range(32)))
        self.assertEqual(values, [b'synthetic'] * 32)
        self.assertEqual(self.credential_backing.reads, 1)
        self.credential_backing.failure = storage.CredentialError('synthetic denial')
        def denied(index):
            with self.assertRaises(storage.CredentialError):
                self.credential_vault.read(str(index))
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            list(pool.map(denied, range(32)))
        self.assertEqual(self.credential_backing.reads, 2)
        self.assertEqual(self.credential_vault.read('first'), b'synthetic')

    def test_unchanged_writes_are_skipped_and_changed_writes_are_verified(self):
        self.store().save(self.value)
        self.store().save(self.value)
        self.assertEqual(self.credential_backing.writes, 1)
        self.assertEqual(self.credential_backing.reads, 1)
        self.store().save(dict(self.value, token='rotated'))
        self.assertEqual(self.credential_backing.writes, 2)
        self.assertEqual(self.credential_backing.reads, 2)

    def test_unverified_write_invalidates_previous_cached_value(self):
        self.credential_vault.write('first', b'old')
        self.credential_backing.drop_writes = True
        with self.assertRaises(storage.CredentialError):
            self.credential_vault.write('first', b'new')
        with self.assertRaises(storage.CredentialError):
            self.credential_vault.read('first')

    def test_unsupported_platform_fails_closed_before_loading_security(self):
        vault = storage.KeychainVault()
        with patch.object(storage.sys, 'platform', 'linux'), patch.object(storage.ctypes, 'CDLL') as library:
            with self.assertRaises(storage.CredentialError):
                vault._load()
        library.assert_not_called()

    def test_library_initialization_error_does_not_become_missing_credentials(self):
        vault = storage.KeychainVault()
        with patch.object(storage.sys, 'platform', 'darwin'), patch.object(storage.ctypes, 'CDLL', side_effect=OSError('synthetic')):
            with self.assertRaises(storage.CredentialError):
                vault._load()


class NativeBindingTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'CoreFoundation is available only on macOS')
    def test_native_dictionary_ownership_and_binary_value_readback(self):
        # Exercises ctypes signatures and CF retain/release, never SecItem.
        vault = storage.KeychainVault()
        vault._load()
        vault.cf.CFDictionaryGetValue.restype = ctypes.c_void_p
        vault.cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        vault.cf.CFStringGetTypeID.restype = ctypes.c_ulong
        vault.cf.CFStringGetTypeID.argtypes = []
        guards = [patch.object(vault.sec, method, side_effect=AssertionError('No Keychain access in tests'))
                  for method in ('SecItemCopyMatching', 'SecItemUpdate', 'SecItemAdd')]
        for guard in guards:
            guard.start()
            self.addCleanup(guard.stop)
        value = b'synthetic\0binary\xff'
        query = vault._dictionary(dict(vault._query('synthetic-test-account'), kSecValueData=value))
        try:
            data = vault.cf.CFDictionaryGetValue(query, vault._constant('kSecValueData'))
            self.assertEqual(vault.cf.CFGetTypeID(data), vault.cf.CFDataGetTypeID())
            self.assertEqual(ctypes.string_at(vault.cf.CFDataGetBytePtr(data), vault.cf.CFDataGetLength(data)), value)
            service = vault.cf.CFDictionaryGetValue(query, vault._constant('kSecAttrService'))
            self.assertEqual(vault.cf.CFGetTypeID(service), vault.cf.CFStringGetTypeID())
            category = vault.cf.CFDictionaryGetValue(query, vault._constant('kSecClass'))
            self.assertEqual(category, vault._constant('kSecClassGenericPassword'))
            sync = vault.cf.CFDictionaryGetValue(query, vault._constant('kSecAttrSynchronizable'))
            self.assertEqual(sync, vault._constant('kCFBooleanFalse'))
        finally:
            vault.cf.CFRelease(query)


if __name__ == '__main__':
    unittest.main()
