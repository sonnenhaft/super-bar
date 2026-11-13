#!/usr/bin/env python3
"""Experimental, read-only Deye Cloud web API client (Python 3.9+).

Login/summary protocol reference:
https://github.com/ToonSoftwareCollective/solarpanel-plugins/blob/efbabdcbe5ce070d781f943ac2d8f6b1068a342b/DEYE1.plugin.txt
Operating data reference:
https://github.com/rlggyp/deye-exporter/blob/5541d850782e4c865ed86f307911443a830c2735/src/client.rs
Station search/daily history are candidate shared Solarman endpoints, not yet
verified against a live Deye account. Failures are reported, never replaced by 0.
https://github.com/Ashar2shahid/solarman-reimagined-dashboard/blob/0c561c7e7417875cdccab67c3a41f39404c79c6b/solarman-api-reference.md
"""

import argparse
import getpass
import hashlib
import json
import math
from pathlib import Path
import sys
import time
from datetime import datetime, timedelta
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit, urljoin
from urllib.request import Request, build_opener, HTTPRedirectHandler
from zoneinfo import ZoneInfo

if __package__:
    from .credential_store import CredentialError, JSONCredentialStore
else:
    from credential_store import CredentialError, JSONCredentialStore


SESSION = Path(__file__).resolve().parent.parent / '.env.deye-session.json'


class DeyeError(Exception):
    pass


class AuthError(DeyeError):
    pass


def checked_base(url):
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or parsed.username or parsed.password
            or parsed.port not in (None, 443)
            or parsed.hostname not in {'deyecloud.com', 'www.deyecloud.com',
                                       'eu1.deyecloud.com', 'us1.deyecloud.com',
                                       'india.deyecloud.com'}):
        raise DeyeError('Допустим только HTTPS-сервер Deye Cloud.')
    return 'https://' + parsed.hostname


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = build_opener(NoRedirect())


def connect(request):
    try:
        return OPENER.open(request, timeout=25)
    except HTTPError:
        raise
    except (URLError, OSError, TimeoutError):
        # urllib exceptions can contain the login URL/password hash. Never print them.
        raise DeyeError('Нет соединения с Deye. Проверь интернет, DNS и VPN.') from None


def discover(base):
    """Follow only public landing-page redirects, before sending any credentials."""
    for _ in range(5):
        try:
            with connect(Request(base + '/', headers={'User-Agent': 'Mozilla/5.0'})):
                return base
        except HTTPError as error:
            if error.code not in (301, 302, 303, 307, 308):
                raise DeyeError(f'Страница Deye вернула HTTP {error.code}.') from None
            location = error.headers.get('Location')
            if not location:
                raise DeyeError('Deye вернул перенаправление без адреса.')
            new_base = checked_base(urljoin(base + '/', location))
            if new_base == base:
                return base  # e.g. / -> /login; API remains at the same origin
            base = new_base
    raise DeyeError('Слишком много перенаправлений Deye.')


class Client:
    def __init__(self, base, token=None):
        self.base = checked_base(base)
        self.token = token
        self.refresh_token = None
        self.expires_at = None
        self.email = None
        self.password_sha256 = None
        self.recovery_failed = False

    def call(self, path, body=None, query=None, method=None):
        if self.recovery_failed:
            raise AuthError('Автоматический вход не удался. Для новых данных входа запусти --login.')
        if not self.token or (self.expires_at is not None and self.expires_at <= time.time() + 60):
            self.recover()
        try:
            return self._request(path, body, query, method)
        except AuthError:
            self.recover()
            # Retry the original read exactly once; never recurse on 401.
            try:
                return self._request(path, body, query, method)
            except AuthError:
                self.recovery_failed = True
                raise

    def _request(self, path, body=None, query=None, method=None, authenticate=True):
        url = self.base + path + (('?' + urlencode(query)) if query else '')
        headers = {'Accept': 'application/json', 'User-Agent': 'Mozilla/5.0'}
        if self.token and authenticate:
            headers['Authorization'] = 'Bearer ' + self.token
        payload = None if body is None else json.dumps(body).encode()
        if payload is not None:
            headers['Content-Type'] = 'application/json'
        request = Request(url, data=payload, headers=headers, method=method)
        try:
            with connect(request) as response:
                data = json.load(response)
        except HTTPError as error:
            if error.code == 401 or (not authenticate and error.code in (400, 403)):
                raise AuthError(f'{path}: авторизация отклонена (HTTP {error.code}).') from None
            hint = (' Сессия истекла или доступ запрещён; попробуй --login.'
                    if error.code in (401, 403) else '')
            if error.code in (301, 302, 303, 307, 308):
                hint = ' API перенаправляет запрос; пароль и токен дальше не отправлены.'
            raise DeyeError(f'{path}: HTTP {error.code}.{hint}') from None
        except (ValueError, UnicodeError):
            raise DeyeError(f'{path}: ожидался JSON. Возможно, API изменился или требует CAPTCHA.') from None
        if isinstance(data, dict) and (data.get('success') is False or data.get('error')):
            # Deliberately omit raw server error strings: they may echo credentials.
            if (not authenticate or data.get('error') in
                    ('invalid_token', 'expired_token', 'token_expired')
                    or str(data.get('code')) == '401'):
                raise AuthError(f'{path}: авторизация отклонена.')
            raise DeyeError(f'{path}: Deye отклонил запрос. Проверь вход; возможна CAPTCHA.')
        return data

    def login(self, email, password):
        self.login_hash(email, hashlib.sha256(password.encode()).hexdigest())

    def login_hash(self, email, password_sha256):
        data = self._request('/oauth-s/oauth/token', method='POST', authenticate=False, query={
            'grant_type': 'password', 'identity_type': '2', 'username': email,
            'password': password_sha256,
            'client_id': 'test', 'org_id': '0', 'record_flag': '0', 'system': 'Deye',
        })
        self.accept_tokens(data)
        self.email = email
        self.password_sha256 = password_sha256

    def accept_tokens(self, data, refreshing=False):
        data = unwrap(data)
        token = data.get('access_token') if isinstance(data, dict) else None
        if not isinstance(token, str) or not token.removeprefix('Bearer ').strip():
            raise AuthError('Deye не выдал токен. Этот способ входа мог измениться; возможна CAPTCHA.')
        self.token = token.removeprefix('Bearer ').strip()
        refresh = data.get('refresh_token')
        if isinstance(refresh, str) and refresh.strip():
            self.refresh_token = refresh.strip()
        elif not refreshing:
            self.refresh_token = None
        try:
            lifetime = float(data['expires_in'])
            self.expires_at = time.time() + lifetime if math.isfinite(lifetime) else None
        except (KeyError, TypeError, ValueError):
            self.expires_at = None  # Older responses: recover reactively on 401.
        self.recovery_failed = False

    def refresh(self):
        # Standard OAuth refresh grant on the same endpoint; live Deye verification pending.
        data = self._request('/oauth-s/oauth/token', method='POST', authenticate=False, query={
            'grant_type': 'refresh_token', 'refresh_token': self.refresh_token,
            'client_id': 'test', 'system': 'Deye',
        })
        self.accept_tokens(data, refreshing=True)

    def recover(self):
        if self.recovery_failed:
            raise AuthError('Автоматический вход не удался. Запусти --login.')
        if self.refresh_token:
            try:
                self.refresh()
            except AuthError:
                pass  # Revoked/unsupported refresh grant: try the saved login once.
            else:
                save_session(self)
                return
        if self.email and self.password_sha256:
            try:
                self.login_hash(self.email, self.password_sha256)
            except AuthError:
                self.recovery_failed = True
                raise AuthError('Сохранённый вход отклонён. Запусти --login для смены данных.') from None
        else:
            # Migration from old access-token-only sessions needs a password once.
            if not sys.stdin.isatty():
                self.recovery_failed = True
                raise AuthError('Токен истёк, сохранённых данных для входа нет. Запусти --login.')
            try:
                prompt_login(self)
            except DeyeError:
                self.recovery_failed = True
                raise
        save_session(self)


def prompt_login(client):
    email = client.email or input('Почта аккаунта Deye Cloud: ').strip()
    if '@' not in email:
        raise DeyeError('Этот способ входа поддерживает почту; укажи email аккаунта.')
    password = getpass.getpass('Пароль (скрыто, для следующих входов сохранится SHA-256): ')
    if not password:
        raise DeyeError('Пустой пароль.')
    client.login(email, password)


def unwrap(data):
    if isinstance(data, dict) and isinstance(data.get('data'), dict):
        return data['data']
    return data


def save_session(client):
    try:
        JSONCredentialStore(SESSION, 'deye-session', validate_saved_session).save(session_data(client))
    except CredentialError as error:
        raise DeyeError(str(error)) from None


def session_data(client):
    return {'base': client.base, 'token': client.token,
            'refresh_token': client.refresh_token, 'expires_at': client.expires_at,
            'email': client.email, 'password_sha256': client.password_sha256}


def client_from_session(data):
    try:
        if not isinstance(data['token'], str) or not data['token']:
            raise ValueError()
        client = Client(data['base'], data['token'])
        for key in ('refresh_token', 'email', 'password_sha256'):
            value = data.get(key)
            if value is not None and not isinstance(value, str):
                raise ValueError()
            setattr(client, key, value or None)
        if data.get('expires_at') is not None:
            expiry = float(data['expires_at'])
            if math.isfinite(expiry):
                client.expires_at = expiry
        # Migrate historical raw passwords to hashes before entering Keychain.
        if isinstance(data.get('password'), str) and data['password']:
            client.password_sha256 = hashlib.sha256(data['password'].encode()).hexdigest()
        return client
    except (ValueError, KeyError, TypeError):
        raise DeyeError('Некорректный файл сессии. Запусти с --login.') from None


def validate_saved_session(data):
    return session_data(client_from_session(data))


def load_session():
    try:
        data = JSONCredentialStore(SESSION, 'deye-session', validate_saved_session).load()
        return client_from_session(data) if data is not None else None
    except CredentialError as error:
        raise DeyeError(str(error)) from None


def fmt(value, divisor=1):
    try:
        if value is None or isinstance(value, bool):
            return 'нет данных'
        number = float(value) / divisor
        return f'{number:.3f}' if math.isfinite(number) else 'нет данных'
    except (TypeError, ValueError):
        return 'нет данных'


def safe_text(value):
    return ''.join(c for c in str(value) if c.isprintable())[:160]


def station_list(client):
    stations = []
    for page in range(1, 101):
        response = client.call('/maintain-s/operating/station/search', body={}, query={
            'order.direction': 'DESC', 'order.property': 'id', 'page': page, 'size': 100,
        })
        data = unwrap(response)
        rows = data.get('data', data.get('records')) if isinstance(data, dict) else data
        if not isinstance(rows, list):
            raise DeyeError('Не распознан ответ списка станций; нужен фактический формат API.')
        stations.extend(rows)
        if len(rows) < 100:
            return stations
    raise DeyeError('Список станций превысил 100 страниц; укажи --station ID.')


def report(client, station_id, name, tz):
    print(f'\nСтанция: {safe_text(name)} (ID {station_id})')
    current = unwrap(client.call(f'/maintain-s/operating/system/{station_id}'))
    if not isinstance(current, dict):
        raise DeyeError('Не распознан ответ текущих показаний.')
    print(f'Последняя мощность PV: {fmt(current.get("generationPower"), 1000)} кВт')
    print(f'Выработка сегодня:   {fmt(current.get("generationValue"))} кВт·ч')
    print(f'Статус: {safe_text(current.get("networkStatus", "неизвестен"))}')
    stamp = current.get('lastUpdateTime', current.get('collectionTime'))
    try:
        stamp = float(stamp)
        if stamp > 1e12:
            stamp /= 1000
        print('Время показаний:', datetime.fromtimestamp(stamp, tz).isoformat())
    except (TypeError, ValueError, OverflowError, OSError):
        print('Время показаний: сервер не сообщил; свежесть не подтверждена.')
    print(f'\nДата ({tz.key})   Выработка, кВт·ч')
    today = datetime.now(tz).date()
    complete = fmt(current.get('generationPower')) != 'нет данных'
    for ago in (2, 1, 0):
        day = today - timedelta(days=ago)
        suffix = ' (неполный день)' if ago == 0 else ''
        try:
            data = unwrap(client.call(
                f'/maintain-s/history/batteryPower/{station_id}/stats/daily',
                query={'year': day.year, 'month': day.month, 'day': day.day}))
            stats = data.get('statistics', {}) if isinstance(data, dict) else {}
            value = stats.get('generationValue') if isinstance(stats, dict) else None
            if fmt(value) == 'нет данных':
                raise DeyeError('В ответе нет statistics.generationValue; формат требует проверки.')
            print(f'{day}          {fmt(value)}{suffix}')
        except DeyeError as error:
            complete = False
            print(f'{day}          нет данных — {error}')
    return complete


def main():
    parser = argparse.ArgumentParser(description='Deye Cloud: мощность и три дня выработки. Экспериментальный web API.')
    parser.add_argument('--login', action='store_true', help='войти заново, заменив сохранённую сессию')
    parser.add_argument('--token', action='store_true', help='вместо пароля скрыто вставить свой web access token')
    parser.add_argument('--station', type=int, help='ID станции, если автоматический список недоступен')
    parser.add_argument('--base', help='HTTPS-домен Deye; обычно определяется по публичному перенаправлению')
    parser.add_argument('--timezone', default='Asia/Manila', help='часовой пояс станции (Asia/Manila)')
    args = parser.parse_args()
    try:
        tz = ZoneInfo(args.timezone)
    except (KeyError, ValueError):
        raise DeyeError('Неизвестный часовой пояс.') from None
    client = None if args.login or args.token else load_session()
    if client is None:
        # Discover routing before asking for credentials. No speculative retries of login.
        base = discover(checked_base(args.base or 'https://deyecloud.com'))
        print(f'Сервер: {base}')
        client = Client(base)
        if not sys.stdin.isatty():
            raise DeyeError('Запусти в интерактивном терминале для скрытого ввода пароля/токена.')
        if args.token:
            client.token = getpass.getpass('Твой Deye web access token (скрыто): ').removeprefix('Bearer ').strip()
            if not client.token:
                raise DeyeError('Пустой токен.')
        else:
            prompt_login(client)
        save_session(client)
        print('Сессия сохранена в macOS Keychain; следующие входы и обновления — автоматически.')
    elif args.base and checked_base(args.base) != client.base:
        raise DeyeError('Для смены сервера используй --login --base URL.')
    if args.station is not None and args.station <= 0:
        raise DeyeError('ID станции должен быть положительным.')
    stations = ([{'id': args.station, 'name': 'Deye'}] if args.station else station_list(client))
    if not stations:
        raise DeyeError('В аккаунте не найдено станций.')
    complete = True
    for station in stations:
        try:
            station_id = int(station.get('id', station.get('stationId')))
            if station_id <= 0:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise DeyeError('В списке станций отсутствует корректный ID.') from None
        try:
            complete = report(client, station_id, station.get('name', 'Deye'), tz) and complete
        except DeyeError as error:
            complete = False
            print(f'Станция {station_id}: {error}', file=sys.stderr)
    return 0 if complete else 2


if __name__ == '__main__':
    try:
        sys.exit(main())
    except DeyeError as error:
        print(f'Ошибка: {error}', file=sys.stderr)
        sys.exit(1)
    except (EOFError, KeyboardInterrupt):
        print('\nОтменено.', file=sys.stderr)
        sys.exit(130)
    except OSError:
        print('Ошибка чтения/записи локального файла или сетевого соединения.', file=sys.stderr)
        sys.exit(1)
