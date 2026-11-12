import Foundation
import CryptoKit
import Security

enum TuyaCrypto {
    static func hex<D: Sequence>(_ data: D) -> String where D.Element == UInt8 { data.map { String(format: "%02x", $0) }.joined() }
    static func md5(_ text: String) -> String { hex(Insecure.MD5.hash(data: Data(text.utf8))) }
    static let signFields: Set<String> = ["a","v","lat","lon","lang","deviceId","imei","imsi","appVersion","ttid","isH5","h5Token","os","clientId","postData","time","requestId","n4h5","sid","sp","et"]
    static func signature(_ fields: [String: String]) -> String {
        let key = "0F:C3:61:99:9C:C0:C3:5B:A8:AC:A5:7D:AA:55:93:A2:0C:F5:57:27:70:2E:A8:5A:D7:B3:22:89:49:F8:88:FE_jfg5rs5kkmrj5mxahugvucrsvw43t48x_r3me7ghmxjevrvnpemwmhw3fxtacphyg"
        let message = fields.keys.sorted().filter { signFields.contains($0) && fields[$0] != "" }.map { key in
            var value = fields[key]!
            if key == "postData" {
                let hash = Array(md5(value))
                value = String(hash[8..<16] + hash[0..<8] + hash[24..<32] + hash[16..<24])
            }
            return key + "=" + value
        }.joined(separator: "||")
        return hex(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8))))
    }
    private static func der(_ tag: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        let length = bytes.count < 128 ? [UInt8(bytes.count)] : bytes.count < 256 ? [0x81, UInt8(bytes.count)] : [0x82, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]
        return [tag] + length + bytes
    }
    static func decimalBytes(_ string: String) throws -> [UInt8] {
        guard !string.isEmpty, string.count < 2500, string.utf8.allSatisfy({ (48...57).contains($0) }) else { throw TuyaError.message("Invalid Tuya RSA key.") }
        var bytes: [UInt8] = [0]
        for digit in string.utf8 {
            var carry = Int(digit - 48)
            for i in bytes.indices.reversed() { let n = Int(bytes[i]) * 10 + carry; bytes[i] = UInt8(n & 255); carry = n >> 8 }
            if carry > 0 { bytes.insert(UInt8(carry), at: 0) }
        }
        return bytes
    }
    static func password(_ digest: String, token: [String: Any]) throws -> String {
        guard digest.count == 32, digest.allSatisfy({ $0.isHexDigit }), let raw = (token["pbKey"] ?? token["publicKey"]) as? String else { throw TuyaError.message("Invalid Tuya login key.") }
        var encoded: Data
        let clean = raw.replacingOccurrences(of: "-----[^-]+-----|\\s", with: "", options: .regularExpression)
        if token["pbKey"] == nil, !raw.contains("BEGIN"), let exponent = CloudValue.number(token["exponent"]) {
            var modulus = clean.utf8.allSatisfy({ (48...57).contains($0) }) ? try decimalBytes(clean) : Array(Data(base64Encoded: clean) ?? Data())
            guard (128...1024).contains(modulus.count), exponent >= 3, exponent <= Double(UInt32.max), Int(exponent) % 2 == 1 else { throw TuyaError.message("Invalid Tuya RSA key.") }
            var e = try decimalBytes(String(Int(exponent)))
            if modulus.first! >= 128 { modulus.insert(0, at: 0) }
            if e.first! >= 128 { e.insert(0, at: 0) }
            encoded = Data(der(0x30, der(2, modulus) + der(2, e)))
        } else {
            guard let data = Data(base64Encoded: clean) else { throw TuyaError.message("Invalid Tuya RSA key.") }
            encoded = data
            // Strip SubjectPublicKeyInfo when the server wraps the RSA key.
            func item(_ data: [UInt8], _ offset: inout Int) throws -> (UInt8, [UInt8]) {
                guard offset + 2 <= data.count else { throw TuyaError.message("Invalid Tuya RSA key.") }
                let tag = data[offset]; var length = Int(data[offset + 1]); offset += 2
                if length & 128 != 0 {
                    let count = length & 127; length = 0
                    guard (1...4).contains(count), offset + count <= data.count else { throw TuyaError.message("Invalid Tuya RSA key.") }
                    for _ in 0..<count { length = length * 256 + Int(data[offset]); offset += 1 }
                }
                guard length <= data.count - offset else { throw TuyaError.message("Invalid Tuya RSA key.") }
                defer { offset += length }
                return (tag, Array(data[offset..<offset + length]))
            }
            var offset = 0
            let outer = try item(Array(data), &offset)
            offset = 0
            let first = try item(outer.1, &offset)
            if first.0 == 0x30 {
                let bits = try item(outer.1, &offset)
                guard bits.0 == 3, bits.1.first == 0 else { throw TuyaError.message("Invalid Tuya RSA key.") }
                encoded = Data(bits.1.dropFirst())
            }
        }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(encoded as CFData, attrs as CFDictionary, nil),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(digest.utf8) as CFData, nil) else {
            throw TuyaError.message("Could not encrypt the Tuya login.")
        }
        return hex(encrypted as Data)
    }
}
