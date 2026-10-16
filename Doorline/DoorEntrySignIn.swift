import Foundation

struct DoorEntryPlant: Equatable, Sendable {
    var plantID: String
    var gatewayID: String
    var name: String
}

enum DoorEntrySignInFailure: Error, Equatable {
    case invalidCredentials(String)
    case noPlant
    case unreachable(String)

    var message: String {
        switch self {
        case .invalidCredentials(let reason):
            reason
        case .noPlant:
            "That account has no Classe 300X on it."
        case .unreachable(let reason):
            reason
        }
    }
}

/// The JSON body the Eliot web sign-in page returns after the email and password are posted.
enum EliotSelfAsserted {
    static func failure(in data: Data) -> DoorEntrySignInFailure? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreachable("Eliot did not answer the sign-in form.")
        }
        let status = (json["status"] as? String) ?? String(describing: json["status"] ?? "")
        if status == "200" { return nil }
        let message = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = (message?.isEmpty == false) ? message! : "That email or password was not accepted."
        let code = json["errorCode"] as? String ?? ""
        if code == "AADB2C90054" || status == "400" {
            return .invalidCredentials(reason)
        }
        return .unreachable(reason)
    }
}

@MainActor
protocol DoorEntryDirectory: AnyObject {
    func plants(email: String, password: String) async -> Result<[DoorEntryPlant], DoorEntrySignInFailure>
}

/// Reads the plant list Eliot returns after a Door Entry sign-in.
enum DoorEntryAccountDocument {
    static func plants(in data: Data) -> [DoorEntryPlant] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var found: [DoorEntryPlant] = []
        collect(json, into: &found)
        var unique: [DoorEntryPlant] = []
        for plant in found where !unique.contains(where: { $0.plantID == plant.plantID && $0.gatewayID == plant.gatewayID }) {
            unique.append(plant)
        }
        return unique
    }

    static func catalogPlants(in data: Data) -> [(id: String, name: String)] {
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [Any]
        if let array = json as? [Any] {
            rows = array
        } else if let object = json as? [String: Any] {
            rows = (object["plants"] as? [Any]) ?? (object["value"] as? [Any]) ?? []
        } else {
            rows = []
        }
        return rows.compactMap { row in
            guard let object = row as? [String: Any] else { return nil }
            let id = text(object, keys: ["id", "plantId", "plantID"]) ?? ""
            guard !id.isEmpty else { return nil }
            let name = text(object, keys: ["name", "plantName"]) ?? "Home"
            return (id, name)
        }
    }

    /// `www.myhomeweb.com/eliot/plants` with header `PRJ_NAME: C3X`.
    /// An empty service-catalog body was reported as no device; this portal answers 401
    /// `User not logged or session expired` when the Eliot token is not a portal session.
    static func portalPlants(status: Int, warning: String, body: Data) -> Result<[DoorEntryPlant], DoorEntrySignInFailure> {
        if status == 204 || (status == 200 && body.isEmpty) {
            return .failure(.noPlant)
        }
        if !(200..<300).contains(status) {
            let reason = warning.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = reason.isEmpty ? "HTTP \(status)" : reason
            return .failure(.unreachable("Signed in to Eliot. Door Entry's portal answered \(detail)."))
        }
        let parsed = plants(in: body)
        if !parsed.isEmpty { return .success(parsed) }
        let listed = catalogPlants(in: body)
        if listed.isEmpty { return .failure(.noPlant) }
        let gateway = gatewayID(in: body)
        return .success(listed.map {
            DoorEntryPlant(plantID: $0.id, gatewayID: gateway ?? $0.id, name: $0.name)
        })
    }

    static func gatewayID(in data: Data) -> String? {
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: String?
        func walk(_ value: Any) {
            if found != nil { return }
            if let array = value as? [Any] {
                for item in array { walk(item) }
                return
            }
            guard let object = value as? [String: Any] else { return }
            let kind = (text(object, keys: ["device", "type", "hw_type"]) ?? "").lowercased()
            if kind.contains("gateway"), let id = text(object, keys: ["id", "gatewayId", "gatewayID"]) {
                found = id
                return
            }
            for child in object.values { walk(child) }
        }
        walk(json)
        return found
    }

    private static func collect(_ value: Any, into found: inout [DoorEntryPlant]) {
        if let array = value as? [Any] {
            for item in array { collect(item, into: &found) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        if let plant = plant(from: object) {
            found.append(plant)
        }
        for child in object.values {
            collect(child, into: &found)
        }
    }

    private static func plant(from object: [String: Any]) -> DoorEntryPlant? {
        let hasGateway = object["gateways"] != nil || object["gateway"] != nil || object["gatewayId"] != nil || object["gatewayID"] != nil || object["plantId"] != nil || object["plantID"] != nil
        guard hasGateway else { return nil }
        let plantID = text(object, keys: ["plantId", "plantID", "id"])
        let gatewayID = text(object, keys: ["gatewayId", "gatewayID"]) ?? firstGateway(object["gateways"] ?? object["gateway"])
        guard let plantID, let gatewayID, !plantID.isEmpty, !gatewayID.isEmpty else { return nil }
        let name = text(object, keys: ["name", "plantName"]) ?? "Home"
        return DoorEntryPlant(plantID: plantID, gatewayID: gatewayID, name: name)
    }

    private static func firstGateway(_ value: Any?) -> String? {
        if let object = value as? [String: Any] {
            return text(object, keys: ["id", "gatewayId", "gatewayID"])
        }
        if let array = value as? [Any] {
            for item in array {
                if let id = firstGateway(item) { return id }
            }
        }
        return nil
    }

    private static func text(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = object[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = object[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }
}

/// Door Entry password sign-in. The iOS app posts the email and password to the Eliot password policy, then reads the plant list.
/// Eliot pages the Door Entry app opens for a new account and a forgotten password.
enum EliotAccountPage {
    static var register: URL { authorize(policy: "B2C_1_BS_DoorEntry_App_iOS-SignUpOrSignIn") }
    static var resetPassword: URL { authorize(policy: "B2C_1_BS_DoorEntry_App_iOS-password") }

    private static func authorize(policy: String) -> URL {
        var parts = URLComponents(string: "https://login.eliotbylegrand.com/EliotClouduamprd.onmicrosoft.com/oauth2/v2.0/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "p", value: policy),
            URLQueryItem(name: "client_id", value: "68391b24-f2fd-44c7-95b3-e04130d4a287"),
            URLQueryItem(name: "nonce", value: "defaultNonce"),
            URLQueryItem(name: "redirect_uri", value: "com.legrandgroup.c300x://oauth2redirect"),
            URLQueryItem(name: "scope", value: "openid offline_access https://EliotClouduamprd.onmicrosoft.com/security/access.full"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "prompt", value: "login"),
        ]
        return parts.url!
    }
}

@MainActor
final class EliotDirectory: DoorEntryDirectory, SipCredentials, PortalTokenProviding, SipCertificateProvisioning {
    private let provisioning: SipProvisioning
    private let certificateProvisioning: SipCertificateProvisioner
    private(set) var lastToken: String?

    init(
        provisioning: SipProvisioning = EliotSipProvisioning(),
        // Optional because default arguments evaluate outside this actor's isolation,
        // which a MainActor-isolated initializer call would not be allowed in.
        certificateProvisioning: SipCertificateProvisioner? = nil
    ) {
        self.provisioning = provisioning
        self.certificateProvisioning = certificateProvisioning ?? SipCertificateProvisioner()
    }

    var portalToken: String? { lastToken }

    func ensureMaterial(deviceName: String) async throws {
        guard let token = lastToken else {
            throw CertificateProvisioningFailure.unreachable("Sign in before provisioning the SIP certificate.")
        }
        _ = try await certificateProvisioning.ensureMaterial(deviceName: deviceName, token: token)
    }

    func plants(email: String, password: String) async -> Result<[DoorEntryPlant], DoorEntrySignInFailure> {
        do {
            let token = try await accessToken(email: email, password: password)
            lastToken = token
            let plants = try await plants(token: token)
            if plants.isEmpty { return .failure(.noPlant) }
            return .success(plants)
        } catch let failure as DoorEntrySignInFailure {
            return .failure(failure)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    private func accessToken(email: String, password: String) async throws -> String {
        try await EliotWebJourney(wire: URLSessionEliotWire()).submitSignIn(identifier: email, password: password)
    }

    /// Uses the token from the last sign-in to read the gateway's SIP account.
    func sipAccount(plantID: String, gatewayID: String) async throws -> SipAccount {
        guard let token = lastToken else {
            throw SipProvisioningFailure.unreachable("Sign in before provisioning the SIP account.")
        }
        return try await provisioning.sipAccount(plantID: plantID, gatewayID: gatewayID, token: token)
    }

    /// Door Entry 1.13.5 stores `prj_name` / `C3X`. The live list is `/eliot/plants`, not the service catalog.
    private func plants(token: String) async throws -> [DoorEntryPlant] {
        guard let url = URL(string: "https://www.myhomeweb.com/eliot/plants") else {
            throw DoorEntrySignInFailure.unreachable("Eliot plant URL could not be built.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("C3X", forHTTPHeaderField: "PRJ_NAME")
        request.setValue("doorentryforc300x-ios-1.13.5", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let warning = http?.value(forHTTPHeaderField: "Warning") ?? ""
        return try DoorEntryAccountDocument.portalPlants(status: status, warning: warning, body: data).get()
    }
}
