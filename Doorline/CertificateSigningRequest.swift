import Foundation
import Security

/// A PKCS#10 certificate signing request for the SIP mutual-TLS certificate.
///
/// Door Entry generates an RSA keypair and POSTs the CSR to the portal's
/// `/users/cert/signcert`; the signed certificate is what the Flexisip registration
/// presents as a client certificate. The DER is assembled by hand because the Security
/// framework does not build CSRs.
struct CertificateSigningRequest {
    let pem: String
    let privateKeyPEM: String

    /// Builds a `sha256WithRSAEncryption` CSR for `commonName` over a fresh 2048-bit key.
    static func make(commonName: String) throws -> CertificateSigningRequest {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil) else {
            throw SigningError.keyGenerationFailed
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SigningError.keyGenerationFailed
        }
        guard let publicDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw SigningError.keyGenerationFailed
        }

        let writer = DERWriter()
        let info = certificationRequestInfo(subject: commonName, publicKeyDER: publicDER, writer: writer)
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            info as CFData,
            nil
        ) as Data? else {
            throw SigningError.signingFailed
        }

        let request = writer.sequence(
            info,
            writer.sequence(writer.oid(.sha256WithRSAEncryption), writer.null),
            writer.bitString(signature)
        )
        return CertificateSigningRequest(
            pem: Self.pem(request, label: "CERTIFICATE REQUEST"),
            privateKeyPEM: Self.pem(try privateKeyPEMData(privateKey), label: "PRIVATE KEY")
        )
    }

    private static func certificationRequestInfo(subject: String, publicKeyDER: Data, writer: DERWriter) -> Data {
        let name = writer.sequence(
            writer.set(writer.sequence(writer.oid(.commonName), writer.utf8(subject)))
        )
        let subjectPublicKeyInfo = writer.sequence(
            writer.sequence(writer.oid(.rsaEncryption), writer.null),
            writer.bitString(publicKeyDER)
        )
        return writer.sequence(
            writer.integer(Data([0x00])),
            name,
            subjectPublicKeyInfo,
            writer.raw(Data([0xA0, 0x00]))
        )
    }

    private static func privateKeyPEMData(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw error?.takeRetainedValue() ?? SigningError.keyGenerationFailed
        }
        // `SecKeyCopyExternalRepresentation` already returns the PKCS#1 RSAPrivateKey
        // (RFC 3447 A.1.2): SEQUENCE of version, modulus, exponents and CRT primes.
        guard data.first == 0x30 else { throw SigningError.keyGenerationFailed }
        let integers = data.integerContents
        guard integers.count == 9 else { throw SigningError.keyGenerationFailed }
        let writer = DERWriter()
        return writer.sequence(integers.map { writer.integer($0) })
    }

    private static func pem(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)-----END \(label)-----\n"
    }

    enum SigningError: Error {
        case keyGenerationFailed
        case signingFailed
    }
}

/// DER length-tagged writer for the CSR structures.
private final class DERWriter {
    func integer(_ value: Data) -> Data {
        // Fresh contiguous buffer: `value` may be an inline slice of a larger Data,
        // and mutating those traps in Data.replaceSubrange.
        var content = Data(value)
        while content.first == 0x00 { content.removeFirst() }
        // A stripped-to-empty value is zero; DER encodes it as a single 0x00, never empty.
        if content.isEmpty { content = Data([0x00]) }
        if let first = content.first, first >= 0x80 {
            var padded = Data([0x00])
            padded.append(content)
            content = padded
        }
        return tagged(0x02, content)
    }

    func oid(_ oid: OID) -> Data {
        let first = oid.first * 40 + oid.second
        var encoded = [UInt8(first)]
        for value in oid.rest { encoded.append(contentsOf: base128(value)) }
        return tagged(0x06, Data(encoded))
    }

    var null: Data { Data([0x05, 0x00]) }

    func utf8(_ string: String) -> Data {
        tagged(0x0C, Data(string.utf8))
    }

    /// Wraps the concatenation of `parts` in a SEQUENCE tag.
    func sequence(_ parts: Data...) -> Data { tagged(0x30, Self.concatenate(parts)) }

    /// Wraps the concatenation of `parts` in a SEQUENCE tag.
    func sequence(_ parts: [Data]) -> Data { tagged(0x30, Self.concatenate(parts)) }

    /// Wraps the concatenation of `parts` in a SET tag.
    func set(_ parts: Data...) -> Data { tagged(0x31, Self.concatenate(parts)) }

    func raw(_ data: Data) -> Data { data }

    private static func concatenate(_ parts: [Data]) -> Data {
        var result = Data()
        for part in parts { result.append(part) }
        return result
    }

    func bitString(_ content: Data) -> Data {
        // BIT STRING with zero unused bits.
        var wrapped = Data([0x00])
        wrapped.append(content)
        return tagged(0x03, wrapped)
    }

    private func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        result.append(length(content.count))
        result.append(content)
        return result
    }

    private func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private func base128(_ value: Int) -> [UInt8] {
        var stack: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            stack.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return stack
    }

    struct OID {
        let first: Int
        let second: Int
        let rest: [Int]

        static let commonName = OID(first: 2, second: 5, rest: [4, 3])
        static let rsaEncryption = OID(first: 1, second: 2, rest: [840, 113549, 1, 1, 1])
        static let sha256WithRSAEncryption = OID(first: 1, second: 2, rest: [840, 113549, 1, 1, 11])
    }
}

/// Slices of the PKCS#1 RSAPrivateKey structure `SecKeyCopyExternalRepresentation` returns.
private extension Data {
    /// The INTEGER contents of a DER SEQUENCE (the first tag and length are skipped).
    /// Leading zero padding is stripped so the values can be re-encoded.
    var integerContents: [Data] {
        var offset = startIndex
        guard self[offset] == 0x30 else { return [] }
        offset = index(after: offset)
        guard offset < endIndex else { return [] }
        let first = self[offset]
        offset = index(after: offset)
        let total: Int
        if first < 0x80 {
            total = Int(first)
        } else {
            let byteCount = Int(first & 0x7F)
            guard byteCount <= 8, distance(from: offset, to: endIndex) >= byteCount else { return [] }
            total = subdata(in: offset..<index(offset, offsetBy: byteCount)).reduce(0) { $0 << 8 | Int($1) }
            offset = index(offset, offsetBy: byteCount)
        }
        let limit = index(offset, offsetBy: total, limitedBy: endIndex) ?? endIndex
        var values: [Data] = []
        while offset < limit {
            guard self[offset] == 0x02 else { return [] }
            offset = index(after: offset)
            guard offset < limit else { return [] }
            let lengthByte = self[offset]
            offset = index(after: offset)
            let length: Int
            if lengthByte < 0x80 {
                length = Int(lengthByte)
            } else {
                let byteCount = Int(lengthByte & 0x7F)
                guard byteCount <= 8, distance(from: offset, to: limit) >= byteCount else { return [] }
                length = subdata(in: offset..<index(offset, offsetBy: byteCount)).reduce(0) { $0 << 8 | Int($1) }
                offset = index(offset, offsetBy: byteCount)
            }
            let contentEnd = index(offset, offsetBy: length, limitedBy: limit) ?? limit
            var content = subdata(in: offset..<contentEnd)
            while content.first == 0x00 { content.removeFirst() }
            values.append(content)
            offset = contentEnd
        }
        return values
    }
}
