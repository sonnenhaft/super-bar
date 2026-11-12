#!/usr/bin/env python3
"""Verbose, read-only probe of the selected Smart Life meter's cloud history.

Tuya statistics API reference:
https://developer.tuya.com/en/docs/iot/data-statistics-related-interface?id=K9m1dlf41ex5f
The cumulative energy DP uses `minux` (Tuya's spelling), not a sum of readings.
"""
import argparse
from datetime import datetime, timedelta
from decimal import Decimal, InvalidOperation
import json
from pathlib import Path
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, quote, quote_plus
from urllib.request import Request
from zoneinfo import ZoneInfo

if __package__:
    from .tuya import OPENER, SESSION, SessionStore
    from .tuya_mobile import MobileClient, MobileError
else:
    from tuya import OPENER, SESSION, SessionStore
    from tuya_mobile import MobileClient, MobileError


HOURS = 'tuya.m.dp.rang.stat.hour.list'
DAYS = 'tuya.m.dp.rang.stat.day.list'
# Official Tuya panel demo: examples/airThermostat/src/components/Chart/index.tsx
QUARTERS = 'tuya.m.dp.path.15minute.list'
LOGS = 'm.smart.operate.log'
SECRET_KEYS = {'sid', 'sign', 'password', 'passwd', 'password_md5', 'token',
               'access_token', 'refresh_token', 'localkey', 'devkey', 'secret',
               'authorization'}


class NetworkError(MobileError):
    pass


class HistoryClient(MobileClient):
    ALLOWED_ACTIONS = MobileClient.ALLOWED_ACTIONS | {HOURS, DAYS, QUARTERS, LOGS}


class VerboseTransport:
    def __init__(self, state, timeout=20):
        self.secrets = set()
        self.timeout = timeout
        self.remember(state)

    def remember(self, value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key.lower() in SECRET_KEYS and isinstance(item, str) and item:
                    self.secrets.update((item, quote(item, safe=''), quote_plus(item)))
                self.remember(item)
        elif isinstance(value, list):
            for item in value:
                self.remember(item)

    def clean(self, value):
        if isinstance(value, dict):
            return {key: '[REDACTED]' if key.lower() in SECRET_KEYS else self.clean(item)
                    for key, item in value.items()}
        if isinstance(value, list):
            return [self.clean(item) for item in value]
        if isinstance(value, str):
            for secret in sorted(self.secrets, key=len, reverse=True):
                value = value.replace(secret, '[REDACTED]')
        return value

    def log(self, label, value):
        self.remember(value)
        rendered = json.dumps(self.clean(value), ensure_ascii=False, indent=2)
        # Also redact credentials echoed inside server messages or JSON strings.
        print(f'\n[{datetime.now().astimezone().isoformat(timespec="seconds")}] {label}\n'
              f'{self.clean(rendered)}', flush=True)

    def __call__(self, url, method='POST', headers=None, data=None):
        fields = dict(parse_qsl(data.decode()))
        if 'postData' in fields:
            fields['postData'] = json.loads(fields['postData'])
        self.log('REQUEST', {'method': method, 'url': url, 'fields': fields})
        request = Request(url, data=data, method=method,
                          headers={'Accept': 'application/json', **(headers or {})})
        try:
            try:
                response = OPENER.open(request, timeout=self.timeout)
            except HTTPError as error:
                response = error
            with response:
                status = response.code
                raw = response.read(8 * 1024 * 1024 + 1)
        except (URLError, OSError, TimeoutError) as error:
            reason = getattr(error, 'reason', error)
            self.log('NETWORK ERROR', {'type': type(reason).__name__, 'message': str(reason)})
            raise NetworkError('Запрос не дошёл до Tuya или ответ не получен; см. ошибку выше.') from None
        if len(raw) > 8 * 1024 * 1024:
            raise MobileError('Ответ больше 8 MiB; чтение остановлено.')
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeError):
            self.log('NON-JSON RESPONSE', {'http': status, 'body': raw.decode(errors='replace')})
            raise MobileError('Tuya вернула не JSON.') from None
        self.log('RESPONSE', {'http': status, 'body': result})
        if not isinstance(result, dict):
            raise MobileError('Ожидался объект JSON.')
        if not 200 <= status < 300:
            raise MobileError(f'Tuya вернула HTTP {status}; тело ответа выше.')
        return result


def parse_date(value):
    try:
        return datetime.strptime(value, '%Y-%m-%d').date()
    except ValueError:
        raise argparse.ArgumentTypeError('Дата должна быть YYYY-MM-DD.') from None


def observations(result, interval='hour', day=None):
    """Accept only valid timestamps on the requested grid; never fill gaps."""
    if not isinstance(result, dict):
        return {}
    points = {}
    length, fmt = (10, '%Y%m%d%H') if interval == 'hour' else (12, '%Y%m%d%H%M')
    for key, value in result.items():
        key = str(key)
        if len(key) != length or not key.isdigit() or isinstance(value, bool):
            continue
        try:
            timestamp = datetime.strptime(key, fmt)
            if day and timestamp.date() != day:
                continue
            if interval != 'hour' and timestamp.minute % 15:
                continue
            number = Decimal(str(value))
            if number.is_finite():
                points[key] = number
        except (TypeError, ValueError, InvalidOperation):
            pass
    return points


def numeric_points(result):
    return len(observations(result))


def summarize(result, interval, day):
    points = observations(result, interval, day)
    expected = 24 if interval == 'hour' else 96
    return {'date': day.isoformat(), 'interval': interval, 'numeric_points': len(points),
            'expected_points': expected, 'complete_grid': len(points) == expected,
            'sum_returned_values': str(sum(points.values())) if points else None}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dates', nargs='*', type=parse_date,
                        help='Даты YYYY-MM-DD; по умолчанию вчера и 7 дней назад.')
    parser.add_argument('--session', type=Path, default=SESSION)
    parser.add_argument('--meter', help='ID другого счётчика; сохранённый выбор не изменяется.')
    parser.add_argument('--dp', type=int, default=1, help='Energy DP ID (по умолчанию 1).')
    parser.add_argument('--type', choices=['minux', 'sum', 'avg', 'max'], default='minux',
                        help='Статистика; для накопленной энергии нужен minux.')
    parser.add_argument('--interval', choices=['hour', '15min', 'both'], default='hour')
    parser.add_argument('--deep', action='store_true',
                        help='15 минут + часы за 1, 7, 14, 30, 90 дней назад и последние записи журнала.')
    parser.add_argument('--logs', action='store_true', help='Последние 100 записей energy DP с временем.')
    args = parser.parse_args(argv)
    today = datetime.now(ZoneInfo('Europe/Warsaw')).date()
    ages = (1, 7, 14, 30, 90) if args.deep else (1, 7)
    dates = sorted(set(args.dates or [today - timedelta(days=n) for n in ages]), reverse=True)
    intervals = ['15min', 'hour'] if args.deep or args.interval == 'both' else [args.interval]
    if any(day > today for day in dates):
        parser.error('Укажите сегодняшнюю или прошедшую дату.')
    store = SessionStore(args.session)
    if not store.load() or store.data.get('mode') != 'mobile':
        raise MobileError('Нужна мобильная сессия Smart Life. Сначала запустите Scripts/tuya.command.')
    meter = args.meter or store.data.get('meter_id')
    if not meter:
        raise MobileError('Счётчик не выбран: укажите --meter ID.')
    transport = VerboseTransport(store.data)
    client = HistoryClient(store, transport)
    snapshot = args.session.with_name('.env.tuya-devices.json')
    device = {}
    try:
        device = next((row for row in json.loads(snapshot.read_text()).get('devices', [])
                       if row.get('id') == meter), {})
    except (OSError, ValueError):
        pass
    transport.log('METER', {'name': device.get('name'), 'id': meter, 'dp': args.dp,
                           'type': args.type, 'dates': [day.isoformat() for day in dates],
                           'schema': [item for item in device.get('diagnostics', {}).get('schema', [])
                                      if item.get('id') == args.dp]})
    print('Даты запрашиваются как календарные дни Tuya. Часовой пояс устройства нужно сверить\n'
          'перед сравнением с Deye. auto=2 сохраняет пропуски как #. Значения ниже — сырые;\n'
          'HTTP success без числовых точек не подтверждает наличие истории.', flush=True)
    summaries = []
    series = {}
    for day in dates:
        for interval in intervals:
            try:
                action = HOURS if interval == 'hour' else QUARTERS
                result = client.read(action, data={'devId': meter, 'dpId': args.dp,
                                            'date': day.strftime('%Y%m%d'), 'auto': 2, 'type': args.type})
                series[(day, interval)] = observations(result, interval, day)
                summary = summarize(result, interval, day)
                summaries.append(summary)
                transport.log('INTERVAL SUMMARY', summary)
            except NetworkError:
                raise
            except MobileError as error:
                transport.log('API ERROR', str(error))
                summaries.append({'date': day.isoformat(), 'interval': interval, 'error': str(error)})
        # One day per request avoids assuming a maximum range for old archives.
        try:
            client.read(DAYS, version='2.0', data={'devId': meter, 'dpId': args.dp,
                    'startDay': day.strftime('%Y%m%d'), 'endDay': day.strftime('%Y%m%d'),
                    'auto': 2, 'type': args.type})
        except NetworkError:
            raise
        except MobileError as error:
            transport.log('DAILY API ERROR', str(error))
        quarters, hours = series.get((day, '15min'), {}), series.get((day, 'hour'), {})
        if quarters and hours and args.type in ('minux', 'sum'):
            comparison = []
            for hour, value in sorted(hours.items()):
                keys = [hour + minute for minute in ('00', '15', '30', '45')]
                if all(key in quarters for key in keys):
                    total = sum(quarters[key] for key in keys)
                    comparison.append({'hour': hour, 'sum_15min': str(total),
                                       'hour_value': str(value), 'difference': str(total - value)})
            transport.log('15MIN VS HOUR (same raw units)', comparison)
    if args.logs or args.deep:
        try:
            result = client.read(LOGS, version='2.0', data={'devId': meter, 'dpIds': str(args.dp),
                                'offset': 0, 'limit': 100, 'sortType': 'DESC'})
            rows = result.get('dps', []) if isinstance(result, dict) else []
            transport.log('LOG SUMMARY', {'returned_records': len(rows),
                           'hasNext': result.get('hasNext') if isinstance(result, dict) else None,
                           'note': 'Последние записи, не полный архив; время и значения — в RESPONSE выше.'})
        except NetworkError:
            raise
        except MobileError as error:
            transport.log('LOG API ERROR', str(error))
    transport.log('SUMMARY', summaries)
    print('Пустой ответ за старую дату сам по себе не доказывает срок хранения: устройство могло не передавать данные.')
    if any(row.get('numeric_points', 0) > 0 for row in summaries):
        print('Tuya вернула числовые точки. Детализация и полнота — в SUMMARY; наличие часов не подтверждает 15 минут.')
        return 0
    print('История для запрошенных интервалов не подтверждена. Полные ответы API приведены выше.')
    return 2


if __name__ == '__main__':
    try:
        sys.exit(main())
    except MobileError as error:
        print(f'\nERROR: {error}', file=sys.stderr, flush=True)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
