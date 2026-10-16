import Foundation
import Security

/// PEM material for the SIP mutual-TLS registration.
///
/// Door Entry stores the same three artifacts in the Keychain (`DoorEliot_IOS_client_cert`,
/// `DoorEliot_IOS_private`, `DoorEliot_IOS_root_ca`) and refuses to register without a valid
/// certificate. Doorline keeps its own Keychain entries; provisioning (keypair + CSR +
/// `/users/cert/signcert`) is layered on top of this store.
struct SipCertificateMaterial: Equatable, Sendable {
    var clientCert: String
    var privateKey: String
    var rootCA: String
}

@MainActor
final class SipCertificateStore {
    static let shared = SipCertificateStore()

    private let clientCertTag = "doorline.sip.client-cert"
    private let privateKeyTag = "doorline.sip.private-key"
    private let rootCATag = "doorline.sip.root-ca"

    var material: SipCertificateMaterial? {
        guard let clientCert = read(clientCertTag),
              let privateKey = read(privateKeyTag),
              let rootCA = read(rootCATag) else {
            return nil
        }
        return SipCertificateMaterial(clientCert: clientCert, privateKey: privateKey, rootCA: rootCA)
    }

    func save(_ material: SipCertificateMaterial) {
        write(material.clientCert, for: clientCertTag)
        write(material.privateKey, for: privateKeyTag)
        write(material.rootCA, for: rootCATag)
    }

    func clear() {
        for tag in [clientCertTag, privateKeyTag, rootCATag] {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: tag] as CFDictionary)
        }
    }

    private func read(_ tag: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, for tag: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tag,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
