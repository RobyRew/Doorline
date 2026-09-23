import Foundation

struct DoorEntryPlant: Equatable, Sendable {
    var plantID: String
    var gatewayID: String
    var name: String
}

enum DoorEntrySignInFailure: Error, Equatable {
    case invalidCredentials
    case noPlant
    case unreachable(String)

    var message: String {
        switch self {
        case .invalidCredentials:
            "That email or password was not accepted."
        case .noPlant:
            "That account has no Classe 300X on it."
        case .unreachable(let reason):
            reason
        }
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
        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        let body = [
            "username": email,
            "password": password,
            "grant_type": "password",
            "scope": Self.scope,
            "client_id": Self.clientID,
            "response_type": "token id_token",
        ]
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let token = json["access_token"] as? String, !token.isEmpty {
                return token
            }
            let description = (json["error_description"] as? String) ?? ""
            let code = (json["error"] as? String) ?? ""
            if code == "invalid_grant" || description.contains("AADB2C90225") {
                throw DoorEntrySignInFailure.invalidCredentials
            }
            if !description.isEmpty {
                throw DoorEntrySignInFailure.unreachable(String(description.prefix(180)))
            }
        }
        if data.starts(with: Data("<!DOCTYPE".utf8)) || data.starts(with: Data("<html".utf8)) {
            throw DoorEntrySignInFailure.unreachable("Eliot returned its web sign-in page instead of a token.")
        }
        throw DoorEntrySignInFailure.unreachable("Eliot answered \(status).")
    }

    private func plantDocument(token: String) async throws -> Data {
        var request = URLRequest(url: Self.plantsURL, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw DoorEntrySignInFailure.invalidCredentials
        }
        if !(200..<300).contains(status) {
            throw DoorEntrySignInFailure.unreachable("The account list answered \(status).")
        }
        return data
    }

    // Password policy and client from the Door Entry iOS binary. The client id is the one Eliot registers for that policy.
    private static let clientID = "68391b24-f2fd-44c7-95b3-e04130d4a287"
    private static let scope = "openid offline_access https://EliotClouduamprd.onmicrosoft.com/security/access.full"
    private static let tokenURL = URL(string: "https://login.eliotbylegrand.com/EliotClouduamprd.onmicrosoft.com/oauth2/v2.0/token?p=B2C_1_BS_DoorEntry_App_iOS-password")!
    private static let plantsURL = URL(string: "https://www.myhomeweb.com/plants")!
}
