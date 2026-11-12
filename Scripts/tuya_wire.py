"""Small stdlib-only primitives needed by Tuya's wire format and QR login.

AES-128-GCM with 96-bit nonces, no associated data, and full 128-bit tags.
QR byte mode, error correction L, versions 1–6, fixed mask 0.
No package installation, subprocesses, native libraries, or network QR services.
"""
import hmac


def _mul(a, b, polynomial=0x11b):
    result = 0
    while b:
        if b & 1:
            result ^= a
        a <<= 1
        if a & 256:
            a ^= polynomial
        b >>= 1
    return result


def _sbox():
    table = []
    for value in range(256):
        inverse, base, power = 1, value, 254
        while power:
            if power & 1:
                inverse = _mul(inverse, base)
            base = _mul(base, base)
            power >>= 1
        result = inverse
        for shift in (1, 2, 3, 4):
            result ^= ((inverse << shift) | (inverse >> (8 - shift))) & 255
        table.append(result ^ 0x63)
    return table


_SBOX = _sbox()


class AES128:
    def __init__(self, key):
        if len(key) != 16:
            raise ValueError('AES-128 requires a 16-byte key')
        expanded = list(key)
        rcon = 1
        while len(expanded) < 176:
            word = expanded[-4:]
            if len(expanded) % 16 == 0:
                word = [_SBOX[value] for value in word[1:] + word[:1]]
                word[0] ^= rcon
                rcon = _mul(rcon, 2)
            for value in word:
                expanded.append(expanded[-16] ^ value)
        self.keys = [expanded[i:i + 16] for i in range(0, 176, 16)]

    def encrypt(self, block):
        if len(block) != 16:
            raise ValueError('AES requires a 16-byte block')
        state = [a ^ b for a, b in zip(block, self.keys[0])]
        for round_index in range(1, 11):
            state = [_SBOX[state[4 * ((column + row) % 4) + row]]
                     for column in range(4) for row in range(4)]
            if round_index != 10:
                for offset in range(0, 16, 4):
                    a = state[offset:offset + 4]
                    combined = a[0] ^ a[1] ^ a[2] ^ a[3]
                    state[offset:offset + 4] = [a[i] ^ combined ^ _mul(a[i] ^ a[(i + 1) % 4], 2)
                                                for i in range(4)]
            state = [a ^ b for a, b in zip(state, self.keys[round_index])]
        return bytes(state)


def _gf128(a, b):
    result = 0
    for shift in range(127, -1, -1):
        if (a >> shift) & 1:
            result ^= b
        b = (b >> 1) ^ (0xe1000000000000000000000000000000 if b & 1 else 0)
    return result


def _tag(aes, nonce, ciphertext):
    h = int.from_bytes(aes.encrypt(bytes(16)), 'big')
    value = 0
    for offset in range(0, len(ciphertext), 16):
        block = ciphertext[offset:offset + 16].ljust(16, b'\0')
        value = _gf128(value ^ int.from_bytes(block, 'big'), h)
    value = _gf128(value ^ (len(ciphertext) * 8), h)
    mask = int.from_bytes(aes.encrypt(nonce + b'\0\0\0\1'), 'big')
    return (value ^ mask).to_bytes(16, 'big')


def _ctr(aes, nonce, data):
    output = bytearray()
    for offset in range(0, len(data), 16):
        stream = aes.encrypt(nonce + (offset // 16 + 2).to_bytes(4, 'big'))
        output.extend(a ^ b for a, b in zip(data[offset:offset + 16], stream))
    return bytes(output)


def gcm_encrypt(key, nonce, plaintext):
    if len(nonce) != 12:
        raise ValueError('GCM requires a 12-byte nonce')
    aes = AES128(key)
    ciphertext = _ctr(aes, nonce, plaintext)
    return ciphertext + _tag(aes, nonce, ciphertext)


def gcm_decrypt(key, nonce, sealed):
    if len(nonce) != 12 or len(sealed) < 16:
        raise ValueError('Invalid GCM message')
    aes = AES128(key)
    ciphertext, tag = sealed[:-16], sealed[-16:]
    if not hmac.compare_digest(tag, _tag(aes, nonce, ciphertext)):
        raise ValueError('GCM authentication failed')
    return _ctr(aes, nonce, ciphertext)


def _rs_remainder(data, degree):
    divisor = [1]
    root = 1
    for _ in range(degree):
        following = [0] * (len(divisor) + 1)
        for i, value in enumerate(divisor):
            following[i] ^= value
            following[i + 1] ^= _mul(value, root, 0x11d)
        divisor = following
        root = _mul(root, 2, 0x11d)
    remainder = [0] * degree
    for value in data:
        factor = value ^ remainder[0]
        remainder = remainder[1:] + [0]
        remainder = [a ^ _mul(b, factor, 0x11d) for a, b in zip(remainder, divisor[1:])]
    return remainder


def qr_matrix(text):
    payload = text.encode('utf-8')
    # (data codewords, error correction codewords per block, blocks)
    layouts = [(19, 7, 1), (34, 10, 1), (55, 15, 1), (80, 20, 1), (108, 26, 1), (136, 18, 2)]
    for version, (capacity, ecc, count) in enumerate(layouts, 1):
        if 12 + len(payload) * 8 <= capacity * 8:
            break
    else:
        raise ValueError('QR login payload exceeds 134 bytes')
    bits = [0, 1, 0, 0] + [(len(payload) >> i) & 1 for i in range(7, -1, -1)]
    bits += [(byte >> i) & 1 for byte in payload for i in range(7, -1, -1)]
    bits += [0] * min(4, capacity * 8 - len(bits))
    bits += [0] * (-len(bits) % 8)
    data = [sum(bits[i + j] << (7 - j) for j in range(8)) for i in range(0, len(bits), 8)]
    pad = (0xec, 0x11)
    while len(data) < capacity:
        data.append(pad[0])
        pad = pad[::-1]
    block_size = capacity // count
    blocks = [data[i:i + block_size] for i in range(0, capacity, block_size)]
    checks = [_rs_remainder(block, ecc) for block in blocks]
    codewords = [value for group in (blocks, checks) for column in zip(*group) for value in column]
    stream = [(value >> bit) & 1 for value in codewords for bit in range(7, -1, -1)]
    size = version * 4 + 17
    matrix = [[None] * size for _ in range(size)]
    for left, top in ((0, 0), (size - 7, 0), (0, size - 7)):
        for dy in range(-1, 8):
            for dx in range(-1, 8):
                x, y = left + dx, top + dy
                if 0 <= x < size and 0 <= y < size:
                    matrix[y][x] = (0 <= dx <= 6 and 0 <= dy <= 6 and
                                    (dx in (0, 6) or dy in (0, 6) or (2 <= dx <= 4 and 2 <= dy <= 4)))
    for i in range(8, size - 8):
        matrix[6][i] = matrix[i][6] = i % 2 == 0
    if version > 1:
        center = size - 7
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                matrix[center + dy][center + dx] = max(abs(dx), abs(dy)) != 1
    # Format information: error correction L, mask 0, BCH encoded and XOR masked.
    format_bits = 0x77c4
    first = [(8, i) for i in range(6)] + [(8, 7), (8, 8), (7, 8)] + [(14 - i, 8) for i in range(9, 15)]
    second = [(size - 1 - i, 8) for i in range(8)] + [(8, size - 15 + i) for i in range(8, 15)]
    for coordinates in (first, second):
        for i, (x, y) in enumerate(coordinates):
            matrix[y][x] = bool((format_bits >> i) & 1)
    matrix[size - 8][8] = True
    index, right, upwards = 0, size - 1, True
    while right >= 1:
        if right == 6:
            right = 5
        for y in (range(size - 1, -1, -1) if upwards else range(size)):
            for x in (right, right - 1):
                if matrix[y][x] is None:
                    bit = stream[index] if index < len(stream) else 0
                    matrix[y][x] = bool(bit ^ ((x + y) % 2 == 0))
                    index += 1
        upwards = not upwards
        right -= 2
    return matrix


def print_qr(text, out):
    matrix = qr_matrix(text)
    size = len(matrix) + 8
    rows = [[False] * size for _ in range(4)]
    rows += [[False] * 4 + row + [False] * 4 for row in matrix]
    rows += [[False] * size for _ in range(5)]
    # Explicit white background: scannable on both light and dark terminals.
    for y in range(0, len(rows) - 1, 2):
        line = ''.join((' ', '▄', '▀', '█')[(int(top) << 1) | int(bottom)]
                       for top, bottom in zip(rows[y], rows[y + 1]))
        print('\033[30;47m' + line + '\033[0m', file=out)
