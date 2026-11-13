import contextlib
import io
import json
import unittest
from urllib.error import URLError
from unittest.mock import patch

from datetime import date
from Scripts.tuya_history import HistoryClient, NetworkError, VerboseTransport, numeric_points, summarize
from Scripts.tuya_mobile import MobileError


class HistoryTests(unittest.TestCase):
    def test_logs_redact_aliases_and_json_encoded_credentials(self):
        aliases = ('accessToken', 'refresh-token', 'session_token', 'secretKey',
                   'SecretAccessKey', 'passwordSha256', 'x_unused')
        payload = {key: f'synthetic-{key}' for key in aliases}
        output = io.StringIO()
        transport = VerboseTransport({})
        with contextlib.redirect_stdout(output):
            transport.log('RESPONSE', {'payload': json.dumps(payload), 'watts': 42})
            transport.log('ERROR', 'echo synthetic-accessToken')
        text = output.getvalue()
        for key in aliases[:-1]:
            self.assertNotIn(f'synthetic-{key}', text)
        self.assertIn('synthetic-x_unused', text)
        self.assertIn('42', text)

    def test_quarters_validate_grid_and_do_not_confuse_hours_or_other_dates(self):
        result = {'202611110000': '0.12', '202611110015': '0.23',
                  '202611110030': '#', '202611110045': None,
                  '202611110011': '500', '2026111100': '900', '202611120000': '800'}
        summary = summarize(result, '15min', date(2026, 11, 11))
        self.assertEqual(summary['numeric_points'], 2)
        self.assertEqual(summary['sum_returned_values'], '0.35')
        self.assertFalse(summary['complete_grid'])
        self.assertEqual(summary['expected_points'], 96)

    def test_logs_keep_observations_but_remove_echoed_credentials(self):
        transport = VerboseTransport({'sid': 'private-session-value'})
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            transport.log('RESPONSE', {'errorMsg': 'sid=private-session-value',
                                      'result': {'2026111100': '123', '2026111101': '#'},
                                      'sid': 'rotated-session-value'})
            transport.log('ERROR', 'echo rotated-session-value')
        logged = output.getvalue()
        self.assertNotIn('private-session-value', logged)
        self.assertNotIn('rotated-session-value', logged)
        self.assertIn('123', logged)
        self.assertIn('#', logged)
        self.assertIn('errorMsg', logged)

    def test_empty_or_missing_data_is_not_success(self):
        self.assertEqual(numeric_points({'2026111100': '#', '2026111101': None,
                                         '2026111102': 'NaN', '2026111103': True}), 0)
        self.assertEqual(numeric_points({'2026111100': '0', '2026111101': '12.5'}), 2)
        self.assertEqual(numeric_points({}), 0)

    def test_device_commands_remain_blocked_before_transport(self):
        client = HistoryClient(None, lambda *a, **kw: self.fail('Unexpected request'))
        with self.assertRaises(MobileError):
            client.request('tuya.m.device.dp.publish', data={'switch': False})

    def test_network_error_preserves_underlying_reason(self):
        output = io.StringIO()
        with patch('Scripts.tuya_history.OPENER.open', side_effect=URLError('DNS unavailable')):
            with contextlib.redirect_stdout(output), self.assertRaises(NetworkError):
                VerboseTransport({})('https://a1.tuyaeu.com/api.json', data=b'a=history')
        self.assertIn('DNS unavailable', output.getvalue())


if __name__ == '__main__':
    unittest.main()
