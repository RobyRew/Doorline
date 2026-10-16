import Foundation

enum CertificateProvisioningFailure: Error, Equatable {
    case unreachable(String)
    case malformed(String)

    var message: String {
        switch self {
        case .unreachable(let reason), .malformed(let reason): reason
        }
    }
}

/// Exposes the Eliot bearer token the directory obtained at sign-in.
@MainActor
protocol PortalTokenProviding: AnyObject {
    var portalToken: String? { get }
}

/// Makes sure the SIP client certificate exists, signing one when it does not.
@MainActor
protocol SipCertificateProvisioning: AnyObject {
    func ensureMaterial(deviceName: String) async throws
}

/// Provisions the SIP client certificate the Door Entry way: generate a keypair and CSR,
/// POST the CSR to the portal's `/users/cert/signcert`, store the signed certificate with
/// the private key and CA in the Keychain for the linphone TLS handshake.
@MainActor
final class SipCertificateProvisioner {
    var host: String = "https://www.myhomeweb.com"
    var userAgent: String = "doorentryforc300x-ios-1.13.5"

    /// Returns the stored material, or signs a new one when the portal has none yet.
    func ensureMaterial(deviceName: String, token: String) async throws -> SipCertificateMaterial {
        if let material = SipCertificateStore.shared.material { return material }
        let request = try CertificateSigningRequest.make(commonName: "doorline-\(deviceName)")
        let signed = try await sign(request.pem, token: token)
        let material = SipCertificateMaterial(
            clientCert: signed.certificate,
            privateKey: request.privateKeyPEM,
            rootCA: signed.rootCA ?? signed.certificate
        )
        SipCertificateStore.shared.save(material)
        return material
    }

    /// POSTs the PEM CSR. The portal's response shape is not pinned by a schema; the
    /// certificate is read from the usual spellings and falls back to a raw PEM body.
    func sign(_ csrPEM: String, token: String) async throws -> (certificate: String, rootCA: String?) {
        guard let url = URL(string: "\(host)/eliot/users/cert/signcert") else {
            throw CertificateProvisioningFailure.unreachable("Certificate URL could not be built.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("C3X", forHTTPHeaderField: "PRJ_NAME")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(csrPEM.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CertificateProvisioningFailure.unreachable("Certificate signing answered HTTP \(status).")
        }
        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            throw CertificateProvisioningFailure.malformed("Certificate signing answered without a certificate.")
        }
        if body.contains("-----BEGIN CERTIFICATE-----") {
            return (body, nil)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CertificateProvisioningFailure.malformed("Certificate signing did not return a certificate.")
        }
        let certificate = (json["certificate"] as? String)
            ?? (json["cert"] as? String)
            ?? (json["certificatePem"] as? String)
            ?? (json["certPem"] as? String)
        guard let certificate, certificate.contains("-----BEGIN CERTIFICATE-----") else {
            throw CertificateProvisioningFailure.malformed("Certificate signing did not return a certificate.")
        }
        let rootCA = json["rootCa"] as? String ?? json["ca"] as? String
        return (certificate, rootCA)
    }
}
