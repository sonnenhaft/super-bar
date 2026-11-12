"""Direct email/password mobile API, stdlib only.

Signing/app registrations: TuyaAPI/cloud and Apollon77/ioBroker.tuya.
Mobile v2/v3 authentication: reetamdan/smartlife-app-tuya/plug_api/auth.py
and thekoma/aventproxy/WHITEPAPER.md (clean-login Frida capture, section 7).
See TUYA-NOTICE.txt. No IoT Platform OpenAPI calls are used here.
"""
import base64
import hashlib
import hmac
import json
import re
import secrets
import time
import uuid
from urllib.parse import urlsplit, urlencode


class MobileError(Exception):
    pass


class MobileAuthError(MobileError):
    pass


APPS = {
    'tuya': {
        'ttid': 'tuya', 'key': '3fjrekuxank9eaej3gcx',
        'cert': '93:21:9F:C2:73:E2:20:0F:4A:DE:E5:F7:19:1D:C6:56:BA:2A:2D:7B:2F:F5:D2:4C:D5:5C:4B:61:55:00:1E:40',
        'secret2': 'vay9g59g9g99qf3rtqptmc3emhkanwkx', 'secret': 'aq7xvqcyqcnegvew793pqjmhv77rneqc',
    },
    'smartlife': {
        'ttid': 'smart_life', 'key': 'ekmnwp9f5pnh3trdtpgy',
        'cert': '0F:C3:61:99:9C:C0:C3:5B:A8:AC:A5:7D:AA:55:93:A2:0C:F5:57:27:70:2E:A8:5A:D7:B3:22:89:49:F8:88:FE',
        'secret2': 'jfg5rs5kkmrj5mxahugvucrsvw43t48x', 'secret': 'r3me7ghmxjevrvnpemwmhw3fxtacphyg',
    },
}
ENDPOINTS = {'EU': 'https://a1.tuyaeu.com/api.json', 'US': 'https://a1.tuyaus.com/api.json',
             'CN': 'https://a1.tuyacn.com/api.json', 'IN': 'https://a1.tuyain.com/api.json'}
SIGN_FIELDS = {'a', 'v', 'lat', 'lon', 'lang', 'deviceId', 'imei', 'imsi', 'appVersion',
               'ttid', 'isH5', 'h5Token', 'os', 'clientId', 'postData', 'time', 'requestId',
               'n4h5', 'sid', 'sp', 'et'}


def checked_endpoint(value):
    parsed = urlsplit(value)
    host = parsed.hostname or ''
    if (parsed.scheme != 'https' or parsed.username or parsed.password or parsed.port not in (None, 443)
            or parsed.path not in ('', '/', '/api.json') or parsed.query or parsed.fragment
            or not any(host.endswith('.' + domain) for domain in
                       ('tuyaeu.com', 'tuyaus.com', 'tuyacn.com', 'tuyain.com', 'iotbing.com', 'lifeaiot.com'))):
        raise MobileError('Некорректный адрес мобильного API Tuya.')
    return 'https://' + host + '/api.json'


def validate_mobile(data):
    try:
        if data['app'] not in APPS or data['region'] not in ENDPOINTS:
            raise ValueError()
        checked_endpoint(data['endpoint'])
        for key in ('sid', 'device_id', 'email', 'country_code'):
            if not isinstance(data[key], str) or not data[key]:
                raise ValueError()
        if data.get('password_md5') and not re.fullmatch('[0-9a-f]{32}', data['password_md5']):
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise MobileError('Некорректная сохранённая сессия мобильного API Tuya.') from None
    return data


def signature(fields, app):
    parts = []
    for key in sorted(fields):
        if key not in SIGN_FIELDS or fields[key] in ('', None):
            continue
        value = str(fields[key])
        if key == 'postData':
            digest = hashlib.md5(value.encode()).hexdigest()
            value = digest[8:16] + digest[:8] + digest[24:] + digest[16:24]
        parts.append(key + '=' + value)
    key = '_'.join(app[k] for k in ('cert', 'secret2', 'secret')).encode()
    return hmac.new(key, '||'.join(parts).encode(), hashlib.sha256).hexdigest()


def _der_items(data):
    offset = 0
    while offset < len(data):
        tag, length = data[offset], data[offset + 1]
        offset += 2
        if length & 128:
            count = length & 127
            if not 1 <= count <= 4:
                raise ValueError()
            length = int.from_bytes(data[offset:offset + count], 'big')
            offset += count
        if offset + length > len(data):
            raise ValueError()
        yield tag, data[offset:offset + length]
        offset += length


def rsa_password(password_md5, token, padding_mode=None):
    """Parse the server key separately from the login protocol's padding choice.

The mobile v3 login requires PKCS#1 v1.5 even when the key is supplied as a
decimal modulus instead of DER. None retains legacy behavior for old callers.
"""
    try:
        if padding_mode not in (None, 'pkcs1') or not re.fullmatch('[0-9a-f]{32}', password_md5):
            raise ValueError()
        public = token.get('pbKey') or token['publicKey']
        raw = re.sub(r'-----[^-]+-----|\s', '', public)
        der_key = bool(token.get('pbKey')) or 'BEGIN' in public or not token.get('exponent')
        if der_key:
            encoded = base64.b64decode(raw, validate=True)
            tag, sequence = next(_der_items(encoded))
            if tag != 0x30:
                raise ValueError()
            items = list(_der_items(sequence))
            if items[0][0] == 0x30:  # SubjectPublicKeyInfo wrapper.
                if items[1][0] != 3 or items[1][1][0] != 0:
                    raise ValueError()
                tag, sequence = next(_der_items(items[1][1][1:]))
                items = list(_der_items(sequence))
            if len(items) != 2 or any(tag != 2 for tag, _ in items):
                raise ValueError()
            modulus, exponent = (int.from_bytes(value, 'big') for _, value in items)
        else:
            # App responses also contain publicKey as a decimal integer string.
            # Such strings are often valid Base64 too: decoding them as Base64
            # silently constructs the wrong RSA modulus.
            modulus = (int(raw, 10) if raw.isdecimal() else
                       int.from_bytes(base64.b64decode(raw, validate=True), 'big'))
            exponent = int(token['exponent'])
        size = (modulus.bit_length() + 7) // 8
        if not 128 <= size <= 1024 or exponent < 3 or exponent % 2 == 0:
            raise ValueError()
        message = password_md5.encode('ascii')
        if padding_mode == 'pkcs1' or der_key:
            padding = bytearray()
            while len(padding) < size - len(message) - 3:
                byte = secrets.token_bytes(1)
                if byte != b'\0':
                    padding.extend(byte)
            message = b'\0\2' + padding + b'\0' + message
        return pow(int.from_bytes(message, 'big'), exponent, modulus).to_bytes(size, 'big').hex()
    except (ValueError, KeyError, TypeError, IndexError, StopIteration):
        raise MobileError('Tuya вернула неподдерживаемый ключ входа RSA.') from None


class MobileClient:
    # Only authentication and read endpoints. Device control is deliberately absent.
    ALLOWED_ACTIONS = frozenset({
        'thing.m.user.username.token.get', 'thing.m.user.email.password.login',
        'tuya.m.location.list', 'tuya.m.my.group.device.list',
        'tuya.m.device.ref.info.my.list',
    })

    def __init__(self, store, transport):
        self.store, self.transport = store, transport
        self.recovery_failed = False

    def request(self, action, data=None, version='1.0', gid=None, authenticated=True):
        if action not in self.ALLOWED_ACTIONS:
            raise MobileError('Разрешены только вход и чтение Tuya; этот метод заблокирован локально.')
        state = self.store.data
        app = APPS[state['app']]
        fields = {'a': action, 'v': version, 'deviceId': state['device_id'], 'os': 'Android',
                  'lang': 'en', 'clientId': app['key'], 'time': str(int(time.time())),
                  'et': '0.0.1', 'ttid': app['ttid'], 'appVersion': '3.8.5',
                  'appRnVersion': '5.11', 'platform': 'Android', 'requestId': str(uuid.uuid4())}
        if data is not None:
            fields['postData'] = json.dumps(data, ensure_ascii=False, separators=(',', ':'))
        if gid is not None:
            fields['gid'] = str(gid)
        if authenticated:
            fields['sid'] = state['sid']
        fields['sign'] = signature(fields, app)
        response = self.transport(checked_endpoint(state['endpoint']), method='POST',
                                  headers={'Content-Type': 'application/x-www-form-urlencoded'},
                                  data=urlencode(fields).encode())
        if response.get('success') is not True:
            code = str(response.get('errorCode', response.get('code', 'unknown')))
            if code in ('USER_SESSION_INVALID', 'USER_SESSION_EXPIRED'):
                raise MobileAuthError('Сессия Tuya истекла.')
            if any(word in code.upper() for word in ('MFA', 'VERIFY', 'CAPTCHA', 'NEED_SEND_CODE')):
                raise MobileError('Tuya требует подтверждение входа в приложении; после подтверждения повтори запуск.')
            safe = code if re.fullmatch(r'[A-Za-z0-9_-]{1,64}', code) else 'unknown'
            raise MobileError(f'Мобильный API Tuya отклонил {action} ({safe}).')
        return response.get('result')

    def login(self):
        state = self.store.data
        # A token is single-use and must come from the matching v2 endpoint.
        # The old email.token.create/v1 + password.login/v1 flow can return
        # USER_PASSWD_WRONG even for the correct app password.
        token = self.request('thing.m.user.username.token.get',
                             {'countryCode': state['country_code'], 'username': state['email'], 'isUid': False},
                             version='2.0', authenticated=False)
        if not isinstance(token, dict) or not isinstance(token.get('token'), str) or not token['token']:
            raise MobileError('Tuya не выдала одноразовый токен мобильного входа.')
        password = rsa_password(state['password_md5'], token, padding_mode='pkcs1')
        result = self.request('thing.m.user.email.password.login', {
            'countryCode': state['country_code'], 'email': state['email'], 'passwd': password,
            'ifencrypt': 1, 'options': json.dumps({'group': 1, 'mfaCode': ''}, separators=(',', ':')),
            'token': token['token'],
        }, version='3.0', authenticated=False)
        if not isinstance(result, dict) or not isinstance(result.get('sid'), str) or not result['sid']:
            raise MobileError('Tuya не выдала сессию после входа.')
        endpoint = (result.get('domain') or {}).get('mobileApiUrl', state['endpoint'])
        state.update(sid=result['sid'], endpoint=checked_endpoint(endpoint), uid=result.get('uid'))
        self.store.save()

    def read(self, action, **kwargs):
        if self.recovery_failed:
            raise MobileAuthError('Повторный вход Tuya отклонён.')
        try:
            return self.request(action, **kwargs)
        except MobileAuthError:
            if not self.store.data.get('password_md5'):
                raise
            try:
                self.login()
                return self.request(action, **kwargs)
            except MobileError:
                self.recovery_failed = True
                raise

    def devices(self):
        homes = self.read('tuya.m.location.list', version='2.1')
        if not isinstance(homes, list):
            raise MobileError('Неподдерживаемый список домов Tuya.')
        devices = {}
        for home in homes:
            gid = home.get('groupId', home.get('id'))
            if gid is None:
                raise MobileError('Дом Tuya без идентификатора.')
            rows = self.read('tuya.m.my.group.device.list', version='2.0', gid=gid)
            schemas = self.read('tuya.m.device.ref.info.my.list', version='2.0', gid=gid)
            if not isinstance(rows, list) or not isinstance(schemas, list):
                raise MobileError('Неподдерживаемый список устройств/схем Tuya.')
            schema_map = {str(s['id']): s.get('schemaInfo', {}) for s in schemas}
            for row in rows:
                devices[row['devId']] = normalize_device(row, schema_map.get(str(row.get('productId')), {}))
        return list(devices.values())


def decode_meter_phase(value):
    """i5mqmxkho1vahdt2: 2-byte decivolts, 3-byte mA, 3-byte watts, BE.

    Layout reference: https://github.com/rospogrigio/localtuya/issues/1193
    Restricted to this product below: other Tuya raw phases use different scales.
    """
    if not isinstance(value, str):
        return None
    try:
        data = base64.b64decode(value, validate=True)
    except ValueError:
        return None
    if len(data) != 8:
        return None
    return {'voltage_v': int.from_bytes(data[:2], 'big') / 10,
            'current_a': int.from_bytes(data[2:5], 'big') / 1000,
            'power_kw': int.from_bytes(data[5:8], 'big') / 1000}


def normalize_device(row, info):
    if isinstance(info, str):
        info = json.loads(info)
    schema = info.get('schema', []) if isinstance(info, dict) else []
    if isinstance(schema, str):
        schema = json.loads(schema)
    dps = (row.get('dataPointInfo') or {}).get('dps', row.get('dps', {}))
    status, ranges = {}, {}
    for item in schema:
        code, dp = item.get('code'), str(item.get('id'))
        if not code or dp not in dps:
            continue
        status[code] = dps[dp]
        ranges[code] = {'values': item.get('property', {})}
    electrical = {}
    phase_codes = [s.get('code') for s in schema if s.get('code') in ('phase_a', 'phase_b', 'phase_c')]
    if row.get('productId') == 'i5mqmxkho1vahdt2':
        for code in phase_codes:
            decoded = decode_meter_phase(status.get(code))
            if decoded is not None:
                electrical[code] = decoded
                power_code = 'power_' + code[-1]
                status[power_code] = decoded['power_kw']
                ranges[power_code] = {'values': {'unit': 'kW', 'scale': 0}}
    def online_flag(value):
        if isinstance(value, bool):
            return value
        if value in (0, 1):
            return bool(value)
        if isinstance(value, str) and value.lower() in ('true', 'false'):
            return value.lower() == 'true'
        return None

    online = online_flag(row.get('isOnline'))
    if online is None:
        online = online_flag(row.get('online'))
    if online is None:
        online = online_flag(row.get('cloudOnline'))
    if online is None:
        modules = list((row.get('moduleMap') or {}).values())
        flags = [module['isOnline'] for module in modules if isinstance(module.get('isOnline'), bool)]
        online = any(flags) if flags else None
    # Keep only device readings/schema for local diagnosis, never the raw row:
    # raw rows can also contain localKey, IP addresses, and other private data.
    diagnostics = {
        'source_fields': sorted(row), 'product_id': row.get('productId'),
        'online_fields': {k: row[k] for k in ('isOnline', 'online', 'isCloudOnline', 'cloudOnline') if k in row},
        'dps': dps,
        'schema': [{k: item[k] for k in ('id', 'code', 'type', 'mode', 'property') if k in item}
                   for item in schema],
    }
    return {'id': row['devId'], 'name': row.get('name', ''), 'category': row.get('category', ''),
            'product_name': row.get('productName', ''), 'online': online,
            'status': status, 'status_range': ranges, 'update_time': row.get('dpMaxTime'),
            'electrical': electrical, 'single_phase': phase_codes == ['phase_a'] and bool(electrical),
            'diagnostics': diagnostics}
