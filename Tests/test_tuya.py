import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import base64
import hashlib
import hmac
import io
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from credential_fixtures import isolate_credentials, clear_credentials

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Scripts'))
import tuya_wire

spec = importlib.util.spec_from_file_location('tuya', Path(__file__).resolve().parents[1] / 'Scripts/tuya.py')
tuya = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tuya)


def session():
    return {'client_id': tuya.CLIENT_ID, 'user_code': 'test', 'terminal_id': 'terminal',
            'endpoint': 'https://apigw.tuyaeu.com', 'token_info': {
                't': int(time.time() * 1000), 'expire_time': 3600, 'uid': 'user',
                'access_token': 'test-access', 'refresh_token': 'test-refresh'}}


def device(status=None, specs=None, **extra):
    data = dict(id='meter1', name='Main meter', product_name='Energy meter', category='zndb',
                online=True, status=status or {'cur_power': 12345},
                status_range=specs or {'cur_power': {'values': '{"unit":"W","scale":1}'}},
                local_key='SECRET')
    data.update(extra)
    return SimpleNamespace(**data)


class PowerTests(unittest.TestCase):
    def test_scaled_watts_to_kw(self):
        self.assertAlmostEqual(tuya.device_report(device())['power_kw'], 1.2345)

    def test_kw_and_negative_export(self):
        d = device({'total_power': -231}, {'total_power': {'values': {'unit': 'kW', 'scale': 2}}})
        self.assertEqual(tuya.device_report(d)['power_kw'], -2.31)

    def test_zero_is_a_reading(self):
        self.assertEqual(tuya.device_report(device({'cur_power': 0}))['power_kw'], 0)

    def test_milliwatts_and_megawatts_are_distinct(self):
        for unit, expected in [('mW', .000001), ('MW', 1000)]:
            d = device({'cur_power': 1}, {'cur_power': {'values': {'unit': unit, 'scale': 0}}})
            self.assertEqual(tuya.device_report(d)['power_kw'], expected)

    def test_missing_scale_not_guessed(self):
        d = device(specs={'cur_power': {'values': {'unit': 'W'}}})
        self.assertIsNone(tuya.device_report(d)['power_kw'])

    def test_energy_not_mistaken_for_power(self):
        d = device({'total_power': 42}, {'total_power': {'values': {'unit': 'kWh', 'scale': 0}}})
        self.assertIsNone(tuya.device_report(d)['power_kw'])

    def test_total_not_double_counted_with_phases(self):
        readings = {'total_power': 600, 'power_a': 100, 'power_b': 200, 'power_c': 300}
        specs = {k: {'values': {'unit': 'W', 'scale': 0}} for k in readings}
        self.assertEqual(tuya.device_report(device(readings, specs))['power_kw'], .6)
        del readings['total_power']
        self.assertAlmostEqual(tuya.device_report(device(readings, specs))['power_kw'], .6)
        del readings['power_c']
        self.assertIsNone(tuya.device_report(device(readings, specs))['power_kw'])

    def test_offline_not_reported_as_current(self):
        result = tuya.device_report(device(online=False))
        self.assertIsNone(result['power_kw'])
        self.assertEqual(result['last_reported_power_kw'], 1.2345)
        self.assertNotIn('SECRET', json.dumps(result))

    def test_invalid_values_not_zero(self):
        for value in (None, True, float('nan'), float('inf'), 'bad'):
            self.assertIsNone(tuya.device_report(device({'cur_power': value}))['power_kw'])

    def test_ambiguous_meter_not_selected_by_largest_load(self):
        devices = [tuya.device_report(device(name='Meter A')),
                   tuya.device_report(device(id='meter2', name='Meter B', status={'cur_power': 90000}))]
        self.assertEqual(tuya.select_meter(devices), (None, 'ambiguous'))
        self.assertEqual(tuya.select_meter(devices, 'meter2')[0]['id'], 'meter2')

    def test_saved_meter_missing_is_error(self):
        with self.assertRaises(tuya.TuyaError):
            tuya.select_meter([tuya.device_report(device())], 'removed')

    def test_unique_meter_is_only_candidate(self):
        self.assertEqual(tuya.select_meter([tuya.device_report(device())])[1], 'candidate_by_name')


class SessionTests(unittest.TestCase):
    def setUp(self):
        isolate_credentials(self)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'session.json'
        self.store = tuya.SessionStore(self.path)
        self.store.data = session()
        self.store.save()

    def test_atomic_save_private_and_refresh_survives_restart(self):
        self.assertFalse(self.path.exists())
        token = dict(self.store.data['token_info'], access_token='rotated', refresh_token='rotated-refresh')
        self.store.update_token(token)
        restarted = tuya.SessionStore(self.path).load()
        self.assertEqual(restarted['token_info'], token)

    def test_valid_session_also_migrates_old_login_hash(self):
        settings = tuya.LoginSettings(self.path)
        saved = {'email': 'test@example.com', 'password_md5': hashlib.md5(b'synthetic').hexdigest()}
        settings.path.write_text(json.dumps(saved))
        settings.path.chmod(0o600)
        with patch.object(tuya, 'password_login', side_effect=AssertionError('must not prompt')):
            tuya.ensure_login(self.store)
        self.assertFalse(settings.path.exists())
        self.assertEqual(settings.load(), saved)

    def test_login_migration_failure_is_not_treated_as_missing_account(self):
        settings = tuya.LoginSettings(self.path)
        settings.path.write_text(json.dumps({'email': 'test@example.com'}))
        settings.path.chmod(0o600)
        from credential_fixtures import credential_store
        self.credential_backing.failure = credential_store.CredentialError('synthetic denial')
        with patch.object(tuya, 'password_login', side_effect=AssertionError('must not prompt')):
            with self.assertRaises(tuya.TuyaError):
                tuya.ensure_login(self.store)
        self.assertTrue(settings.path.exists())

    def test_rejects_public_or_symlink_session(self):
        clear_credentials(self)
        self.path.write_text(json.dumps(session()))
        self.path.chmod(0o644)
        with self.assertRaises(tuya.TuyaError):
            self.store.load()
        link = self.path.with_name('link')
        link.symlink_to(self.path)
        with self.assertRaises(tuya.TuyaError):
            tuya.SessionStore(link).load()

    def test_rejects_untrusted_endpoint(self):
        for endpoint in ('http://apigw.tuyaeu.com', 'https://tuyaeu.com.evil.example',
                         'https://user@apigw.tuyaeu.com', 'https://apigw.tuyaeu.com/token'):
            data = session()
            data['endpoint'] = endpoint
            with self.assertRaises(tuya.TuyaError):
                tuya.validate_session(data)

    def test_client_reuses_login_and_never_revokes_on_exit(self):
        rows = [dict(vars(device()), status=[{'code': 'cur_power', 'value': 12345}])]
        spec = {'status': [{'code': 'cur_power', 'values': '{"unit":"W","scale":1}'}]}
        with patch.object(tuya.Client, 'get', side_effect=[[{'ownerId': 123}], rows, spec]) as get:
            with patch.object(tuya, 'login', side_effect=AssertionError('must not prompt')):
                with tuya.Client(self.path) as client:
                    self.assertEqual(client.devices()[0]['power_kw'], 1.2345)
        self.assertEqual(get.call_count, 3)
        self.assertEqual(get.call_args_list[1].args[1], {'homeId': '123'})
        self.assertEqual(tuya.SessionStore(self.path).load()['token_info']['access_token'], 'test-access')

    def test_expired_token_refreshes_and_is_saved_before_read(self):
        self.store.data['token_info']['t'] = 1
        self.store.save()
        refresh = {'success': True, 't': int(time.time() * 1000), 'result': {
            'expireTime': 3600, 'uid': 'user', 'accessToken': 'new-access', 'refreshToken': 'new-refresh'}}
        def reply(path, params=None):
            if path.startswith('/v1.0/m/token/'):
                return refresh
            self.assertEqual(tuya.SessionStore(self.path).load()['token_info']['refresh_token'], 'new-refresh')
            return {'success': True, 'result': []}
        with tuya.Client(self.path) as client, patch.object(client, '_request', side_effect=reply) as request:
            self.assertEqual(client.get('/read'), [])
            self.assertEqual(request.call_count, 2)

    def test_auth_retry_is_bounded(self):
        with tuya.Client(self.path) as client:
            with patch.object(client, '_request', side_effect=tuya.AuthError('rejected')) as request:
                for _ in range(3):
                    with self.assertRaises(tuya.AuthError):
                        client.get('/read')
                self.assertEqual(request.call_count, 2)

    def test_network_error_does_not_trigger_login_or_refresh(self):
        with tuya.Client(self.path) as client:
            with patch.object(client, '_request', side_effect=tuya.TuyaError('network')) as request:
                with self.assertRaises(tuya.TuyaError):
                    client.get('/read')
                self.assertEqual(request.call_count, 1)

    def test_rotated_credentials_used_after_auth_retry(self):
        refreshed = {'success': True, 't': int(time.time() * 1000), 'result': {
            'expireTime': 3600, 'uid': 'user', 'accessToken': 'rotated-access', 'refreshToken': 'rotated-refresh'}}
        with tuya.Client(self.path) as client:
            with patch.object(client, '_request', side_effect=[tuya.AuthError('expired'), refreshed,
                                                               {'success': True, 'result': ['ok']}]) as request:
                self.assertEqual(client.get('/read'), ['ok'])
                self.assertEqual(request.call_count, 3)
                self.assertEqual(client.store.data['token_info']['access_token'], 'rotated-access')
                self.assertEqual(tuya.SessionStore(self.path).load()['token_info']['refresh_token'], 'rotated-refresh')

    def test_corrupt_encrypted_response_fails_closed(self):
        with tuya.Client(self.path) as client:
            with patch.object(tuya, 'request_json', return_value={'success': True, 'result': 'broken'}):
                with self.assertRaises(tuya.TuyaError):
                    client.get('/read')

    def test_wire_signature_encryption_and_response_decryption(self):
        nonce = bytes(range(12))
        def server(url, method='GET', headers=None):
            rid = headers['X-requestId']
            key = hashlib.md5((rid + 'test-refresh').encode()).hexdigest().encode()
            secret = hmac.new(rid.encode(), key, hashlib.sha256).hexdigest()[:16].encode()
            encoded = parse_qs(urlsplit(url).query)['encdata'][0]
            encrypted = base64.b64decode(encoded)
            decoded = tuya_wire.gcm_decrypt(secret, encrypted[:12], encrypted[12:])
            self.assertEqual(json.loads(decoded), {'homeId': '123'})
            signed_headers = ('X-appKey', 'X-requestId', 'X-sid', 'X-time', 'X-token')
            message = '||'.join(k + '=' + headers[k] for k in signed_headers if headers[k]) + encoded
            self.assertEqual(headers['X-sign'], hmac.new(key, message.encode(), hashlib.sha256).hexdigest())
            self.assertEqual(headers['X-token'], 'test-access')
            return {'success': True, 'result': base64.b64encode(nonce + tuya_wire.gcm_encrypt(secret, nonce, b'[{"id":"device"}]')).decode()}
        with tuya.Client(self.path) as client, patch.object(tuya, 'request_json', side_effect=server):
            self.assertEqual(client.get('/devices', {'homeId': '123'}), [{'id': 'device'}])

    def test_login_direct_endpoints_and_saved_session(self):
        info = dict(session()['token_info'], endpoint=session()['endpoint'], terminal_id='terminal')
        replies = [{'success': True, 'result': {'qrcode': 'test-qr'}},
                   {'success': False}, {'success': True, 't': info['t'], 'result': info}]
        with patch.object(tuya, 'request_json', side_effect=replies) as request, \
                patch.object(tuya, 'print_qr') as qr, patch.object(tuya.time, 'sleep'), \
                patch.object(tuya.sys, 'stderr', io.StringIO()):
            tuya.login(self.store, 'USER123')
        self.assertEqual(request.call_args_list[0].kwargs['method'], 'POST')
        self.assertIn('schema=haauthorize', request.call_args_list[0].args[0])
        self.assertIn('/test-qr?', request.call_args_list[1].args[0])
        self.assertEqual(qr.call_args.args[0], 'tuyaSmart--qrLogin?token=test-qr')
        self.assertEqual(tuya.SessionStore(self.path).load()['user_code'], 'USER123')


class AutoLoginTests(unittest.TestCase):
    def setUp(self):
        isolate_credentials(self)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = tuya.SessionStore(self.root / '.env.tuya-session.json')
        self.source = self.root / 'tuya-session.json'
        self.candidates = patch.object(tuya, 'session_candidates', return_value=[self.source])
        self.candidates.start()
        self.addCleanup(self.candidates.stop)

    def test_import_existing_session_without_prompt(self):
        self.source.write_text(json.dumps(session()))
        self.source.chmod(0o600)
        with patch.object(tuya, 'password_login') as login:
            tuya.ensure_login(self.store)
        login.assert_not_called()
        self.assertEqual(self.store.load()['token_info']['access_token'], 'test-access')
        self.assertFalse(self.store.path.exists())
        self.assertTrue(self.source.exists(), 'External imports are not owned by this tool')

    def test_saved_session_takes_precedence_over_discovery(self):
        self.store.data = session()
        self.store.save()
        with patch.object(tuya, 'session_candidates', side_effect=AssertionError('must not search')):
            with patch.object(tuya, 'password_login') as login:
                tuya.ensure_login(self.store)
        login.assert_not_called()

    def test_no_session_starts_interactive_login_without_flags(self):
        with patch.object(tuya.sys.stdin, 'isatty', return_value=True):
            with patch.object(tuya, 'password_login') as login:
                tuya.ensure_login(self.store)
        login.assert_called_once_with(self.store)

    def test_headless_missing_session_does_not_hang_or_require_flags(self):
        with patch.object(tuya.sys.stdin, 'isatty', return_value=False):
            with patch.object(tuya, 'password_login') as login:
                with self.assertRaises(tuya.TuyaError) as caught:
                    tuya.ensure_login(self.store)
        login.assert_not_called()
        self.assertNotIn('--', str(caught.exception))

    def test_invalid_source_is_skipped(self):
        invalid = session()
        invalid['endpoint'] = 'https://attacker.example'
        self.source.write_text(json.dumps(invalid))
        self.source.chmod(0o600)
        self.assertIsNone(tuya.load_available_session(self.store))
        self.assertFalse(self.store.path.exists())

    def test_multiple_accounts_are_not_silently_mixed(self):
        self.source.write_text(json.dumps(session()))
        self.source.chmod(0o600)
        second = self.root / 'another.json'
        data = session()
        data['token_info']['uid'] = 'another-user'
        second.write_text(json.dumps(data))
        second.chmod(0o600)
        with patch.object(tuya, 'session_candidates', return_value=[self.source, second]):
            with self.assertRaises(tuya.TuyaError):
                tuya.load_available_session(self.store)
        self.assertFalse(self.store.path.exists())

    def test_discovery_rejects_public_symlink_and_fifo_credentials(self):
        self.source.write_text(json.dumps(session()))
        self.source.chmod(0o644)
        self.assertIsNone(tuya.load_available_session(self.store))
        self.source.chmod(0o600)
        link = self.source.with_name('link.json')
        link.symlink_to(self.source)
        with patch.object(tuya, 'session_candidates', return_value=[link]):
            self.assertIsNone(tuya.load_available_session(self.store))
        fifo = self.source.with_name('fifo.json')
        os.mkfifo(fifo, 0o600)
        with patch.object(tuya, 'session_candidates', return_value=[fifo]):
            self.assertIsNone(tuya.load_available_session(self.store))
        self.assertFalse(self.credential_backing.values)
        self.assertTrue(self.source.exists())

    def test_reauthorization_preserves_meter(self):
        self.store.data = dict(session(), meter_id='meter1')
        def authorize(store):
            self.assertEqual(store.data['meter_id'], 'meter1')
            store.data = session()
            store.save()
        with patch.object(tuya.sys.stdin, 'isatty', return_value=True):
            with patch.object(tuya, 'password_login', side_effect=authorize) as login:
                tuya.ensure_login(self.store, force=True)
        self.assertEqual(self.store.load()['meter_id'], 'meter1')
        login.assert_called_once()


class TransportTests(unittest.TestCase):
    def test_error_messages_never_include_secret_url(self):
        for error in (URLError('SECRET'), HTTPError('https://example/?SECRET', 401, 'SECRET', {}, None),
                      HTTPError('https://example/?SECRET', 503, 'SECRET', {}, None)):
            with patch.object(tuya.OPENER, 'open', side_effect=error):
                with self.assertRaises(tuya.TuyaError) as caught:
                    tuya.request_json('https://apigw.iotbing.com')
                self.assertNotIn('SECRET', str(caught.exception))

    def test_server_error_message_not_printed(self):
        with self.assertRaises(tuya.TuyaError) as caught:
            tuya.checked_response({'success': False, 'code': '500', 'msg': 'SECRET'})
        self.assertNotIn('SECRET', str(caught.exception))

    def test_redirects_disabled(self):
        self.assertIsNone(tuya.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.com'))


class CryptoTests(unittest.TestCase):
    def test_fips197_aes128_vector(self):
        key = bytes.fromhex('000102030405060708090a0b0c0d0e0f')
        plaintext = bytes.fromhex('00112233445566778899aabbccddeeff')
        expected = '69c4e0d86a7b0430d8cdb78070b4c55a'
        self.assertEqual(tuya_wire.AES128(key).encrypt(plaintext).hex(), expected)

    def test_nist_gcm_empty_and_single_block_vectors(self):
        for plaintext, expected in [
            (b'', '58e2fccefa7e3061367f1d57a4e7455a'),
            (bytes(16), '0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf')]:
            sealed = tuya_wire.gcm_encrypt(bytes(16), bytes(12), plaintext)
            self.assertEqual(sealed.hex(), expected)
            self.assertEqual(tuya_wire.gcm_decrypt(bytes(16), bytes(12), sealed), plaintext)

    def test_nist_gcm_multiblock_vector(self):
        key = bytes.fromhex('feffe9928665731c6d6a8f9467308308')
        nonce = bytes.fromhex('cafebabefacedbaddecaf888')
        plain = bytes.fromhex('d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72'
                              '1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255')
        sealed = bytes.fromhex('42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e'
                               '21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985'
                               '4d5c2af327cd64a62cf35abd2ba6fab4')
        self.assertEqual(tuya_wire.gcm_encrypt(key, nonce, plain), sealed)
        self.assertEqual(tuya_wire.gcm_decrypt(key, nonce, sealed), plain)

    def test_tampered_ciphertext_tag_nonce_and_key_rejected(self):
        sealed = tuya_wire.gcm_encrypt(bytes(16), bytes(12), b'test payload with partial block')
        for index in (0, len(sealed) - 1):
            broken = bytearray(sealed)
            broken[index] ^= 1
            with self.assertRaises(ValueError):
                tuya_wire.gcm_decrypt(bytes(16), bytes(12), broken)
        with self.assertRaises(ValueError):
            tuya_wire.gcm_decrypt(bytes(16), b'1' * 12, sealed)
        with self.assertRaises(ValueError):
            tuya_wire.gcm_decrypt(b'1' * 16, bytes(12), sealed)

    def test_qr_versions_and_capacity(self):
        for length, size in [(10, 21), (25, 25), (45, 29), (70, 33), (100, 37), (130, 41)]:
            matrix = tuya_wire.qr_matrix('x' * length)
            self.assertEqual(len(matrix), size)
            self.assertTrue(all(type(cell) is bool for row in matrix for cell in row))
        with self.assertRaises(ValueError):
            tuya_wire.qr_matrix('x' * 135)


if __name__ == '__main__':
    unittest.main()
