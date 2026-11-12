import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from Scripts import export_energy_year as export


class ExportTests(unittest.TestCase):
    def test_cache_resume_and_refresh(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = export.Archive(Path(directory), 0)
            call = Mock(return_value={'20260101': '#', '20260102': 0})
            request = {'provider': 'tuya', 'data': {'dpId': 1}}
            first = archive.fetch(request, call)
            self.assertEqual(archive.fetch(request, call), first)
            self.assertEqual(call.call_count, 1)
            archive.fetch(request, call, refresh=True)
            self.assertEqual(call.call_count, 2)
            self.assertEqual(first['response']['20260101'], '#')

    def test_errors_are_retried_on_resume(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = export.Archive(Path(directory), 0)
            call = Mock(side_effect=[export.tuya.TuyaError('Rejected'), {'value': 1}])
            self.assertEqual(archive.fetch({'a': 1}, call)['status'], 'error')
            self.assertEqual(archive.fetch({'a': 1}, call)['status'], 'ok')

    def test_file_is_private_and_secrets_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'result.json'
            export.save(path, {'token': 'secret', 'rows': [{'localKey': 'secret', 'value': 3}],
                               'password_sha256': 'secret'})
            self.assertEqual(json.loads(path.read_text()), {'rows': [{'value': 3}]})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_one_day_two_meters_and_deye(self):
        schema = [{'id': 1, 'code': 'total_forward_energy', 'property': {'scale': 2, 'unit': 'kWh'}}]
        devices = [{'id': id, 'name': name, 'timezone': 'Asia/Manila',
                    'diagnostics': {'schema': schema}} for id, name in
                   [('new', 'main switch new'), ('old', 'main switch old')]]
        client = Mock()
        client.call.return_value = {'statistics': {'generationValue': 12.5},
                                    'records': [{'generationPower': 42, 'dateTime': 1767225600000}]}
        store = Mock(data={'mode': 'mobile', 'meter_id': 'new', 'endpoint': 'https://a1.tuyaeu.com/api.json'})
        store.load.return_value = store.data
        mobile = Mock(store=store)
        def read(action, data, version):
            if action == export.history.DAYS:
                return {'20260101': 14.25}
            if action == export.history.HOURS:
                return {'2026010100': 1.25, '2026010101': '#', '2026010102': 0}
            if action == export.history.QUARTERS:
                return {'202601010000': 0.5, '202601010015': '#'}
            return {'dps': [{'dpId': 1, 'value': 1425}], 'hasNext': False}
        mobile.read.side_effect = read
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(export.deye, 'load_session', return_value=client), \
                patch.object(export.deye, 'station_list', return_value=[{'id': 12, 'name': 'Solar'}]), \
                patch.object(export.tuya, 'SessionStore', return_value=store), \
                patch.object(export.history, 'HistoryClient', return_value=mobile), \
                patch.object(export, 'tuya_devices', return_value=devices):
            client.base = 'https://eu1.deyecloud.com'
            output = Path(directory) / 'archive.json'
            code = export.main(['--year', '2026', '--through', '2026-01-01', '--delay', '0', '--output', str(output)])
            report = json.loads(output.read_text())
            self.assertEqual(code, 0)
            self.assertEqual(len(report['calendar']), 365)
            self.assertEqual(report['coverage']['deye'][0]['intraday_records'], 1)
            self.assertEqual(len(report['tuya']['meters']), 2)
            self.assertEqual(mobile.read.call_count, 8)
            for meter in report['tuya']['meters']:
                series = meter['days']['2026-01-01']['series']['1']
                self.assertEqual(series['day']['value_returned'], 14.25)
                self.assertEqual(series['hour']['coverage']['numeric_points'], 2)
                self.assertTrue(meter['logs']['pagination_complete'])


if __name__ == '__main__':
    unittest.main()
