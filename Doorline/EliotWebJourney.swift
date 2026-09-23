import Foundation

/// `encodeURIComponent` and the POST bodies from the Eliot page scripts.
enum EliotPageScript {
    static func encodeURIComponent(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Combined sign-in script: `request_type` first, then the two `SA_FIELDS` ids.
    static func signInBody(identifier: String, password: String) -> String {
        "request_type=RESPONSE&logonIdentifier=\(encodeURIComponent(trim(identifier)))&password=\(encodeURIComponent(trim(password)))"
    }

    /// Self-asserted send-code script, including the leading `&`.
    static func verificationBody(claimId: String, claimValue: String) -> String {
        "&request_type=VERIFICATION_REQUEST&claim_id=\(encodeURIComponent(claimId))&claim_value=\(encodeURIComponent(trim(claimValue)))"
    }

    /// Self-asserted verify-code script. `user_input` is trimmed.
    static func validationBody(claimId: String, claimValue: String, userInput: String) -> String {
        "&request_type=VALIDATION_REQUEST&claim_id=\(encodeURIComponent(claimId))&claim_value=\(encodeURIComponent(trim(claimValue)))&user_input=\(encodeURIComponent(trim(userInput)))"
    }

    /// `collectData` order is supplied by the caller. `request_type=RESPONSE` is appended.
    static func responseBody(_ claims: [(id: String, value: String)], trimPasswords: Bool) -> String {
        let pairs = claims.map { claim -> String in
            let isPassword = claim.id.lowercased().contains("password")
            let value = (!isPassword || trimPasswords) ? trim(claim.value) : claim.value
            return "\(encodeURIComponent(claim.id))=\(encodeURIComponent(value))"
        }
        return pairs.joined(separator: "&") + "&request_type=RESPONSE"
    }
}

struct EliotField: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text
        case email
        case password
        case checkbox
        case menu
    }

    var id: String
    var kind: Kind
    var required: Bool
    var verify: Bool
    var pattern: String
    var options: [(value: String, label: String)]

    static func == (lhs: EliotField, rhs: EliotField) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.required == rhs.required && lhs.verify == rhs.verify && lhs.pattern == rhs.pattern && lhs.options.elementsEqual(rhs.options, by: { $0.value == $1.value && $0.label == $1.label })
    }
}

struct EliotParsedPage: Equatable, Sendable {
    var api: String
    var tenant: String
    var policy: String
    var csrf: String
    var transId: String
    var trimPasswords: Bool
    var fields: [EliotField]
}

enum EliotPageDocument {
    static func parse(_ html: String) -> EliotParsedPage? {
        guard let settings = object(named: "var SETTINGS = ", in: html),
              let fields = object(named: "var SA_FIELDS = ", in: html),
              let hosts = settings["hosts"] as? [String: Any],
              let tenant = hosts["tenant"] as? String,
              let policy = hosts["policy"] as? String,
              let csrf = settings["csrf"] as? String,
              let transId = settings["transId"] as? String,
              let api = settings["api"] as? String,
              let attributes = fields["AttributeFields"] as? [[String: Any]] else {
            return nil
        }
        return EliotParsedPage(
            api: api,
            tenant: tenant,
            policy: policy,
            csrf: csrf,
            transId: transId,
            trimPasswords: (settings["trimSpacesInPassword"] as? Bool) ?? true,
            fields: attributes.compactMap(field)
        )
    }

    private static func field(_ raw: [String: Any]) -> EliotField? {
        guard let id = raw["ID"] as? String else { return nil }
        let input = (raw["UX_INPUT_TYPE"] as? String) ?? ""
        let kind: EliotField.Kind
        switch input {
        case "Password": kind = .password
        case "EmailBox": kind = .email
        case "DropdownSingleSelect": kind = .menu
        case "CheckboxMultiSelect": kind = .checkbox
        default: kind = .text
        }
        let options = (raw["OPTIONS"] as? [[String: Any]] ?? []).compactMap { option -> (String, String)? in
            guard let value = option["VAL"] as? String else { return nil }
            return (value, option["DISP"] as? String ?? value)
        }
        return EliotField(
            id: id,
            kind: kind,
            required: (raw["IS_REQ"] as? Bool) ?? false,
            verify: (raw["VERIFY"] as? Bool) ?? false,
            pattern: raw["PAT"] as? String ?? "",
            options: options
        )
    }

    private static func object(named marker: String, in html: String) -> [String: Any]? {
        guard let start = html.range(of: marker),
              let end = html.range(of: "};", range: start.upperBound..<html.endIndex) else {
            return nil
        }
        let json = html[start.upperBound..<html.index(after: end.lowerBound)]
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

enum EliotPasswordRules {
    static let mismatch = "The password entry fields do not match. Please enter the same password in both fields and try again."

    /// Nil when `newPassword` matches `pattern` and `reenterPassword` equals it.
    static func rejection(newPassword: String, reenterPassword: String, pattern: String) -> String? {
        if newPassword != reenterPassword { return mismatch }
        guard !pattern.isEmpty else { return nil }
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return "The password does not match the page rules."
        }
        let range = NSRange(newPassword.startIndex..<newPassword.endIndex, in: newPassword)
        if expression.firstMatch(in: newPassword, range: range) == nil {
            return "The password does not match the page rules."
        }
        return nil
    }
}

enum EliotEndpoints {
    static let origin = "https://login.eliotbylegrand.com"
    static let signInPolicy = "B2C_1_BS_DoorEntry_App_iOS-SignUpOrSignIn"
    static let passwordPolicy = "B2C_1_BS_DoorEntry_App_iOS-password"
    static let clientID = "68391b24-f2fd-44c7-95b3-e04130d4a287"
    static let redirect = "com.legrandgroup.c300x://oauth2redirect"
    static let scope = "openid offline_access https://EliotClouduamprd.onmicrosoft.com/security/access.full"

    static func authorize(policy: String) -> String {
        let query = [
            "p=\(policy)",
            "client_id=\(clientID)",
            "nonce=defaultNonce",
            "redirect_uri=\(EliotPageScript.encodeURIComponent(redirect))",
            "scope=\(EliotPageScript.encodeURIComponent(scope))",
            "response_type=code",
            "prompt=login",
        ].joined(separator: "&")
        return "\(origin)/EliotClouduamprd.onmicrosoft.com/oauth2/v2.0/authorize?\(query)"
    }

    static func selfAsserted(page: EliotParsedPage) -> String {
        "\(origin)\(page.tenant)/SelfAsserted?tx=\(page.transId)&p=\(page.policy)"
    }

    static func confirmed(page: EliotParsedPage, api: String) -> String {
        "\(origin)\(page.tenant)/api/\(api)/confirmed?csrf_token=\(page.csrf)&tx=\(page.transId)&p=\(page.policy)"
    }

    static func signup(page: EliotParsedPage) -> String {
        "\(origin)\(page.tenant)/api/\(page.api)/unified?local=signup&csrf_token=\(page.csrf)&tx=\(page.transId)&p=\(page.policy)"
    }
}

struct EliotWireRequest: Equatable, Sendable {
    var method: String
    var url: String
    var headers: [String: String]
    var body: String
}

struct EliotWireResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

protocol EliotWire: AnyObject {
    func send(_ request: EliotWireRequest) async throws -> EliotWireResponse
}

final class EliotCookieJar {
    private(set) var pairs: [(String, String)] = []

    func store(_ response: EliotWireResponse) {
        let raw = response.header("set-cookie") ?? ""
        for line in raw.split(separator: "\n") {
            let piece = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let parts = piece.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            pairs.removeAll { $0.0 == name }
            pairs.append((name, parts[1]))
        }
    }

    var header: String {
        pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }
}

/// Sign-in, reset, and registration against the Eliot page script.
@MainActor
final class EliotWebJourney {
    private let wire: EliotWire
    private let jar = EliotCookieJar()
    private(set) var sent: [EliotWireRequest] = []
    private(set) var page: EliotParsedPage?
    var message: String?

    init(wire: EliotWire) {
        self.wire = wire
    }

    func loadSignIn() async throws -> EliotParsedPage {
        let response = try await get(EliotEndpoints.authorize(policy: EliotEndpoints.signInPolicy))
        guard let parsed = EliotPageDocument.parse(String(decoding: response.body, as: UTF8.self)) else {
            throw DoorEntrySignInFailure.unreachable("Eliot's sign-in page had no session.")
        }
        page = parsed
        return parsed
    }

    func submitSignIn(identifier: String, password: String) async throws -> String {
        let parsed = try await loadSignIn()
        let posted = try await post(
            EliotEndpoints.selfAsserted(page: parsed),
            body: EliotPageScript.signInBody(identifier: identifier, password: password),
            csrf: parsed.csrf
        )
        if let failure = EliotSelfAsserted.failure(in: posted.body) {
            message = failure.message
            throw failure
        }
        let confirmed = try await get(EliotEndpoints.confirmed(page: parsed, api: parsed.api))
        guard let code = Self.code(in: confirmed) else {
            throw DoorEntrySignInFailure.unreachable("Eliot did not return a sign-in code.")
        }
        let tokenURL = "\(EliotEndpoints.origin)/EliotClouduamprd.onmicrosoft.com/oauth2/v2.0/token?p=\(parsed.policy)"
        let tokenBody = [
            "grant_type=authorization_code",
            "client_id=\(EliotEndpoints.clientID)",
            "scope=\(EliotPageScript.encodeURIComponent(EliotEndpoints.scope))",
            "code=\(EliotPageScript.encodeURIComponent(code))",
            "redirect_uri=\(EliotPageScript.encodeURIComponent(EliotEndpoints.redirect))",
        ].joined(separator: "&")
        let token = try await post(tokenURL, body: tokenBody, csrf: nil)
        guard let json = try? JSONSerialization.jsonObject(with: token.body) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw DoorEntrySignInFailure.unreachable("Eliot did not return an access token.")
        }
        return access
    }

    func loadPasswordReset() async throws {
        let response = try await get(EliotEndpoints.authorize(policy: EliotEndpoints.passwordPolicy))
        guard let parsed = EliotPageDocument.parse(String(decoding: response.body, as: UTF8.self)) else {
            throw DoorEntrySignInFailure.unreachable("Eliot's password page had no session.")
        }
        page = parsed
    }

    func loadRegistration() async throws {
        let response = try await get(EliotEndpoints.authorize(policy: EliotEndpoints.signInPolicy))
        guard let authorizePage = EliotPageDocument.parse(String(decoding: response.body, as: UTF8.self)) else {
            throw DoorEntrySignInFailure.unreachable("Eliot's sign-in page had no session.")
        }
        let signup = try await get(EliotEndpoints.signup(page: authorizePage))
        guard let parsed = EliotPageDocument.parse(String(decoding: signup.body, as: UTF8.self)) else {
            throw DoorEntrySignInFailure.unreachable("Eliot's registration page had no session.")
        }
        page = parsed
    }

    func sendCode(claimId: String, claimValue: String) async throws {
        guard let page else { return }
        let posted = try await post(
            EliotEndpoints.selfAsserted(page: page),
            body: EliotPageScript.verificationBody(claimId: claimId, claimValue: claimValue),
            csrf: page.csrf
        )
        if let failure = EliotSelfAsserted.failure(in: posted.body) {
            message = failure.message
            throw failure
        }
    }

    func verifyCode(claimId: String, claimValue: String, userInput: String) async throws {
        guard let page else { return }
        let posted = try await post(
            EliotEndpoints.selfAsserted(page: page),
            body: EliotPageScript.validationBody(claimId: claimId, claimValue: claimValue, userInput: userInput),
            csrf: page.csrf
        )
        if let failure = EliotSelfAsserted.failure(in: posted.body) {
            message = failure.message
            throw failure
        }
    }

    /// Posts the current page. A `"400"` sets `message` and does not GET `confirmed`.
    func submit(_ values: [String: String]) async throws {
        guard let page else { return }
        if let rejection = Self.passwordRejection(fields: page.fields, values: values) {
            message = rejection
            throw DoorEntrySignInFailure.unreachable(rejection)
        }
        let claims = Self.responseClaims(fields: page.fields, values: values)
        let posted = try await post(
            EliotEndpoints.selfAsserted(page: page),
            body: EliotPageScript.responseBody(claims, trimPasswords: page.trimPasswords),
            csrf: page.csrf
        )
        if let failure = EliotSelfAsserted.failure(in: posted.body) {
            message = failure.message
            throw failure
        }
        let confirmed = try await get(EliotEndpoints.confirmed(page: page, api: "SelfAsserted"))
        if let next = EliotPageDocument.parse(String(decoding: confirmed.body, as: UTF8.self)) {
            self.page = next
            return
        }
        message = nil
    }

    static func passwordRejection(fields: [EliotField], values: [String: String]) -> String? {
        guard let fresh = fields.first(where: { $0.id == "newPassword" }),
              let again = fields.first(where: { $0.id == "reenterPassword" }) else {
            return nil
        }
        return EliotPasswordRules.rejection(
            newPassword: values[fresh.id] ?? "",
            reenterPassword: values[again.id] ?? "",
            pattern: fresh.pattern
        )
    }

    /// Inputs first, then menus, matching `collectData` then `encodeDropdownComponents`.
    static func responseClaims(fields: [EliotField], values: [String: String]) -> [(id: String, value: String)] {
        let inputs = fields.filter { $0.kind != .menu }
        let menus = fields.filter { $0.kind == .menu }
        return (inputs + menus).compactMap { field in
            let value = values[field.id] ?? ""
            if (field.id == "displayName" || field.id == "extension_Language"), value.isEmpty {
                return nil
            }
            if field.kind == .checkbox {
                return (field.id, "1")
            }
            return (field.id, value)
        }
    }

    private func get(_ url: String) async throws -> EliotWireResponse {
        try await send(EliotWireRequest(method: "GET", url: url, headers: [:], body: ""))
    }

    private func post(_ url: String, body: String, csrf: String?) async throws -> EliotWireResponse {
        var headers = [
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "Accept": "application/json, text/javascript, */*; q=0.01",
        ]
        if let csrf { headers["X-CSRF-TOKEN"] = csrf }
        return try await send(EliotWireRequest(method: "POST", url: url, headers: headers, body: body))
    }

    private func send(_ request: EliotWireRequest) async throws -> EliotWireResponse {
        var request = request
        if !jar.header.isEmpty {
            request.headers["Cookie"] = jar.header
        }
        sent.append(request)
        let response = try await wire.send(request)
        jar.store(response)
        if let location = response.header("location"), location.hasPrefix("com.legrandgroup.c300x:") {
            return EliotWireResponse(status: response.status, headers: response.headers, body: Data(location.utf8))
        }
        return response
    }

    private static func code(in response: EliotWireResponse) -> String? {
        let location = response.header("location") ?? String(decoding: response.body, as: UTF8.self)
        guard let items = URLComponents(string: location.hasPrefix("com.") ? "https://doorline.invalid/\(location.drop { $0 != "?" })" : location)?.queryItems else {
            return nil
        }
        return items.first { $0.name == "code" }?.value
    }
}

final class URLSessionEliotWire: EliotWire {
    private let redirect = EliotRedirect()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: redirect, delegateQueue: nil)
    }()

    func send(_ request: EliotWireRequest) async throws -> EliotWireResponse {
        guard let url = URL(string: request.url) else {
            throw DoorEntrySignInFailure.unreachable("Eliot URL could not be built.")
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: 30)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if request.method == "POST" {
            urlRequest.httpBody = Data(request.body.utf8)
        }
        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        http?.allHeaderFields.forEach { key, value in
            headers[String(describing: key)] = String(describing: value)
        }
        if let stopped = redirect.stopped {
            headers["Location"] = stopped.absoluteString
            redirect.stopped = nil
        }
        return EliotWireResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }
}
