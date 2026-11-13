#!/usr/bin/env python3
"""Read-only, resumable Deye + current/old Tuya meter archive. Stdlib only."""
import argparse
from datetime import date, datetime, timedelta, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time
from zoneinfo import ZoneInfo

if __package__:
    from . import deye, tuya, tuya_history as history
    from .tuya_mobile import normalize_device
else:
    import deye
    import tuya
    import tuya_history as history
    from tuya_mobile import normalize_device

ROOT = Path(__file__).resolve().parent.parent
SECRET_KEYS = history.SECRET_KEYS | {
    'email', 'username', 'phone', 'mobile', 'ip', 'ipaddress',
}


def utcnow():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def clean(value):
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items() if history.normalized_field(k) not in SECRET_KEYS}
    if isinstance(value, list):
        return [clean(v) for v in value]
    decoded = history.embedded_json(value)
    if decoded is not None:
        return json.dumps(clean(decoded), ensure_ascii=False, separators=(',', ':'))
    return value


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.energy-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(clean(value), stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write('\n')
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def number(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (ValueError, TypeError):
        return None


class Archive:
    def __init__(self, path, delay):
        self.path, self.delay = path, delay
        self.last = 0

    def fetch(self, request, call, refresh=False):
        key = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
        path = self.path / (key + '.json')
        if path.exists() and not refresh:
            saved = json.loads(path.read_text())
            if saved.get('status') == 'ok' and saved.get('request') == request:
                return saved
        record = {'request': request, 'fetched_at': utcnow()}
        for attempt in range(3):
            time.sleep(max(0, self.last + self.delay - time.monotonic()))
            try:
                record.update(status='ok', response=clean(call()))
                break
            except (deye.DeyeError, tuya.TuyaError) as error:
                record.update(status='error', error=str(error))
                # Authentication has its own single recovery attempt in the clients.
                transient = any(x in str(error) for x in ('соединения', 'HTTP 429', 'HTTP 50'))
                if not transient or attempt == 2:
                    break
                time.sleep(2 ** attempt)
            finally:
                self.last = time.monotonic()
        save(path, record)
        return record


def dates_between(start, end):
    return [start + timedelta(days=n) for n in range((end - start).days + 1)]


def run_deye(args, archive, days, today, report):
    client = deye.load_session()
    if client is None:
        raise deye.DeyeError('Нет сохранённой сессии Deye. Запусти Scripts/deye.py.')
    # Live preflight: fail once if networking/authentication is unavailable.
    stations = deye.station_list(client)
    report['deye']['status'] = 'running'
    for station in stations:
        station_id = int(station.get('id', station.get('stationId')))
        target = {'id': station_id, 'name': station.get('name'),
                  'timezone': args.timezone, 'timezone_source': 'CLI / existing app configuration',
                  'days': {}}
        report['deye']['stations'].append(target)
        failed = 0
        for i, day in enumerate(days):
            path = f'/maintain-s/history/batteryPower/{station_id}/stats/daily'
            query = {'year': day.year, 'month': day.month, 'day': day.day}
            request = {'provider': 'deye', 'base': client.base, 'path': path, 'query': query}
            result = archive.fetch(request, lambda: client.call(path, query=query), day == today)
            body = deye.unwrap(result.get('response', {}))
            body = body if isinstance(body, dict) else {}
            rows = body.get('records') or []
            stats = body.get('statistics') or {}
            target['days'][day.isoformat()] = {
                'partial_day': day == today, 'api': result,
                'record_count': len(rows),
                'generation_kwh': number(stats.get('generationValue')) if isinstance(stats, dict) else None,
                'available_fields': sorted({k for row in rows if isinstance(row, dict) for k in row}),
            }
            failed = failed + 1 if result['status'] == 'error' else 0
            if i % 10 == 0 or i == len(days) - 1:
                print(f'Deye {station_id}: {day} ({i + 1}/{len(days)}), records={len(rows)}', flush=True)
            if failed >= 3:
                raise deye.DeyeError('Три последовательные ошибки Deye; успешные ответы сохранены, повтори запуск.')
    report['deye']['status'] = 'finished'


def tuya_devices(client):
    devices = []
    for home in client.read('tuya.m.location.list', version='2.1'):
        gid = home.get('groupId', home.get('id'))
        rows = client.read('tuya.m.my.group.device.list', version='2.0', gid=gid)
        refs = client.read('tuya.m.device.ref.info.my.list', version='2.0', gid=gid)
        schemas = {str(r['id']): r.get('schemaInfo', {}) for r in refs}
        for row in rows:
            # Normalization keeps device keys and credentials out.
            device = normalize_device(row, schemas.get(str(row.get('productId')), {}))
            device['timezone'] = row.get('timezoneId', row.get('timeZoneId'))
            device['activation_time'] = row.get('activeTime')
            devices.append(device)
    return devices


def run_logs(args, archive, client, device, target):
    dp_ids = ','.join(str(s['id']) for s in device['diagnostics']['schema'])
    target['logs'] = {'scope': 'All available reported DPs; API retained history, may include other years',
                      'pages': [], 'pagination_complete': False}
    seen = set()
    for page in range(args.max_log_pages):
        data = {'devId': device['id'], 'dpIds': dp_ids, 'offset': page * 100,
                'limit': 100, 'sortType': 'DESC'}
        req = {'provider': 'tuya', 'endpoint': client.store.data['endpoint'],
               'action': history.LOGS, 'version': '2.0', 'data': data}
        # Offset-based live logs shift: never resume stale pages against a new first page.
        result = archive.fetch(req, lambda: client.read(history.LOGS, data=data, version='2.0'), True)
        target['logs']['pages'].append(result)
        if result['status'] != 'ok':
            target['logs']['stop_reason'] = 'API error'
            return
        body = result.get('response')
        if not isinstance(body, dict) or not isinstance(body.get('dps'), list):
            target['logs']['stop_reason'] = 'Unrecognized response; retained verbatim'
            return
        rows = body['dps']
        digest = hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()
        if digest in seen:
            target['logs']['stop_reason'] = 'Repeated page; pagination not reliable'
            return
        seen.add(digest)
        if body.get('hasNext') is False:
            target['logs'].update(pagination_complete=True, stop_reason='API hasNext=false')
            return
        if not rows or body.get('hasNext') is not True:
            target['logs']['stop_reason'] = 'No explicit pagination continuation'
            return
        if page % 10 == 0:
            print(f'Tuya {device["name"]}: logs page {page + 1}', flush=True)
    target['logs']['stop_reason'] = f'Page limit {args.max_log_pages}; increase --max-log-pages'


def run_tuya(args, archive, days, today, report):
    store = tuya.SessionStore(args.tuya_session)
    if not store.load() or store.data.get('mode') != 'mobile':
        raise tuya.TuyaError('Нет мобильной сессии Tuya. Запусти Scripts/tuya.command.')
    client = history.HistoryClient(store, tuya.request_json)
    devices = tuya_devices(client)
    ids = set(args.meter or [])
    if not ids:
        ids = {d['id'] for d in devices if 'main switch' in d['name'].lower()}
        if store.data.get('meter_id'):
            ids.add(store.data['meter_id'])
    missing = ids - {d['id'] for d in devices}
    if missing or not ids:
        raise tuya.TuyaError('Не найдены нужные счётчики; укажи --meter ID для каждого счётчика.')
    report['tuya']['status'] = 'running'
    for device in devices:
        if device['id'] not in ids:
            continue
        energy = [s for s in device['diagnostics']['schema']
                  if s.get('code') in ('total_forward_energy', 'total_reverse_energy', 'add_ele')]
        if not energy:
            raise tuya.TuyaError(f'Не распознан energy DP у {device["id"]}.')
        target = {'device': device, 'selected_meter': device['id'] == store.data.get('meter_id'),
                  'energy_dps': energy, 'days': {}}
        report['tuya']['meters'].append(target)
        print(f'Tuya: {device["name"]} ({device["id"]})', flush=True)
        failed = 0
        for i, day in enumerate(days):
            day_result = {'partial_day': day == today, 'series': {}}
            target['days'][day.isoformat()] = day_result
            for dp in energy:
                kind = 'sum' if dp['code'] == 'add_ele' else 'minux'
                series = {}
                day_result['series'][str(dp['id'])] = series
                for interval, action in [('day', history.DAYS), ('hour', history.HOURS), ('15min', history.QUARTERS)]:
                    data = {'devId': device['id'], 'dpId': dp['id'], 'auto': 2, 'type': kind}
                    key = day.strftime('%Y%m%d')
                    data.update({'startDay': key, 'endDay': key} if interval == 'day' else {'date': key})
                    version = '2.0' if interval == 'day' else '1.0'
                    req = {'provider': 'tuya', 'endpoint': store.data['endpoint'],
                           'action': action, 'version': version, 'data': data}
                    result = archive.fetch(req, lambda: client.read(action, data=data, version=version), day == today)
                    series[interval] = {'api': result}
                    if result['status'] == 'ok':
                        raw = result['response']
                        if interval == 'day':
                            series[interval]['value_returned'] = number(raw.get(key)) if isinstance(raw, dict) else None
                        else:
                            series[interval]['coverage'] = history.summarize(raw, interval, day)
                    failed = failed + 1 if result['status'] == 'error' else 0
                    if failed >= 6:
                        raise tuya.TuyaError('Шесть последовательных ошибок Tuya; ответы сохранены, повтори запуск.')
            if i % 10 == 0 or i == len(days) - 1:
                print(f'Tuya {device["name"]}: {day} ({i + 1}/{len(days)})', flush=True)
        if not args.skip_logs:
            run_logs(args, archive, client, device, target)
        else:
            target['logs'] = {'pagination_complete': False, 'stop_reason': '--skip-logs'}
    report['tuya']['status'] = 'finished'


def coverage(report):
    result = {'api_errors': 0, 'deye': [], 'tuya': []}
    def errors(value):
        if isinstance(value, dict):
            if 'request' in value and value.get('status') == 'error':
                result['api_errors'] += 1
            for item in value.values():
                errors(item)
        elif isinstance(value, list):
            for item in value:
                errors(item)
    errors(report['deye'])
    errors(report['tuya'])
    for station in report['deye']['stations']:
        days = station['days']
        result['deye'].append({'id': station['id'], 'days_attempted': len(days),
            'days_with_generation': sum(d['generation_kwh'] is not None for d in days.values()),
            'intraday_records': sum(d['record_count'] for d in days.values())})
    for meter in report['tuya']['meters']:
        counts = {'id': meter['device']['id'], 'name': meter['device']['name'],
                  'days_attempted': len(meter['days']), 'daily_values': 0,
                  'hourly_points': 0, 'quarter_hour_points': 0,
                  'log_pagination_complete': meter.get('logs', {}).get('pagination_complete', False)}
        for day in meter['days'].values():
            for dp in day['series'].values():
                counts['daily_values'] += dp.get('day', {}).get('value_returned') is not None
                for interval, field in [('hour', 'hourly_points'), ('15min', 'quarter_hour_points')]:
                    counts[field] += dp.get(interval, {}).get('coverage', {}).get('numeric_points', 0)
        result['tuya'].append(counts)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--year', type=int, default=datetime.now(ZoneInfo('Europe/Warsaw')).year)
    parser.add_argument('--through', type=date.fromisoformat, help='Last date to request, YYYY-MM-DD')
    parser.add_argument('--timezone', default='Asia/Manila')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--tuya-session', type=Path, default=tuya.SESSION)
    parser.add_argument('--deye-session', type=Path, default=deye.SESSION)
    parser.add_argument('--meter', action='append', help='Repeat for current and old meters; default finds both')
    parser.add_argument('--delay', type=float, default=0.25)
    parser.add_argument('--max-log-pages', type=int, default=1000)
    parser.add_argument('--skip-logs', action='store_true')
    args = parser.parse_args(argv)
    today = datetime.now(ZoneInfo(args.timezone)).date()
    if not 1970 <= args.year <= today.year or args.delay < 0 or args.max_log_pages < 1:
        parser.error('Invalid year, delay or max-log-pages')
    first, last = date(args.year, 1, 1), date(args.year, 12, 31)
    through = min(args.through or today, today, last)
    if through < first:
        parser.error('--through precedes requested year')
    output = args.output or ROOT / 'generated' / f'energy-{args.year}.json'
    archive = Archive(output.parent / (output.stem + '-responses'), args.delay)
    deye.SESSION = args.deye_session
    days = dates_between(first, through)
    report = {
        'format_version': 1, 'started_at': utcnow(), 'year': args.year,
        'requested_from': first.isoformat(), 'requested_through': through.isoformat(),
        'calendar_timezone': args.timezone,
        'notes': [
            'No interpolation or zero filling. Null, #, empty replies and API errors are distinct.',
            'Deye responses retain every returned statistics field and intraday record.',
            'Tuya statistics retain original values; DP scale describes live raw DP values, not an instruction to rescale statistics.',
            'Tuya intervals use the device calendar; inspect device.timezone before comparing providers.',
            'Current day is partial. Future days are not requested.',
            'A successful empty response does not prove a retention limit or zero consumption.',
            'Logs use live offset pagination; duplicates or gaps are possible if new readings arrive during export.',
            'Current and old meters are separate; do not sum overlapping days without checking the installation history.',
        ],
        'calendar': {d.isoformat(): ('future' if d > today else 'outside_requested_range' if d > through else 'partial' if d == today else 'requested')
                     for d in dates_between(first, last)},
        'deye': {'status': 'pending', 'stations': []},
        'tuya': {'status': 'pending', 'meters': []},
    }
    save(output, report)
    for provider, run in [('deye', run_deye), ('tuya', run_tuya)]:
        try:
            run(args, archive, days, today, report)
        except (deye.DeyeError, tuya.TuyaError, OSError, ValueError) as error:
            report[provider].update(status='incomplete', error=str(error))
            print(f'{provider}: {error}', file=sys.stderr, flush=True)
        except KeyboardInterrupt:
            report[provider]['status'] = 'interrupted'
            save(output, report)
            print(f'Interrupted. Partial JSON: {output}; rerun the same command to resume.', flush=True)
            return 130
        finally:
            report['updated_at'] = utcnow()
            report['coverage'] = coverage(report)
            save(output, report)
    report['finished_at'] = utcnow()
    # Finished means all planned calls were attempted, not that cloud history is complete.
    save(output, report)
    print(f'JSON: {output.resolve()}\nRaw response cache: {archive.path.resolve()}', flush=True)
    errors = [p for p in ('deye', 'tuya') if report[p]['status'] != 'finished']
    print(json.dumps(report['coverage'], ensure_ascii=False, indent=2), flush=True)
    incomplete_logs = any(not m['log_pagination_complete'] for m in report['coverage']['tuya'])
    return 2 if errors or report['coverage']['api_errors'] or incomplete_logs else 0


if __name__ == '__main__':
    sys.exit(main())
