"""Keychain-only credential persistence for local macOS tools (stdlib only).

Legacy paths identify accounts and are read once for migration. Credentials are
never sent to a subprocess, logged, or written to a plaintext fallback file.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import threading


class CredentialError(Exception):
    pass


class KeychainVault:
    """Small lazy binding to Apple's public SecItem/CoreFoundation APIs."""
    def __init__(self):
        self._loaded = False

    def _load(self):
        if self._loaded:
            return
        if sys.platform != 'darwin':
            raise CredentialError('This tool requires macOS Keychain; no file fallback is available.')
        try:
            self.cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
            self.sec = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
            pointer, index = ctypes.c_void_p, ctypes.c_long
            definitions = {
                'CFStringCreateWithBytes': (pointer, [pointer, pointer, index, ctypes.c_uint32, ctypes.c_bool]),
                'CFDataCreate': (pointer, [pointer, pointer, index]),
                'CFDataGetLength': (index, [pointer]),
                'CFDataGetBytePtr': (pointer, [pointer]),
                'CFDataGetTypeID': (ctypes.c_ulong, []),
                'CFGetTypeID': (ctypes.c_ulong, [pointer]),
                'CFDictionaryCreate': (pointer, [pointer, pointer, pointer, index, pointer, pointer]),
                'CFRelease': (None, [pointer]),
            }
            for name, (result, arguments) in definitions.items():
                function = getattr(self.cf, name)
                function.restype, function.argtypes = result, arguments
            for name, arguments in {
                'SecItemCopyMatching': [pointer, ctypes.POINTER(pointer)],
                'SecItemUpdate': [pointer, pointer],
                'SecItemAdd': [pointer, ctypes.POINTER(pointer)],
            }.items():
                function = getattr(self.sec, name)
                function.restype, function.argtypes = ctypes.c_int32, arguments
            self._loaded = True
        except (OSError, AttributeError, ValueError):
            raise CredentialError('Could not load macOS Keychain services.') from None

    def _constant(self, name):
        library = self.cf if name.startswith('kCF') else self.sec
        return ctypes.c_void_p.in_dll(library, name).value

    def _dictionary(self, fields):
        owned, keys, values = [], [], []
        try:
            for name, value in fields.items():
                keys.append(self._constant(name))
                if isinstance(value, str):
                    data = value.encode('utf-8')
                    ref = self.cf.CFStringCreateWithBytes(None, data, len(data), 0x08000100, False)
                    owned.append(ref)
                elif isinstance(value, bytes):
                    ref = self.cf.CFDataCreate(None, value, len(value))
                    owned.append(ref)
                else:
                    ref = self._constant('kCFBooleanTrue' if value else 'kCFBooleanFalse')
                if not ref:
                    raise CredentialError('Could not prepare a Keychain request.')
                values.append(ref)
            # Class is a CFString constant, not the literal spelling of its name.
            if 'kSecClass' in fields:
                values[list(fields).index('kSecClass')] = self._constant('kSecClassGenericPassword')
            count = len(keys)
            array = ctypes.c_void_p * count
            key_callbacks = ctypes.addressof(ctypes.c_byte.in_dll(self.cf, 'kCFTypeDictionaryKeyCallBacks'))
            value_callbacks = ctypes.addressof(ctypes.c_byte.in_dll(self.cf, 'kCFTypeDictionaryValueCallBacks'))
            result = self.cf.CFDictionaryCreate(None, array(*keys), array(*values), count,
                                                key_callbacks, value_callbacks)
            if not result:
                raise CredentialError('Could not prepare a Keychain request.')
            return result
        finally:
            for ref in owned:
                if ref:
                    self.cf.CFRelease(ref)

    @staticmethod
    def _check(status):
        if status:
            raise CredentialError('Could not access Keychain. Unlock it and restart this command to retry.')

    @staticmethod
    def _query(key):
        return {'kSecClass': 'generic-password', 'kSecAttrService': 'com.sonnenhaft.superbar.cli',
                'kSecAttrAccount': key, 'kSecAttrSynchronizable': False}

    def read(self, key):
        self._load()
        query = self._dictionary(dict(self._query(key), kSecReturnData=True))
        result = ctypes.c_void_p()
        try:
            status = self.sec.SecItemCopyMatching(query, ctypes.byref(result))
            if status == -25300:  # errSecItemNotFound
                return None
            self._check(status)
            if not result.value or self.cf.CFGetTypeID(result) != self.cf.CFDataGetTypeID():
                raise CredentialError('Keychain returned invalid credential data.')
            size = self.cf.CFDataGetLength(result)
            if size < 0 or size > 1024 * 1024:
                raise CredentialError('Keychain returned invalid credential data.')
            return ctypes.string_at(self.cf.CFDataGetBytePtr(result), size)
        finally:
            if result.value:
                self.cf.CFRelease(result)
            self.cf.CFRelease(query)

    def write(self, key, data):
        self._load()
        query = self._dictionary(self._query(key))
        attributes = self._dictionary({'kSecValueData': data})
        try:
            status = self.sec.SecItemUpdate(query, attributes)
            if status == -25300:
                addition = self._dictionary(dict(self._query(key), kSecValueData=data))
                try:
                    status = self.sec.SecItemAdd(addition, None)
                finally:
                    self.cf.CFRelease(addition)
            self._check(status)
        finally:
            self.cf.CFRelease(attributes)
            self.cf.CFRelease(query)


class SessionVault:
    """Coalesce reads and suppress repeated permission prompts in one process."""
    def __init__(self, backing):
        self.backing = backing
        self._lock = threading.RLock()
        self._values = {}
        self._failure = None

    def read(self, key):
        with self._lock:
            if key in self._values:
                return self._values[key]
            if self._failure:
                raise self._failure
            try:
                value = self.backing.read(key)
                self._values[key] = value
                return value
            except CredentialError as error:
                self._failure = error
                raise

    def write(self, key, data):
        with self._lock:
            if key in self._values and self._values[key] == data:
                return
            self._values.pop(key, None)
            if self._failure:
                raise self._failure
            try:
                self.backing.write(key, data)
                if self.backing.read(key) != data:
                    raise CredentialError('Could not verify credentials saved in Keychain.')
                self._values[key] = data
            except CredentialError as error:
                self._failure = error
                raise


DEFAULT_VAULT = SessionVault(KeychainVault())


def read_legacy_file(path):
    """Read a bounded private regular file through the validated descriptor.

    Used for both owned migrations and external discovery; callers decide
    ownership and never delete external import sources.
    """
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError:
        raise CredentialError('Could not open the legacy credential file safely.') from None
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_size > 1024 * 1024):
            raise CredentialError('Legacy credentials must be a private file owned by you (mode 600).')
        data = stream.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise CredentialError('Legacy credential data is too large to read safely.')
        return data, info


class JSONCredentialStore:
    def __init__(self, path, kind, validate=lambda value: value, vault=None):
        self.path = Path(os.path.abspath(os.path.expanduser(path)))
        identity = os.path.join(os.path.realpath(self.path.parent), self.path.name)
        self.key = kind + ':' + hashlib.sha256(os.fsencode(identity)).hexdigest()
        self.validate = validate
        self.vault = DEFAULT_VAULT if vault is None else vault

    def _decode(self, data):
        try:
            return self.validate(json.loads(data))
        except (ValueError, UnicodeError, TypeError):
            raise CredentialError('Stored credentials are invalid. Sign in again.') from None

    def _remove_legacy(self, original=None):
        try:
            info = self.path.lstat()
        except FileNotFoundError:
            return
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise CredentialError('The legacy credential path must be a file owned by you.')
        if original is not None:
            identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_ctime_ns)
            if identity(info) != identity(original):
                raise CredentialError('The legacy credential file changed during migration; it was preserved.')
        self.path.unlink()

    def load(self):
        data = self.vault.read(self.key)
        if data is not None:
            value = self._decode(data)
            self._remove_legacy()
            return value
        legacy = read_legacy_file(self.path)
        if legacy is None:
            return None
        data, info = legacy
        value = self._decode(data)
        self._save(value)
        self._remove_legacy(info)
        return value

    def _save(self, value):
        value = self.validate(value)
        data = json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
        if len(data) > 1024 * 1024:
            raise CredentialError('Credential data is too large to save safely.')
        self.vault.write(self.key, data)
        if self.vault.read(self.key) != data:
            raise CredentialError('Could not verify credentials saved in Keychain.')

    def save(self, value):
        self._save(value)
        self._remove_legacy()
