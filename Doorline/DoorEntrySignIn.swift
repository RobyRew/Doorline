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
final class EliotDirectory: DoorEntryDirectory {
    func plants(email: String, password: String) async -> Result<[DoorEntryPlant], DoorEntrySignInFailure> {
        do {
            let token = try await accessToken(email: email, password: password)
            let document = try await plantDocument(token: token)
            let plants = DoorEntryAccountDocument.plants(in: document)
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

    private func plantDocument(token: String) async throws -> Data {
        var statuses: [String] = []
        for url in Self.plantURLs {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if url.host?.contains("developer.legrand.com") == true {
                request.setValue(Self.subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status), !DoorEntryAccountDocument.plants(in: data).isEmpty {
                return data
            }
            statuses.append("\(url.host ?? "") \(status)")
        }
        throw DoorEntrySignInFailure.unreachable("Signed in, but the plant list did not come back (\(statuses.joined(separator: ", "))).")
    }

    private static let subscriptionKey = "3c48aa3992754ac28dab36742d5b151a"
    private static let plantURLs = [
        URL(string: "https://www.myhomeweb.com/plants")!,
        URL(string: "https://api.developer.legrand.com/plants")!,
        URL(string: "https://api.developer.legrand.com/bticino/v1.0/plants")!,
        URL(string: "https://api.developer.legrand.com/doorentry/v1.0/plants")!,
    ]
}
