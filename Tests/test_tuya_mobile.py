import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.parse import parse_qs
from credential_fixtures import isolate_credentials, clear_credentials

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Scripts'))
import tuya
import tuya_mobile as mobile


def state():
    return {'mode': 'mobile', 'app': 'tuya', 'region': 'EU', 'country_code': '48',
            'email': 'test@example.com', 'password_md5': hashlib.md5(b'fake-password').hexdigest(),
            'device_id': 'test-installation', 'endpoint': mobile.ENDPOINTS['EU'], 'sid': 'saved-session'}


def rsa_fixture():
    # Two known Mersenne primes, only for deterministic RSA protocol tests.
    p, q, exponent = 2 ** 521 - 1, 2 ** 607 - 1, 65537
    modulus = p * q
    private = pow(exponent, -1, (p - 1) * (q - 1))
    raw = modulus.to_bytes((modulus.bit_length() + 7) // 8, 'big')
    return modulus, exponent, private, raw


def der(tag, data):
    size = len(data)
    length = bytes([size]) if size < 128 else b'\x82' + size.to_bytes(2, 'big')
    return bytes([tag]) + length + data


class MobileTests(unittest.TestCase):
    def setUp(self):
        isolate_credentials(self)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = tuya.SessionStore(Path(self.temp.name) / 'session.json')
        self.store.data = state()
        self.store.save()

    def test_legacy_rsa_encrypts_password_digest(self):
        n, e, private, raw = rsa_fixture()
        token = {'publicKey': base64.b64encode(raw).decode(), 'exponent': str(e)}
        ciphertext = mobile.rsa_password(state()['password_md5'], token)
        decrypted = pow(int(ciphertext, 16), private, n).to_bytes(len(raw), 'big')
        self.assertEqual(decrypted.lstrip(b'\0'), state()['password_md5'].encode())

    def test_der_rsa_pkcs1_padding(self):
        n, e, private, raw = rsa_fixture()
        key = der(0x30, der(2, b'\0' + raw) + der(2, e.to_bytes(3, 'big')))
        spki = der(0x30, der(0x30, b'') + der(3, b'\0' + key))
        for encoded in (key, spki):
            ciphertext = mobile.rsa_password(state()['password_md5'], {'pbKey': base64.b64encode(encoded).decode()})
            decrypted = pow(int(ciphertext, 16), private, n).to_bytes(len(raw), 'big')
            self.assertTrue(decrypted.startswith(b'\0\2'))
            padding, message = decrypted[2:].split(b'\0', 1)
            self.assertGreaterEqual(len(padding), 8)
            self.assertEqual(message, state()['password_md5'].encode())

    def test_decimal_modulus_is_not_base64_and_modern_login_uses_padding(self):
        n, e, private, raw = rsa_fixture()
        token = {'publicKey': str(n), 'exponent': str(e)}
        ciphertext = mobile.rsa_password(state()['password_md5'], token, padding_mode='pkcs1')
        decrypted = pow(int(ciphertext, 16), private, n).to_bytes(len(raw), 'big')
        self.assertTrue(decrypted.startswith(b'\0\2'))
        padding, message = decrypted[2:].split(b'\0', 1)
        self.assertGreaterEqual(len(padding), 8)
        self.assertEqual(message, state()['password_md5'].encode())

    def test_mobile_capture_sequence_and_server_side_password_decryption(self):
        n, e, private, raw = rsa_fixture()
        der_key = der(0x30, der(2, b'\0' + raw) + der(2, e.to_bytes(3, 'big')))
        seen = []
        def server(url, **kwargs):
            form = {k: v[0] for k, v in parse_qs(kwargs['data'].decode()).items()}
            data = json.loads(form['postData'])
            seen.append((form['a'], form['v']))
            self.assertNotIn('sid', form)
            if len(seen) == 1:
                self.assertEqual(seen[-1], ('thing.m.user.username.token.get', '2.0'))
                self.assertEqual(data, {'countryCode': '48', 'username': 'test@example.com', 'isUid': False})
                return {'success': True, 'result': {'token': 'fresh-once',
                        'pbKey': base64.b64encode(der_key).decode(), 'publicKey': str(n), 'exponent': str(e)}}
            self.assertEqual(seen[-1], ('thing.m.user.email.password.login', '3.0'))
            self.assertEqual(data['token'], 'fresh-once')
            self.assertEqual(json.loads(data['options']), {'group': 1, 'mfaCode': ''})
            decrypted = pow(int(data['passwd'], 16), private, n).to_bytes(len(raw), 'big')
            self.assertTrue(decrypted.startswith(b'\0\2'))
            self.assertEqual(decrypted[2:].split(b'\0', 1)[1], hashlib.md5(b'fake-password').hexdigest().encode())
            return {'success': True, 'result': {'sid': 'validated-session'}}
        mobile.MobileClient(self.store, server).login()
        self.assertEqual(len(seen), 2)
        self.assertEqual(self.store.load()['sid'], 'validated-session')

    def test_password_rejection_is_not_retried_with_old_endpoints(self):
        _, e, _, raw = rsa_fixture()
        transport = Mock(side_effect=[
            {'success': True, 'result': {'token': 'fresh', 'publicKey': base64.b64encode(raw).decode(), 'exponent': e}},
            {'success': False, 'errorCode': 'USER_PASSWD_WRONG', 'errorMsg': 'SECRET'},
        ])
        before = self.store.load()
        with self.assertRaises(mobile.MobileError) as caught:
            mobile.MobileClient(self.store, transport).login()
        self.assertEqual(transport.call_count, 2)
        self.assertIn('thing.m.user.email.password.login', str(caught.exception))
        self.assertNotIn('SECRET', str(caught.exception))
        self.assertEqual(self.store.load(), before)

    def test_missing_one_time_token_stops_before_password_submission(self):
        transport = Mock(return_value={'success': True, 'result': {}})
        with self.assertRaises(mobile.MobileError):
            mobile.MobileClient(self.store, transport).login()
        transport.assert_called_once()

    def test_signed_request_is_post_and_hides_sid_from_url(self):
        transport = Mock(return_value={'success': True, 'result': []})
        client = mobile.MobileClient(self.store, transport)
        client.request('tuya.m.my.group.device.list', gid='123', version='2.0')
        args, kwargs = transport.call_args
        self.assertNotIn('saved-session', args[0])
        self.assertEqual(kwargs['method'], 'POST')
        form = {k: v[0] for k, v in parse_qs(kwargs['data'].decode()).items()}
        self.assertEqual(form['sid'], 'saved-session')
        self.assertEqual(form['gid'], '123')
        self.assertEqual(form['sign'], mobile.signature(form, mobile.APPS['tuya']))
        self.assertNotIn('password', kwargs['data'].decode())

    def test_login_saves_sid_without_plaintext_password(self):
        _, exponent, _, raw = rsa_fixture()
        replies = [{'success': True, 'result': {'publicKey': base64.b64encode(raw).decode(),
                    'exponent': exponent, 'token': 'one-time-token'}},
                   {'success': True, 'result': {'sid': 'new-sid', 'uid': 'user',
                    'domain': {'mobileApiUrl': 'https://a2.tuyaeu.com'}}}]
        transport = Mock(side_effect=replies)
        mobile.MobileClient(self.store, transport).login()
        saved = self.store.load()
        self.assertEqual(saved['sid'], 'new-sid')
        self.assertEqual(saved['endpoint'], 'https://a2.tuyaeu.com/api.json')
        self.assertFalse(self.store.path.exists())
        self.assertNotIn(b'fake-password', b''.join(self.credential_backing.values.values()))
        for call in transport.call_args_list:
            form = parse_qs(call.kwargs['data'].decode())
            self.assertNotIn('sid', form)
            self.assertNotIn('fake-password', call.kwargs['data'].decode())

    def test_expired_sid_reauthenticates_exactly_once(self):
        client = mobile.MobileClient(self.store, Mock())
        with patch.object(client, 'request', side_effect=[mobile.MobileAuthError(), ['ok']]) as request:
            with patch.object(client, 'login') as login:
                self.assertEqual(client.read('read'), ['ok'])
        login.assert_called_once()
        self.assertEqual(request.call_count, 2)

    def test_rejected_relogin_does_not_loop(self):
        client = mobile.MobileClient(self.store, Mock())
        with patch.object(client, 'request', side_effect=mobile.MobileAuthError()):
            with patch.object(client, 'login', side_effect=mobile.MobileError('rejected')) as login:
                for _ in range(2):
                    with self.assertRaises(mobile.MobileError):
                        client.read('read')
        login.assert_called_once()

    def test_network_error_never_reauthenticates(self):
        client = mobile.MobileClient(self.store, Mock(side_effect=mobile.MobileError('network')))
        with patch.object(client, 'login') as login:
            with self.assertRaises(mobile.MobileError):
                client.read('tuya.m.location.list')
        login.assert_not_called()

    def test_control_and_unknown_actions_blocked_before_network(self):
        transport = Mock()
        client = mobile.MobileClient(self.store, transport)
        for action in ('tuya.m.device.dp.publish', 'tuya.m.device.reset', 'unknown'):
            with self.assertRaises(mobile.MobileError):
                client.request(action, {'dps': {'16': False}})
        transport.assert_not_called()

    def test_meter_phase_decodes_saved_packet_and_single_phase_power(self):
        schema = {'schema': [{'id': 6, 'code': 'phase_a', 'type': 'raw'},
                            {'id': 1, 'code': 'total_forward_energy',
                             'property': {'unit': 'kW·h', 'scale': 2}},
                            {'id': 15, 'code': 'leakage_current',
                             'property': {'unit': 'mA', 'scale': 0}},
                            {'id': 103, 'code': 'temp_current',
                             'property': {'unit': '℃', 'scale': 0}}]}
        row = {'devId': 'meter', 'productId': 'i5mqmxkho1vahdt2',
               'cloudOnline': True, 'dps': {'6': 'CSIADWYAAf4=', '1': 96246, '15': 10, '103': 31}}
        report = tuya.device_report(mobile.normalize_device(row, schema))
        self.assertEqual(report['power_kw'], .510)
        self.assertEqual(report['power_source'], 'power_a')
        self.assertEqual(report['meter_readings'],
                         {'forward_energy_kwh': 962.46, 'leakage_current_ma': 10, 'temperature_c': 31})
        self.assertEqual(report['electrical']['phase_a'],
                         {'voltage_v': 233.8, 'current_a': 3.430, 'power_kw': .510})
        row['cloudOnline'] = False
        report = tuya.device_report(mobile.normalize_device(row, schema))
        self.assertIsNone(report['power_kw'])
        self.assertEqual(report['last_reported_power_kw'], .510)

    def test_raw_phase_does_not_guess_unknown_products_or_missing_phases(self):
        schema = {'schema': [{'id': n, 'code': 'phase_' + phase, 'type': 'raw'}
                             for n, phase in ((6, 'a'), (7, 'b'), (8, 'c'))]}
        row = {'devId': 'meter', 'productId': 'unknown', 'online': True,
               'dps': {'6': 'CSIADWYAAf4='}}
        self.assertEqual(mobile.normalize_device(row, schema)['electrical'], {})
        row['productId'] = 'i5mqmxkho1vahdt2'
        self.assertIsNone(tuya.device_report(mobile.normalize_device(row, schema))['power_kw'])

    def test_raw_phase_invalid_payload_and_full_24_bit_fields(self):
        for raw in (None, True, '', '!!!', 'AAAA', base64.b64encode(bytes(9)).decode()):
            self.assertIsNone(mobile.decode_meter_phase(raw))
        raw = bytes.fromhex('0900011170013880')
        self.assertEqual(mobile.decode_meter_phase(base64.b64encode(raw).decode()),
                         {'voltage_v': 230.4, 'current_a': 70, 'power_kw': 80})

    def test_device_schema_converts_power_without_leaking_local_key(self):
        schema = {'schema': json.dumps([{'id': 19, 'code': 'cur_power',
                                        'property': {'unit': 'W', 'scale': 1}}])}
        row = {'devId': 'meter', 'name': 'Main meter', 'productId': 'product',
               'dps': {'19': 15678}, 'moduleMap': {'wifi': {'isOnline': True}}, 'localKey': 'SECRET'}
        report = tuya.device_report(mobile.normalize_device(row, schema))
        self.assertAlmostEqual(report['power_kw'], 1.5678)
        self.assertNotIn('SECRET', json.dumps(report))

    def test_top_level_online_field_and_unknown_status_keep_existing_reading(self):
        schema = {'schema': [{'id': 19, 'code': 'cur_power', 'property': {'unit': 'W', 'scale': 1}}]}
        row = {'devId': 'monitor', 'name': 'monitor', 'dps': {'19': 310}, 'online': True}
        self.assertEqual(tuya.device_report(mobile.normalize_device(row, schema))['power_kw'], .031)
        row['online'] = 'false'
        offline = tuya.device_report(mobile.normalize_device(row, schema))
        self.assertIsNone(offline['power_kw'])
        self.assertIs(offline['online'], False)
        del row['online']
        unknown = tuya.device_report(mobile.normalize_device(row, schema))
        self.assertIsNone(unknown['power_kw'])
        self.assertIsNone(unknown['online'])
        with patch.object(tuya.sys, 'stdout', new_callable=io.StringIO) as output:
            tuya.render({'devices': [unknown], 'meter': None, 'selection': 'not_found'})
        line = output.getvalue().splitlines()[1]
        self.assertIn('0.031 кВт (последнее облачное показание)', line)
        self.assertNotIn('мощность недоступна', line)

    def test_unknown_meter_datapoints_and_schema_saved_without_credentials(self):
        schema = {'schema': [{'id': 6, 'code': 'phase_a', 'property': {'type': 'raw'}}]}
        row = {'devId': 'meter', 'name': 'main meter', 'dps': {'6': 'AQIDBAUGBwg='},
               'localKey': 'SECRET_LOCAL_KEY', 'ip': 'PRIVATE_ADDRESS'}
        report = tuya.device_report(mobile.normalize_device(row, schema))
        snapshot = tuya.DeviceSnapshot(self.store.path)
        snapshot.data = {'devices': [report]}
        snapshot.save()
        data = snapshot.load()['devices'][0]
        self.assertEqual(data['diagnostics']['dps'], row['dps'])
        self.assertEqual(data['diagnostics']['schema'][0]['code'], 'phase_a')
        self.assertIsNone(data['power_kw'])
        self.assertNotIn('SECRET_LOCAL_KEY', snapshot.path.read_text())
        self.assertNotIn('PRIVATE_ADDRESS', snapshot.path.read_text())
        self.assertEqual(snapshot.path.stat().st_mode & 0o777, 0o600)

    def test_default_client_dispatches_saved_mobile_session(self):
        with tuya.Client(self.store.path) as client:
            self.assertIsInstance(client.mobile, mobile.MobileClient)
            with patch.object(client.mobile, 'devices', return_value=[]) as devices:
                self.assertEqual(client.devices(), [])
            devices.assert_called_once()

    def test_email_login_prompts_password_hidden_and_never_qr(self):
        clear_credentials(self)
        self.store.data = None
        def success(client):
            self.assertEqual(client.store.data['email'], 'test@example.com')
            self.assertEqual(client.store.data['password_md5'], hashlib.md5(b'fake-password').hexdigest())
            self.assertEqual(client.store.data['app'], 'smartlife')
            self.assertEqual(client.store.data['country_code'], '63')
            self.assertEqual(client.store.data['endpoint'], mobile.ENDPOINTS['EU'])
            client.store.data['sid'] = 'new-sid'
            client.store.save()
        with patch('builtins.input', side_effect=['test@example.com', '', '']):
            with patch.object(tuya.getpass, 'getpass', return_value='fake-password') as hidden:
                with patch.object(mobile.MobileClient, 'login', autospec=True, side_effect=success):
                    with patch.object(tuya, 'print_qr') as qr:
                        tuya.password_login(self.store)
        hidden.assert_called_once()
        qr.assert_not_called()
        self.assertEqual(self.store.load()['sid'], 'new-sid')

    def test_failed_login_remembers_all_inputs_and_enter_reuses_them(self):
        clear_credentials(self)
        self.store.data = None
        with patch('builtins.input', side_effect=['remember@example.com', '63', 'EU']):
            with patch.object(tuya.getpass, 'getpass', return_value='remember-password'):
                with patch.object(mobile.MobileClient, 'login', side_effect=mobile.MobileError('network')):
                    with self.assertRaises(mobile.MobileError):
                        tuya.password_login(self.store)
        self.assertFalse(self.store.path.exists())
        settings = tuya.LoginSettings(self.store.path)
        data = settings.load()
        self.assertEqual(data['email'], 'remember@example.com')
        self.assertEqual(data['region'], 'EU')
        self.assertEqual(data['country_code'], '63')
        self.assertEqual(data['app'], 'smartlife')
        self.assertNotIn(b'remember-password', b''.join(self.credential_backing.values.values()))
        self.assertFalse(settings.path.exists())
        captured = []
        def rejected(client):
            captured.append(dict(client.store.data))
            raise mobile.MobileError('rejected again')
        restarted = tuya.SessionStore(self.store.path)
        with patch('builtins.input', side_effect=['', '', '']) as inputs:
            with patch.object(tuya.getpass, 'getpass', return_value=''):
                with patch.object(mobile.MobileClient, 'login', autospec=True, side_effect=rejected):
                    with self.assertRaises(mobile.MobileError):
                        tuya.password_login(restarted)
        self.assertEqual(captured[0]['email'], 'remember@example.com')
        self.assertEqual(captured[0]['password_md5'], data['password_md5'])
        self.assertEqual(captured[0]['device_id'], data['device_id'])
        self.assertIn('remember@example.com', inputs.call_args_list[0].args[0])
        self.assertEqual(inputs.call_count, 3)  # No application-choice prompt.

    def test_email_saved_even_if_next_prompt_is_interrupted(self):
        with patch('builtins.input', side_effect=['interrupted@example.com', KeyboardInterrupt]):
            with self.assertRaises(KeyboardInterrupt):
                tuya.password_login(self.store)
        self.assertEqual(tuya.LoginSettings(self.store.path).load()['email'], 'interrupted@example.com')

    def test_failed_credential_edit_preserves_successful_session(self):
        before = self.store.load()
        with patch('builtins.input', side_effect=['edited@example.com', '63', 'EU']):
            with patch.object(tuya.getpass, 'getpass', return_value='edited-password'):
                with patch.object(mobile.MobileClient, 'login', side_effect=mobile.MobileError('rejected')):
                    with self.assertRaises(mobile.MobileError):
                        tuya.password_login(self.store)
        self.assertEqual(self.store.load(), before)
        self.assertEqual(tuya.LoginSettings(self.store.path).load()['email'], 'edited@example.com')

    def test_server_cannot_redirect_credentials_outside_tuya(self):
        for url in ('http://a1.tuyaeu.com', 'https://tuyaeu.com.evil.example/api.json',
                    'https://user@a1.tuyaeu.com/api.json'):
            with self.assertRaises(mobile.MobileError):
                mobile.checked_endpoint(url)


if __name__ == '__main__':
    unittest.main()
