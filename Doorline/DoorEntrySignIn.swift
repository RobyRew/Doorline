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
        let redirect = EliotRedirect()
        let session = URLSession(configuration: .ephemeral, delegate: redirect, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let authorize = Self.authorizeURL()
        var pageRequest = URLRequest(url: authorize, timeoutInterval: 30)
        pageRequest.setValue(Self.browser, forHTTPHeaderField: "User-Agent")
        let (pageData, _) = try await session.data(for: pageRequest)
        let html = String(decoding: pageData, as: UTF8.self)
        let settings = try Self.pageSettings(in: html)
        var submit = URLRequest(url: Self.selfAssertedURL(transId: settings.transId), timeoutInterval: 30)
        submit.httpMethod = "POST"
        submit.setValue(Self.browser, forHTTPHeaderField: "User-Agent")
        submit.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        submit.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        submit.setValue(settings.csrf, forHTTPHeaderField: "X-CSRF-TOKEN")
        submit.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        submit.setValue(authorize.absoluteString, forHTTPHeaderField: "Referer")
        submit.httpBody = Self.form([
            "request_type": "RESPONSE",
            "logonIdentifier": email,
            "password": password,
        ])
        let (asserted, _) = try await session.data(for: submit)
        if let failure = EliotSelfAsserted.failure(in: asserted) {
            throw failure
        }
        var confirm = URLRequest(url: Self.confirmedURL(csrf: settings.csrf, transId: settings.transId), timeoutInterval: 30)
        confirm.setValue(Self.browser, forHTTPHeaderField: "User-Agent")
        confirm.setValue(authorize.absoluteString, forHTTPHeaderField: "Referer")
        _ = try? await session.data(for: confirm)
        guard let callback = redirect.stopped, let code = Self.code(in: callback) else {
            throw DoorEntrySignInFailure.unreachable(Self.callbackError(redirect.stopped) ?? "Eliot did not return a sign-in code.")
        }
        var tokenRequest = URLRequest(url: Self.tokenURL, timeoutInterval: 30)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        tokenRequest.httpBody = Self.form([
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "scope": Self.scope,
            "code": code,
            "redirect_uri": Self.redirect,
        ])
        let (tokenData, tokenResponse) = try await session.data(for: tokenRequest)
        if let json = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
           let token = json["access_token"] as? String, !token.isEmpty {
            return token
        }
        let status = (tokenResponse as? HTTPURLResponse)?.statusCode ?? 0
        throw DoorEntrySignInFailure.unreachable("Eliot did not return an access token (\(status)).")
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

    private static func pageSettings(in html: String) throws -> (csrf: String, transId: String) {
        guard let start = html.range(of: "var SETTINGS = "),
              let end = html.range(of: "};", range: start.upperBound..<html.endIndex) else {
            throw DoorEntrySignInFailure.unreachable("Eliot's sign-in page had no session.")
        }
        let json = html[start.upperBound..<html.index(after: end.lowerBound)]
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let csrf = object["csrf"] as? String,
              let transId = object["transId"] as? String else {
            throw DoorEntrySignInFailure.unreachable("Eliot's sign-in page had no session.")
        }
        return (csrf, transId)
    }

    private static func code(in url: URL) -> String? {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = parts?.queryItems ?? []
        let fragment = parts?.fragment.map { item -> [URLQueryItem] in
            URLComponents(string: "https://doorline.invalid/?\(item)")?.queryItems ?? []
        } ?? []
        return (query + fragment).first { $0.name == "code" }?.value
    }

    private static func callbackError(_ url: URL?) -> String? {
        guard let url else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == "error_description" }?.value?.removingPercentEncoding
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let text = fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    private static func authorizeURL() -> URL {
        var parts = URLComponents(string: "https://login.eliotbylegrand.com/EliotClouduamprd.onmicrosoft.com/oauth2/v2.0/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "p", value: policy),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "nonce", value: "defaultNonce"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "prompt", value: "login"),
        ]
        return parts.url!
    }

    private static func selfAssertedURL(transId: String) -> URL {
        var parts = URLComponents(string: "https://login.eliotbylegrand.com/EliotClouduamprd.onmicrosoft.com/\(policy)/SelfAsserted")!
        parts.queryItems = [
            URLQueryItem(name: "tx", value: transId),
            URLQueryItem(name: "p", value: policy),
        ]
        return parts.url!
    }

    private static func confirmedURL(csrf: String, transId: String) -> URL {
        var parts = URLComponents(string: "https://login.eliotbylegrand.com/EliotClouduamprd.onmicrosoft.com/\(policy)/api/CombinedSigninAndSignup/confirmed")!
        parts.queryItems = [
            URLQueryItem(name: "rememberMe", value: "false"),
            URLQueryItem(name: "csrf_token", value: csrf),
            URLQueryItem(name: "tx", value: transId),
            URLQueryItem(name: "p", value: policy),
        ]
        return parts.url!
    }

    // Values carried by the Door Entry iOS app for the production Eliot web sign-in.
    private static let clientID = "68391b24-f2fd-44c7-95b3-e04130d4a287"
    private static let policy = "B2C_1_BS_DoorEntry_App_iOS-SignUpOrSignIn"
    private static let scope = "openid offline_access https://EliotClouduamprd.onmicrosoft.com/security/access.full"
    private static let redirect = "com.legrandgroup.c300x://oauth2redirect"
    private static let subscriptionKey = "3c48aa3992754ac28dab36742d5b151a"
    private static let browser = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let tokenURL = URL(string: "https://login.eliotbylegrand.com/EliotClouduamprd.onmicrosoft.com/oauth2/v2.0/token?p=\(policy)")!
    private static let plantURLs = [
        URL(string: "https://www.myhomeweb.com/plants")!,
        URL(string: "https://api.developer.legrand.com/plants")!,
        URL(string: "https://api.developer.legrand.com/bticino/v1.0/plants")!,
        URL(string: "https://api.developer.legrand.com/doorentry/v1.0/plants")!,
    ]
}

/// Stops URLSession from trying to open the app redirect and keeps the URL that carries the code.
private final class EliotRedirect: NSObject, URLSessionTaskDelegate {
    var stopped: URL?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        if let url = request.url, url.absoluteString.hasPrefix("com.legrandgroup.c300x:") {
            stopped = url
            return nil
        }
        return request
    }
}
