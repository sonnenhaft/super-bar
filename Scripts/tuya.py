#!/usr/bin/env python3
"""Read-only Tuya client: email/password login, persistent session, device power.

Wire protocol reference: https://github.com/tuya/tuya-device-sharing-sdk
Implemented directly using only the Python standard library.
QR registration: home-assistant/core, homeassistant/components/tuya/const.py.
Import Client for library use; run Scripts/tuya.command for the CLI.
"""
import argparse
import getpass
from datetime import datetime, timezone
import json
import base64
import hashlib
import hmac
import secrets
import uuid
import math
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
from urllib.parse import urlsplit, urlencode, quote
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, HTTPRedirectHandler

if __package__:
    from .credential_store import CredentialError, JSONCredentialStore, read_legacy_file
    from .tuya_wire import gcm_encrypt, gcm_decrypt, print_qr
    from .tuya_mobile import MobileClient, MobileError as TuyaError, MobileAuthError as AuthError, validate_mobile, ENDPOINTS
else:
    from credential_store import CredentialError, JSONCredentialStore, read_legacy_file
    from tuya_wire import gcm_encrypt, gcm_decrypt, print_qr
    from tuya_mobile import MobileClient, MobileError as TuyaError, MobileAuthError as AuthError, validate_mobile, ENDPOINTS

SESSION = Path(__file__).resolve().parent.parent / '.env.tuya-session.json'
CLIENT_ID = 'HA_3y9q4ak7g4ephrvke'
TOKEN_FIELDS = ('t', 'uid', 'expire_time', 'access_token', 'refresh_token')
TOTAL_CODES = ('total_power', 'total_active_power', 'power_total', 'cur_power',
               'active_power', 'power')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = build_opener(NoRedirect())


def request_json(url, method='GET', headers=None, data=None):
    request = Request(url, data=data, method=method, headers={'Accept': 'application/json', **(headers or {})})
    try:
        with OPENER.open(request, timeout=30) as response:
            raw = response.read(8 * 1024 * 1024 + 1)
        if len(raw) > 8 * 1024 * 1024:
            raise TuyaError('Слишком большой ответ Tuya.')
        result = json.loads(raw)
        if not isinstance(result, dict):
            raise ValueError()
        return result
    except HTTPError as error:
        if error.code == 401:
            raise AuthError('Tuya отклонила сессию. Повторный вход начнётся автоматически в терминале.') from None
        raise TuyaError(f'Tuya вернула HTTP {error.code}.') from None
    except (URLError, OSError, TimeoutError):
        raise TuyaError('Нет соединения с Tuya. Проверь интернет, DNS и VPN.') from None
    except (ValueError, UnicodeError):
        raise TuyaError('Tuya вернула некорректный JSON.') from None


def checked_response(response):
    if response.get('success') is not True:
        code = str(response.get('code', ''))
        if code in ('1010', '1011'):
            raise AuthError('Сессия Tuya недействительна или истекла.')
        # Never print server messages: they can echo credentials.
        label = code if re.fullmatch(r'[A-Za-z0-9_-]{1,24}', code) else 'unknown'
        raise TuyaError(f'Tuya отклонила запрос (код {label}).')
    return response


def validate_session(data):
    if isinstance(data, dict) and data.get('mode') == 'mobile':
        return validate_mobile(data)
    try:
        for key in ('client_id', 'user_code', 'terminal_id', 'endpoint'):
            if not isinstance(data[key], str) or not data[key]:
                raise ValueError()
        url = urlsplit(data['endpoint'])
        host = url.hostname or ''
        if (url.scheme != 'https' or url.username or url.password or url.port not in (None, 443)
                or url.path not in ('', '/') or url.query or url.fragment
                or not any(host == domain or host.endswith('.' + domain)
                           for domain in ('tuyaus.com', 'tuyaeu.com', 'tuyacn.com',
                                          'tuyain.com', 'iotbing.com'))):
            raise ValueError()
        token = data['token_info']
        for key in ('access_token', 'refresh_token', 'uid'):
            if not isinstance(token[key], str) or not token[key]:
                raise ValueError()
        for key in ('t', 'expire_time'):
            if isinstance(token[key], bool) or not math.isfinite(float(token[key])) or float(token[key]) <= 0:
                raise ValueError()
        if data.get('meter_id') is not None and not isinstance(data['meter_id'], str):
            raise ValueError()
    except (KeyError, TypeError, ValueError, AttributeError):
        raise TuyaError('Некорректная сессия Tuya. Открой Scripts/tuya.command.') from None
    return data


class SessionStore:
    credential_kind = 'tuya-session'

    def __init__(self, path=None):
        self.path = Path(SESSION if path is None else path)
        self.data = None

    def validate(self, data):
        return validate_session(data)

    def load(self):
        try:
            self.data = JSONCredentialStore(self.path, self.credential_kind, self.validate).load()
        except CredentialError as error:
            raise TuyaError(str(error)) from None
        if self.credential_kind == 'tuya-session':
            login = LoginSettings(self.path)
            if login.path.exists():
                login.load()  # Migrate old saved hashes even when the session is valid.
        return self.data

    def save(self):
        try:
            JSONCredentialStore(self.path, self.credential_kind, self.validate).save(self.data)
        except CredentialError as error:
            raise TuyaError(str(error)) from None

    def update_token(self, token_info):
        # Persist rotated tokens before the next API read.
        self.data['token_info'] = {key: token_info[key] for key in TOKEN_FIELDS}
        self.save()


class LoginSettings(SessionStore):
    """Remember input independently of successful session creation."""
    credential_kind = 'tuya-login'

    def __init__(self, session_path):
        super().__init__(Path(session_path).with_name('.env.tuya-login.json'))

    def validate(self, data):
        if not isinstance(data, dict):
            raise TuyaError('Некорректные сохранённые настройки входа Tuya.')
        for key in ('email', 'country_code', 'region', 'password_md5', 'device_id'):
            if key in data and not isinstance(data[key], str):
                raise TuyaError('Некорректные сохранённые настройки входа Tuya.')
        if data.get('password_md5') and not re.fullmatch('[0-9a-f]{32}', data['password_md5']):
            raise TuyaError('Некорректный сохранённый пароль Tuya.')
        return data


class DeviceSnapshot(SessionStore):
    """Non-secret readings remain an exportable JSON file for history tools."""
    def __init__(self, session_path):
        super().__init__(Path(session_path).with_name('.env.tuya-devices.json'))

    def validate(self, data):
        if not isinstance(data, dict) or not isinstance(data.get('devices'), list):
            raise TuyaError('Некорректный снимок устройств Tuya.')
        return data

    def load(self):
        try:
            info = self.path.lstat()
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
            raise TuyaError('Снимок устройств должен быть обычным приватным файлом.')
        try:
            self.data = self.validate(json.loads(self.path.read_text()))
        except (ValueError, UnicodeError):
            raise TuyaError('Повреждён снимок устройств Tuya.') from None
        return self.data

    def save(self):
        self.validate(self.data)
        fd, name = tempfile.mkstemp(prefix='.tuya-readings-', dir=self.path.parent)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(self.data, stream)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)


def session_candidates():
    """Only inspect Tuya-specific files; never scan unrelated credential stores."""
    home = Path.home()
    roots = [SESSION.parent, home / '.tuya', home / '.config/tuya',
             home / 'Library/Application Support/Super Bar',
             home / 'Library/Application Support/Tuya']
    yield home / '.tuya-session.json'
    for root in roots:
        for name in ('.env.tuya-session.json', 'tuya-session.json', 'tuya_session.json'):
            yield root / name
        if root != SESSION.parent:
            yield root / 'session.json'


def load_available_session(store):
    if store.load():
        return store.data
    found = {}
    for path in session_candidates():
        if path == store.path:
            continue
        try:
            legacy = read_legacy_file(path)
            if legacy is None:
                continue
            data = json.loads(legacy[0])
            if not isinstance(data, dict):
                continue
            # Accept the existing client session format, including wrappers.
            if 'token_info' not in data and data.get('mode') != 'mobile':
                data = data.get('session', data.get('data', {}))
            data = dict(data)
            data.setdefault('client_id', CLIENT_ID)
            validate_session(data)
        except (OSError, ValueError, TypeError, TuyaError, CredentialError):
            continue
        if data.get('mode') == 'mobile':
            identity = (data['app'], data['email'])
            found.setdefault(identity, {key: data[key] for key in (
                'mode', 'app', 'region', 'endpoint', 'email', 'country_code', 'device_id', 'sid',
                'password_md5', 'meter_id', 'uid') if key in data})
            continue
        identity = (data['endpoint'], data['token_info']['uid'])
        previous = found.get(identity)
        if previous is None or float(data['token_info']['t']) > float(previous['token_info']['t']):
            # Import only the fields needed by this client, never extra secrets.
            found[identity] = {key: data[key] for key in
                               ('client_id', 'user_code', 'terminal_id', 'endpoint', 'token_info')}
            if data.get('meter_id'):
                found[identity]['meter_id'] = data['meter_id']
    if len(found) > 1:
        raise TuyaError('Найдено несколько аккаунтов Tuya; невозможно выбрать аккаунт однозначно.')
    if found:
        store.data = next(iter(found.values()))
        store.save()
    return store.data


def ensure_login(store, force=False, user_code=None):
    if not force and load_available_session(store):
        return
    if not sys.stdin.isatty() and not user_code:
        raise TuyaError('Сохранённая сессия Tuya не найдена или отозвана. '
                        'Открой Scripts/tuya.command в терминале: первый вход начнётся автоматически.')
    saved = store.data or {}
    if user_code:
        login(store, user_code)  # Explicit legacy QR login only; never the default.
    else:
        password_login(store)
    if saved.get('meter_id'):
        store.data['meter_id'] = saved['meter_id']
        store.save()


LOGIN_URL = 'https://apigw.iotbing.com/v1.0/m/life/home-assistant/qrcode/tokens'


def password_login(store):
    settings = LoginSettings(store.path)
    stored_session = store.data or store.load() or {}
    saved = {key: stored_session[key] for key in
             ('email', 'country_code', 'region', 'password_md5', 'device_id') if key in stored_session}
    saved.update(settings.load() or {})
    saved['app'] = 'smartlife'
    settings.data = saved

    def remember(key, value):
        saved[key] = value
        settings.save()  # Persist each answer before the next prompt or network call.
        return value

    previous = saved.get('email', '')
    email = input(f'Почта Smart Life [{safe_text(previous)}]: ').strip() or previous
    if '@' not in email:
        raise TuyaError('Укажи почту аккаунта приложения.')
    remember('email', email)
    previous = saved.get('country_code') or '63'
    country = input(f'Код страны аккаунта [{safe_text(previous)}]: ').strip().lstrip('+') or previous
    if not re.fullmatch(r'[0-9]{1,4}', country):
        raise TuyaError('Нужен код страны аккаунта цифрами, например 63.')
    remember('country_code', country)
    previous = saved.get('region') or 'EU'
    region = input(f'Регион аккаунта EU / US / CN / IN [{safe_text(previous)}]: ').strip().upper() or previous
    if region not in ENDPOINTS:
        raise TuyaError('Неизвестный регион аккаунта.')
    remember('region', region)
    hint = 'Enter — оставить сохранённый' if saved.get('password_md5') else 'ввод скрыт'
    password = getpass.getpass(f'Пароль ({hint}): ')
    if password:
        remember('password_md5', hashlib.md5(password.encode()).hexdigest())
    if not saved.get('password_md5'):
        raise TuyaError('Пустой пароль.')
    del password
    remember('device_id', saved.get('device_id') or secrets.token_hex(22))
    candidate = SessionStore(store.path)
    candidate.data = {
        'mode': 'mobile', 'app': 'smartlife', 'region': region, 'endpoint': ENDPOINTS[region],
        'email': email, 'country_code': country,
        'device_id': saved['device_id'], 'sid': '', 'password_md5': saved['password_md5'],
    }
    MobileClient(candidate, request_json).login()
    store.data = candidate.data
    print('Вход по почте сохранён. Дальше сессия используется автоматически.', file=sys.stderr)


def login(store, user_code=None):
    code = user_code or input('Smart Life / Tuya Smart → Я → Настройки → Учётная запись → User Code: ').strip()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', code):
        raise TuyaError('Нужен User Code из приложения (буквы и цифры).')
    query = {'clientid': CLIENT_ID, 'usercode': code}
    response = checked_response(request_json(
        LOGIN_URL + '?' + urlencode(dict(query, schema='haauthorize')), method='POST'))
    token = response['result']['qrcode']
    print('Отсканируй QR сканером Smart Life / Tuya Smart и подтверди вход.', file=sys.stderr)
    print_qr('tuyaSmart--qrLogin?token=' + token, sys.stderr)
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        response = request_json(LOGIN_URL + '/' + quote(token, safe='') + '?' + urlencode(query))
        if response.get('success'):
            info = dict(response['result'], t=response['t'])
            store.data = validate_session({
                'client_id': CLIENT_ID, 'user_code': code,
                'terminal_id': info['terminal_id'], 'endpoint': info['endpoint'],
                'token_info': {key: info[key] for key in TOKEN_FIELDS},
            })
            store.save()
            print('Вход сохранён. Следующие запуски используют эту сессию.', file=sys.stderr)
            return
        time.sleep(2)
    raise TuyaError('QR не подтверждён за 3 минуты. Запусти скрипт ещё раз.')


class Client:
    """Direct read-only HTTP client. Construction never prompts or logs in."""
    def __init__(self, session_path=None):
        self.store = SessionStore(session_path)
        data = load_available_session(self.store) if session_path is None else self.store.load()
        if not data:
            raise TuyaError('Сессия Tuya не найдена. Открой Scripts/tuya.command для автоматического входа.')
        self.recovery_failed = False
        self.mobile = MobileClient(self.store, request_json) if data.get('mode') == 'mobile' else None

    def _request(self, path, params=None):
        data = self.store.data
        token = data['token_info']
        request_id = str(uuid.uuid4())
        hash_key = hashlib.md5((request_id + token['refresh_token']).encode()).hexdigest().encode()
        secret = hmac.new(request_id.encode(), hash_key, hashlib.sha256).hexdigest()[:16].encode()
        encrypted = ''
        if params:
            plaintext = json.dumps(params, separators=(',', ':')).encode()
            nonce = secrets.token_bytes(12)
            encrypted = base64.b64encode(nonce + gcm_encrypt(secret, nonce, plaintext)).decode()
        headers = {'X-appKey': data['client_id'], 'X-requestId': request_id,
                   'X-sid': '', 'X-time': str(int(time.time() * 1000)),
                   'X-token': token['access_token']}
        sign_input = '||'.join(key + '=' + value for key, value in headers.items() if value) + encrypted
        headers['X-sign'] = hmac.new(hash_key, sign_input.encode(), hashlib.sha256).hexdigest()
        url = data['endpoint'].rstrip('/') + path
        if encrypted:
            url += '?' + urlencode({'encdata': encrypted})
        response = checked_response(request_json(url, headers=headers))
        if response.get('result'):
            try:
                sealed = base64.b64decode(response['result'], validate=True)
                plain = gcm_decrypt(secret, sealed[:12], sealed[12:])
                response['result'] = json.loads(plain)
            except (ValueError, TypeError, UnicodeError):
                raise TuyaError('Ответ Tuya не прошёл проверку шифрования/формата.') from None
        return response

    def refresh(self):
        if self.recovery_failed:
            raise AuthError('Обновление сессии отклонено. Открой Scripts/tuya.command для повторного входа.')
        try:
            response = self._request('/v1.0/m/token/' + quote(self.store.data['token_info']['refresh_token'], safe=''))
            result = response['result']
            token = {'t': response['t'], 'expire_time': result['expireTime'], 'uid': result['uid'],
                     'access_token': result['accessToken'], 'refresh_token': result['refreshToken']}
            candidate = dict(self.store.data, token_info=token)
            validate_session(candidate)
            if float(token['t']) + float(token['expire_time']) * 1000 <= time.time() * 1000:
                raise AuthError('Tuya выдала уже истёкший токен.')
            self.store.update_token(token)
        except AuthError:
            self.recovery_failed = True
            raise
        except (KeyError, TypeError, ValueError):
            raise TuyaError('Tuya не выдала корректные токены обновления.') from None

    def get(self, path, params=None):
        if self.recovery_failed:
            raise AuthError('Сессия отклонена. Открой Scripts/tuya.command для повторного входа.')
        token = self.store.data['token_info']
        refreshed = float(token['t']) + float(token['expire_time']) * 1000 <= (time.time() + 60) * 1000
        if refreshed:
            self.refresh()
        try:
            return self._request(path, params)['result']
        except AuthError:
            if refreshed:
                self.recovery_failed = True
                raise
            self.refresh()
            try:
                return self._request(path, params)['result']
            except AuthError:
                self.recovery_failed = True
                raise

    def devices(self):
        if self.mobile:
            return [device_report(device) for device in self.mobile.devices()]
        homes = self.get('/v1.0/m/life/users/homes')
        if not isinstance(homes, list):
            raise TuyaError('Некорректный список домов Tuya.')
        devices = {}
        for home in homes:
            rows = self.get('/v1.0/m/life/ha/home/devices', {'homeId': str(home['ownerId'])})
            if not isinstance(rows, list):
                raise TuyaError('Некорректный список устройств Tuya.')
            for row in rows:
                devices[row['id']] = dict(row)
        reports = []
        for device in devices.values():
            spec = self.get('/v1.1/m/life/' + quote(device['id'], safe='') + '/specifications')
            if not isinstance(spec, dict):
                raise TuyaError('Некорректные характеристики устройства Tuya.')
            device['status_range'] = {item['code']: item for item in spec.get('status', [])}
            device['function'] = {item['code']: item for item in spec.get('functions', [])}
            if isinstance(device.get('status'), list):
                device['status'] = {item['code']: item['value'] for item in device['status']
                                    if 'code' in item and 'value' in item}
            reports.append(device_report(device))
        return reports

    def close(self):
        pass  # No persistent sockets, MQTT threads, or server-side logout.

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def field(value, key, default=None):
    return value.get(key, default) if isinstance(value, dict) else getattr(value, key, default)


def power_readings(device):
    readings = []
    for code, raw in (field(device, 'status', {}) or {}).items():
        spec = (field(device, 'status_range', {}) or {}).get(code)
        if spec is None:
            spec = (field(device, 'function', {}) or {}).get(code)
        values = field(spec, 'values', {})
        try:
            if isinstance(values, str):
                values = json.loads(values)
            unit = str(values.get('unit', '')).strip()
            factors = {'W': .001, 'w': .001, 'kW': 1, 'kw': 1, 'KW': 1,
                       'MW': 1000, 'mW': .000001}
            if unit not in factors:
                continue  # Never guess scale/unit from a datapoint name.
            if 'scale' not in values or isinstance(raw, bool):
                continue
            scale = int(values['scale'])
            if not 0 <= scale <= 12:
                continue
            kw = float(raw) / (10 ** scale) * factors[unit]
            if math.isfinite(kw):
                readings.append({'code': code, 'kw': kw, 'raw': raw, 'unit': unit, 'scale': scale})
        except (ValueError, TypeError, AttributeError, OverflowError):
            continue
    return readings


def meter_readings(device):
    result = {}
    for code, key, units in (
            ('total_forward_energy', 'forward_energy_kwh', ('kWh', 'kW·h')),
            ('leakage_current', 'leakage_current_ma', ('mA',)),
            ('temp_current', 'temperature_c', ('℃', '°C'))):
        raw = (field(device, 'status', {}) or {}).get(code)
        spec = (field(device, 'status_range', {}) or {}).get(code, {})
        values = field(spec, 'values', {})
        try:
            if isinstance(values, str):
                values = json.loads(values)
            if values.get('unit') not in units or isinstance(raw, bool):
                continue
            scale = int(values['scale'])
            if not 0 <= scale <= 12:
                continue
            value = float(raw) / 10 ** scale
            if math.isfinite(value):
                result[key] = value
        except (ValueError, TypeError, KeyError, AttributeError, OverflowError):
            continue
    return result


def device_report(device):
    readings = power_readings(device)
    # Prefer a declared total; do not sum phases and total, or apparent/reactive power.
    total = next((reading for code in TOTAL_CODES for reading in readings if reading['code'] == code), None)
    phases = {item['code']: item for item in readings}
    if total is None and all('power_' + phase in phases for phase in 'abc'):
        total = {'kw': sum(phases['power_' + phase]['kw'] for phase in 'abc'),
                 'code': 'power_a + power_b + power_c'}
    if total is None and field(device, 'single_phase', False):
        total = phases.get('power_a')
    online = field(device, 'online')
    return {
        'id': field(device, 'id'), 'name': field(device, 'name', ''),
        'category': field(device, 'category', ''), 'product': field(device, 'product_name', ''),
        'online': online, 'power_kw': total['kw'] if total and online is True else None,
        'last_reported_power_kw': total['kw'] if total else None,
        'power_source': total['code'] if total else None,
        'power_readings': readings,
        'electrical': field(device, 'electrical', {}),
        'meter_readings': meter_readings(device),
        'device_update_time': field(device, 'update_time'),
        'freshness': 'cloud_snapshot; measurement timestamp not verified',
        'diagnostics': field(device, 'diagnostics', {}),
    }


def select_meter(devices, selected=None):
    if selected:
        match = next((d for d in devices if d['id'] == selected), None)
        if not match:
            raise TuyaError('Сохранённый/указанный meter отсутствует в аккаунте. Укажи --meter ID.')
        return match, 'selected'
    candidates = [d for d in devices if d['category'] in ('zndb', 'dlq') or d.get('electrical') or
                  re.search(r'\bmeter\b|сч[её]тчик|лічильник|licznik',
                            d['name'] + ' ' + d['product'], re.I)]
    named = [d for d in candidates if re.search(r'\bmain\b|\bgrid\b|главн|ввод|główn', d['name'], re.I)]
    if len(named) == 1:
        return named[0], 'candidate_by_name'
    if len(candidates) == 1:
        return candidates[0], 'only_meter_candidate'
    return None, 'ambiguous' if candidates else 'not_found'


def safe_text(value):
    return ''.join(c for c in str(value) if c.isprintable())[:160]


def render(result):
    print('Устройства Tuya:')
    for device in result['devices']:
        power = device['power_kw']
        value = f'{power:.3f} кВт' if power is not None else 'мощность недоступна'
        if power is None and device['last_reported_power_kw'] is not None:
            value = f"{device['last_reported_power_kw']:.3f} кВт (последнее облачное показание)"
        online = {True: 'online', False: 'offline', None: 'статус неизвестен'}[device['online']]
        print(f"  {safe_text(device['id'])}  {safe_text(device['name'])} [{safe_text(device['category'])}] {online} — {value}")
        for reading in device['power_readings']:
            print(f"    {safe_text(reading['code'])}: {reading['kw']:.3f} кВт (последнее показание)")
        for phase, values in device.get('electrical', {}).items():
            print(f"    {safe_text(phase)}: {values['voltage_v']:.1f} В · {values['current_a']:.3f} А")
        for key, label, unit in (('forward_energy_kwh', 'Накопленная энергия', 'кВт·ч'),
                                 ('leakage_current_ma', 'Утечка', 'мА'),
                                 ('temperature_c', 'Температура', '°C')):
            value = device.get('meter_readings', {}).get(key)
            if value is not None:
                print(f'    {label}: {value:g} {unit}')
    meter = result['meter']
    if meter:
        label = 'Главный meter' if result['selection'] == 'selected' else 'Вероятный главный meter'
        print(f"\n{label}: {safe_text(meter['name'])} ({safe_text(meter['id'])})")
        power = meter['power_kw']
        if power is not None:
            print(f'Мощность: {power:.3f} кВт')
        elif meter['last_reported_power_kw'] is not None:
            print(f"Последняя мощность: {meter['last_reported_power_kw']:.3f} кВт; связь не подтверждена.")
        else:
            print('Мощность: нет расшифрованного показания; нужны datapoints и схема устройства.')
        if result['selection'] != 'selected':
            print(f"Закрепить выбор: Scripts/tuya.command --meter {safe_text(meter['id'])}")
    else:
        print('\nГлавный meter не определён однозначно. Выбери: Scripts/tuya.command --meter ID')
    print('Это последние облачные показания; время измерения не подтверждено.')
    if result.get('snapshot_path') and meter and meter['power_kw'] is None:
        print('Показания и схема сохранены:', result['snapshot_path'])


def main(argv=None):
    parser = argparse.ArgumentParser(description='Tuya: сохранённый вход, устройства и мощность счётчика в кВт.')
    parser.add_argument('--login', action='store_true', help='Повторный ввод почты и пароля')
    parser.add_argument('--meter', metavar='ID', help='Запомнить главный счётчик')
    parser.add_argument('--json', action='store_true', help='JSON без токенов и local_key')
    args = parser.parse_args(argv)
    try:
        store = SessionStore()
        ensure_login(store, force=args.login)
        try:
            with Client(store.path) as client:
                devices = client.devices()
        except AuthError:
            # One automatic reauthorization after refresh was rejected, not on network errors.
            ensure_login(store, force=True)
            with Client(store.path) as client:
                devices = client.devices()
        with Client(store.path) as client:
            meter, reason = select_meter(devices, args.meter or client.store.data.get('meter_id'))
            if args.meter:
                client.store.data['meter_id'] = meter['id']
                client.store.save()
            result = {'fetched_at': datetime.now(timezone.utc).isoformat(), 'devices': devices,
                      'meter': meter, 'selection': reason}
            snapshot = DeviceSnapshot(store.path)
            snapshot.data = result
            try:
                snapshot.save()
                result['snapshot_path'] = str(snapshot.path)
            except OSError:
                print('Не удалось сохранить снимок устройств; полученные показания доступны ниже.', file=sys.stderr)
            if args.json:
                print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
            else:
                render(result)
            return 0 if meter and meter['power_kw'] is not None else 2
    except (TuyaError, OSError, EOFError) as error:
        message = str(error) if isinstance(error, TuyaError) else 'Не удалось прочитать/сохранить сессию или получить ввод.'
        print('Ошибка: ' + message, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    except Exception:
        print('Неожиданный формат ответа Tuya. Секреты не выведены.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
