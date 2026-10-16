import XCTest
import Security
@testable import Doorline

final class CertificateSigningRequestTests: XCTestCase {
    func testCSRBuildsAnImportableKeyAndASignatureThePublicKeyVerifies() throws {
        let csr = try CertificateSigningRequest.make(commonName: "doorline-test")
        XCTAssertTrue(csr.pem.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))
        XCTAssertTrue(csr.privateKeyPEM.hasPrefix("-----BEGIN PRIVATE KEY-----"))

        let keyDER = try pemBody(csr.privateKeyPEM, label: "PRIVATE KEY")
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(
            keyDER as CFData,
            [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            ] as CFDictionary,
            &error
        ) else {
            return XCTFail("Private key PEM did not import: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            return XCTFail("Public key could not be derived")
        }

        let csrDER = try pemBody(csr.pem, label: "CERTIFICATE REQUEST")
        let parts = csrDER.derElements
        guard parts.count == 3 else {
            return XCTFail("CSR should be SEQUENCE of info, algorithm, signature; got \(parts.count) elements")
        }
        // `parts` keeps each element's tag and length; the signature is a BIT STRING
        // whose payload starts after tag, length and the unused-bits byte.
        let info = parts[0]
        guard let signature = parts[2].bitStringPayload, signature.first == 0x00 else {
            return XCTFail("Signature should be a BIT STRING with an unused-bits byte")
        }

        XCTAssertTrue(
            SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, info as CFData, signature.dropFirst() as CFData, nil),
            "The CSR signature should verify against the public key"
        )
        XCTAssertTrue(String(decoding: info, as: UTF8.self).contains("doorline-test"), "The subject CN should be in the request info")
    }

    private func pemBody(_ pem: String, label: String) throws -> Data {
        let begin = "-----BEGIN \(label)-----\n"
        let end = "-----END \(label)-----\n"
        guard pem.hasPrefix(begin), pem.hasSuffix(end) else {
            throw TestFailure.malformedPEM
        }
        let body = pem.dropFirst(begin.count).dropLast(end.count).replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: body) else { throw TestFailure.malformedPEM }
        return data
    }

    enum TestFailure: Error { case malformedPEM }
}

/// Reads the children of a DER SEQUENCE (definite lengths only), each with its
/// tag and length kept.
private extension Data {
    var derElements: [Data] {
        var offset = startIndex
        guard first == 0x30 else { return [] }
        offset = index(after: offset)
        guard offset < endIndex else { return [] }
        let lengthByte = self[offset]
        offset = index(after: offset)
        let total: Int
        if lengthByte < 0x80 {
            total = Int(lengthByte)
        } else {
            let count = Int(lengthByte & 0x7F)
            guard distance(from: offset, to: endIndex) >= count else { return [] }
            total = subdata(in: offset..<index(offset, offsetBy: count)).reduce(0) { $0 << 8 | Int($1) }
            offset = index(offset, offsetBy: count)
        }
        let limit = index(offset, offsetBy: total, limitedBy: endIndex) ?? endIndex
        var elements: [Data] = []
        while offset < limit {
            let elementStart = offset
            offset = index(after: offset)
            guard offset < limit else { return [] }
            let lengthByte = self[offset]
            offset = index(after: offset)
            let length: Int
            if lengthByte < 0x80 {
                length = Int(lengthByte)
            } else {
                let count = Int(lengthByte & 0x7F)
                guard distance(from: offset, to: limit) >= count else { return [] }
                length = subdata(in: offset..<index(offset, offsetBy: count)).reduce(0) { $0 << 8 | Int($1) }
                offset = index(offset, offsetBy: count)
            }
            let elementEnd = index(offset, offsetBy: length, limitedBy: limit) ?? limit
            elements.append(subdata(in: elementStart..<elementEnd))
            offset = elementEnd
        }
        return elements
    }

    /// The payload of a DER BIT STRING element (after tag, length and the unused-bits byte).
    var bitStringPayload: Data? {
        guard first == 0x03, count > 2 else { return nil }
        var offset = index(after: startIndex)
        let lengthByte = self[offset]
        offset = index(after: offset)
        let length: Int
        if lengthByte < 0x80 {
            length = Int(lengthByte)
        } else {
            let count = Int(lengthByte & 0x7F)
            guard distance(from: offset, to: endIndex) >= count else { return nil }
            length = subdata(in: offset..<index(offset, offsetBy: count)).reduce(0) { $0 << 8 | Int($1) }
            offset = index(offset, offsetBy: count)
        }
        let contentEnd = index(offset, offsetBy: length, limitedBy: endIndex) ?? endIndex
        let content = subdata(in: offset..<contentEnd)
        // First content byte is the unused-bits count; the signature follows.
        guard content.count > 1 else { return nil }
        return content
    }
}
