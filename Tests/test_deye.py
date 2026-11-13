"""Offline auth lifecycle tests; no real credentials or API calls."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit
from credential_fixtures import isolate_credentials


spec = importlib.util.spec_from_file_location('deye', Path(__file__).parents[1] / 'Scripts/deye.py')
deye = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deye)


class SessionTests(unittest.TestCase):
    def setUp(self):
        isolate_credentials(self)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'session.json'
        self.session_patch = patch.object(deye, 'SESSION', self.path)
        self.session_patch.start()
        self.addCleanup(self.session_patch.stop)
        # Any unexpected interactive prompt or network call fails the test.
        for target in ('connect', 'prompt_login'):
            guard = patch.object(deye, target, side_effect=AssertionError('unexpected ' + target))
            guard.start()
            self.addCleanup(guard.stop)
        self.client = deye.Client('https://eu1.deyecloud.com', 'old-token')
        self.client.refresh_token = 'old-refresh'
        self.client.email = 'test@example.com'
        self.client.password_sha256 = hashlib.sha256(b'fake-password').hexdigest()

    def test_valid_session_is_reused_without_login(self):
        self.client.expires_at = time.time() + 3600
        deye.save_session(self.client)
        client = deye.load_session()
        with patch.object(client, '_request', return_value={'generationPower': 0}) as request:
            self.assertEqual(client.call('/read'), {'generationPower': 0})
            request.assert_called_once_with('/read', None, None, None)

    def test_expiry_refresh_rotates_tokens_and_persists(self):
        self.client.expires_at = time.time() - 1
        with patch.object(self.client, '_request', side_effect=[
            {'access_token': 'new-token', 'refresh_token': 'new-refresh', 'expires_in': 3600},
            {'value': 12},
        ]) as request:
            self.assertEqual(self.client.call('/read'), {'value': 12})
            self.assertEqual(request.call_args_list[0].kwargs['query']['grant_type'], 'refresh_token')
        saved = deye.load_session()
        self.assertEqual(saved.token, 'new-token')
        self.assertEqual(saved.refresh_token, 'new-refresh')
        self.assertGreater(saved.expires_at, time.time())
        self.assertEqual(saved.password_sha256, self.client.password_sha256)
        self.assertFalse(self.path.exists())
        self.assertNotIn(b'fake-password', b''.join(self.credential_backing.values.values()))

    def test_401_refresh_then_retry_original_request(self):
        with patch.object(self.client, '_request', side_effect=[
            deye.AuthError('expired'), {'access_token': 'new-token'}, {'value': 12},
        ]) as request:
            self.assertEqual(self.client.call('/read', body={'page': 2}), {'value': 12})
            self.assertEqual(request.call_args_list[0], request.call_args_list[2])
        self.assertEqual(deye.load_session().refresh_token, 'old-refresh')

    def test_rejected_refresh_falls_back_to_saved_password_hash(self):
        self.client.expires_at = 1
        with patch.object(self.client, '_request', side_effect=[
            deye.AuthError('invalid grant'), {'access_token': 'login-token'}, {'value': 1},
        ]) as request:
            self.assertEqual(self.client.call('/read'), {'value': 1})
            query = request.call_args_list[1].kwargs['query']
            self.assertEqual(query['grant_type'], 'password')
            self.assertEqual(query['password'], self.client.password_sha256)
        self.assertEqual(deye.load_session().token, 'login-token')
        self.assertIsNone(deye.load_session().refresh_token)

    def test_network_failure_does_not_trigger_password_login(self):
        self.client.expires_at = 1
        with patch.object(self.client, '_request', side_effect=deye.DeyeError('network')) as request:
            with self.assertRaises(deye.DeyeError):
                self.client.call('/read')
            self.assertEqual(request.call_count, 1)

    def test_bad_saved_credentials_attempted_only_once(self):
        self.client.expires_at = 1
        with patch.object(self.client, '_request', side_effect=deye.AuthError('rejected')) as request:
            for _ in range(3):
                with self.assertRaises(deye.AuthError):
                    self.client.call('/read')
            self.assertEqual(request.call_count, 2)  # one refresh, one password grant

    def test_401_after_refresh_is_not_an_infinite_retry(self):
        with patch.object(self.client, '_request', side_effect=[
            deye.AuthError('expired'), {'access_token': 'new-token'}, deye.AuthError('still rejected'),
        ]) as request:
            for _ in range(2):
                with self.assertRaises(deye.AuthError):
                    self.client.call('/read')
            self.assertEqual(request.call_count, 3)

    def test_old_token_only_session_loads(self):
        self.path.write_text(json.dumps({'base': self.client.base, 'token': 'legacy'}))
        self.path.chmod(0o600)
        client = deye.load_session()
        self.assertEqual(client.token, 'legacy')
        self.assertIsNone(client.refresh_token)
        self.assertFalse(self.path.exists())

    def test_plaintext_in_existing_session_migrates(self):
        self.path.write_text(json.dumps({'base': self.client.base, 'token': 'legacy',
                                        'email': 'test@example.com', 'password': 'fake-password'}))
        self.path.chmod(0o600)
        client = deye.load_session()
        self.assertEqual(client.password_sha256, self.client.password_sha256)
        self.assertFalse(self.path.exists())
        self.assertNotIn('password', json.loads(next(iter(self.credential_backing.values.values()))))

    def test_transport_sends_refresh_without_stale_authorization(self):
        with patch.object(deye, 'connect', return_value=io.StringIO(json.dumps({
            'access_token': 'fresh', 'refresh_token': 'rotated', 'expires_in': '3600',
        }))) as transport:
            self.client.refresh()
            request = transport.call_args.args[0]
            self.assertEqual(request.method, 'POST')
            self.assertIsNone(request.get_header('Authorization'))
            query = parse_qs(urlsplit(request.full_url).query)
            self.assertEqual(query['refresh_token'], ['old-refresh'])

    def test_error_messages_do_not_expose_tokens(self):
        error = HTTPError('https://eu1.deyecloud.com/?refresh_token=SECRET', 400, 'SECRET', {}, None)
        with patch.object(deye, 'connect', side_effect=error):
            with self.assertRaises(deye.AuthError) as caught:
                self.client.refresh()
        self.assertNotIn('SECRET', str(caught.exception))

    def test_forbidden_read_does_not_refresh(self):
        error = HTTPError('https://eu1.deyecloud.com/read', 403, 'Forbidden', {}, None)
        with patch.object(deye, 'connect', side_effect=error) as transport:
            with self.assertRaises(deye.DeyeError):
                self.client.call('/read')
            self.assertEqual(transport.call_count, 1)


if __name__ == '__main__':
    unittest.main()
