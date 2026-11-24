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
            "That account has no door system on it."
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
    func plants(email: String, password: String, product: DoorProduct) async -> Result<[DoorEntryPlant], DoorEntrySignInFailure>
}

/// The door system Doorline is signing in to. Classe 300X is the one the entrance controls;
/// the others use the same screens with that product's sign-in.
enum DoorProduct: String, CaseIterable, Identifiable, Sendable {
    case classe300X
    case homeTouch
    case classe100X
    case easyKit

    var id: String { rawValue }

    static let storageKey = "doorline.product"

    static var stored: DoorProduct {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let product = DoorProduct(rawValue: raw) else { return .classe300X }
        return product
    }

    func store() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }

    var title: String {
        switch self {
        case .classe300X: "Classe 300X"
        case .homeTouch: "Home Touch"
        case .classe100X: "Classe 100X"
        case .easyKit: "EasyKit"
        }
    }

    var signInDetail: String {
        switch self {
        case .classe300X:
            "Use the same email and password as Door Entry. Doorline signs that account in to the Classe 300X portal and reads the system on it."
        case .homeTouch:
            "Use the same email and password as Door Entry for Home Touch. Doorline signs that account in to the Home Touch portal."
        case .classe100X:
            "Classe 100X still signs in through Eliot, then reads the service catalog for that account."
        case .easyKit:
            "EasyKit still signs in through Eliot, then reads the service catalog for that account."
        }
    }

    /// Door Entry 1.13.6 (Classe 300X and Home Touch) posts the account to the portal.
    /// Eliot web sign-in is not part of those builds.
    var portal: PortalSignIn.Profile? {
        switch self {
        case .classe300X:
            PortalSignIn.Profile(
                projectName: "C3X",
                userAgent: "doorentryforc300x-ios-1.13.6",
                appVersion: "1.13.6"
            )
        case .homeTouch:
            PortalSignIn.Profile(
                projectName: "MHT",
                userAgent: "doorentryforHOMETOUCH-ios-1.13.6",
                appVersion: "1.13.6"
            )
        case .classe100X, .easyKit:
            nil
        }
    }

    /// Where the phone registers, and the panel user it dials.
    /// Door Entry 1.13.6 uses `app.sipserver.bs.iotleg.com` for Classe 300X and Home Touch.
    /// Classe 100X 1.7.2 and EasyKit 1.7.0 use `vdesip.bs.iotleg.com`. Both listen on TLS 443.
    var sipRoute: (proxy: String, port: Int, panelUser: String) {
        switch self {
        case .classe300X:
            ("app.sipserver.bs.iotleg.com", 443, "c300x")
        case .homeTouch:
            ("app.sipserver.bs.iotleg.com", 443, "MHT")
        case .classe100X:
            ("vdesip.bs.iotleg.com", 443, "c100x")
        case .easyKit:
            ("vdesip.bs.iotleg.com", 443, "diy")
        }
    }

    /// `Ocp-Apim-Subscription-Key` for the Legrand developer catalog.
    /// The production key is the second key stored after the API host in each binary.
    var subscriptionKey: String? {
        switch self {
        case .classe100X:
            "a61c185c9b97499e9f64c0e798f324bc"
        case .easyKit:
            "f36968e522bf4ec3877fa491109d3d14"
        case .classe300X, .homeTouch:
            nil
        }
    }

    /// Classe 100X 1.7.2 and EasyKit 1.7.0 still open an Eliot B2C page.
    /// The client id is the UUID stored beside that policy in each binary.
    var eliotClient: EliotClient {
        switch self {
        case .classe100X:
            EliotClient(
                signInPolicy: "B2C_1_DoorEliot-C100X-SignUporSignIn",
                passwordPolicy: "B2C_1_DoorEliot-C100X-password",
                clientID: "89157f0f-9a06-e811-80c2-0003ff433c2c",
                redirect: "com.legrandgroup.c100x://oauth2redirect"
            )
        case .easyKit:
            EliotClient(
                signInPolicy: "B2C_1_DoorEliot-DIY-SignUporSignIn",
                passwordPolicy: "B2C_1_DoorEliot-DIY-Password",
                clientID: "89157f0f-9a06-e811-80c2-0003ff433c2c",
                redirect: "com.legrandgroup.diy://oauth2redirect"
            )
        case .classe300X, .homeTouch:
            .classe300X
        }
    }
}

/// Password sign-in against `www.myhomeweb.com/eliot/users/sign_in`.
/// Door Entry 1.13.6 posts `username`, `password`, and `rememberMe`. The same request
/// also carries `appVersion` and an empty `registrationId`. The product code (`C3X` or
/// `MHT`) is the `prj_name` header, not a body field.
enum PortalSignIn {
    struct Profile: Equatable, Sendable {
        var projectName: String
        var userAgent: String
        var appVersion: String
    }

    struct Ticket: Equatable, Sendable {
        var token: String?
        var plants: [DoorEntryPlant]
    }

    static func jsonBody(username: String, password: String, profile: Profile) -> Data {
        let object: [String: Any] = [
            "username": username,
            "password": password,
            "rememberMe": true,
            "appVersion": profile.appVersion,
            "registrationId": "",
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A rejected password is HTTP 401 with an empty body. Any other failure keeps the portal's warning.
    static func outcome(status: Int, warning: String, body: Data) -> Result<Ticket, DoorEntrySignInFailure> {
        if status == 401 || status == 403 {
            return .failure(.invalidCredentials("That email or password was not accepted."))
        }
        guard (200..<300).contains(status) else {
            let reason = warning.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = reason.isEmpty ? "HTTP \(status)" : reason
            return .failure(.unreachable("The portal answered \(detail)."))
        }
        return .success(Ticket(token: token(in: body), plants: DoorEntryAccountDocument.plants(in: body)))
    }

    static func token(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return token(in: json)
    }

    private static func token(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            for key in ["auth_token", "authToken", "token"] {
                if let string = object[key] as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            for child in object.values {
                if let found = token(in: child) { return found }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let found = token(in: child) { return found }
            }
        }
        return nil
    }
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

    /// `www.myhomeweb.com/eliot/plants` with header `prj_name` (`C3X` or `MHT`).
    /// An empty body was reported as no device. HTTP 401 is a missing portal session.
    static func portalPlants(status: Int, warning: String, body: Data) -> Result<[DoorEntryPlant], DoorEntrySignInFailure> {
        if status == 204 || (status == 200 && body.isEmpty) {
            return .failure(.noPlant)
        }
        if !(200..<300).contains(status) {
            let reason = warning.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = reason.isEmpty ? "HTTP \(status)" : reason
            return .failure(.unreachable("The portal answered \(detail)."))
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
    private let portalHTTP: URLSession
    private(set) var lastToken: String?
    private var developerAPI = false
    private var subscriptionKey: String?
    private var fallbackProxy = "app.sipserver.bs.iotleg.com"
    private var fallbackPort = 443
    private var panelUser = "c300x"

    init(
        provisioning: SipProvisioning = EliotSipProvisioning(),
        // Optional because default arguments evaluate outside this actor's isolation,
        // which a MainActor-isolated initializer call would not be allowed in.
        certificateProvisioning: SipCertificateProvisioner? = nil
    ) {
        self.provisioning = provisioning
        let provisioner = certificateProvisioning ?? SipCertificateProvisioner()
        self.certificateProvisioning = provisioner
        let storage = HTTPCookieStorage()
        storage.cookieAcceptPolicy = .always
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = storage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        self.portalHTTP = session
        if let provisioning = provisioning as? EliotSipProvisioning {
            provisioning.session = session
        }
        provisioner.session = session
    }

    var portalToken: String? { lastToken }

    func ensureMaterial(deviceName: String) async throws {
        guard let token = lastToken else {
            throw CertificateProvisioningFailure.unreachable("Sign in before provisioning the SIP certificate.")
        }
        _ = try await certificateProvisioning.ensureMaterial(deviceName: deviceName, token: token)
    }

    func plants(email: String, password: String, product: DoorProduct) async -> Result<[DoorEntryPlant], DoorEntrySignInFailure> {
        if let profile = product.portal {
            return await portalPlants(email: email, password: password, profile: profile, product: product)
        }
        return await eliotPlants(email: email, password: password, product: product)
    }

    /// Door Entry 1.13.6 posts the account to `/eliot/users/sign_in`, then lists `/eliot/plants`
    /// with the same cookies and `prj_name`.
    private func portalPlants(email: String, password: String, profile: PortalSignIn.Profile, product: DoorProduct) async -> Result<[DoorEntryPlant], DoorEntrySignInFailure> {
        do {
            let ticket = try await signPortal(email: email, password: password, profile: profile)
            lastToken = ticket.token
            apply(profile: profile, product: product, token: ticket.token, sendsBearer: false)
            if !ticket.plants.isEmpty { return .success(ticket.plants) }
            let plants = try await listedPlants(profile: profile, token: ticket.token, sendsBearer: false)
            if plants.isEmpty { return .failure(.noPlant) }
            return .success(plants)
        } catch let failure as DoorEntrySignInFailure {
            return .failure(failure)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    /// Classe 100X and EasyKit still exchange an Eliot authorization code, then read the catalog.
    private func eliotPlants(email: String, password: String, product: DoorProduct) async -> Result<[DoorEntryPlant], DoorEntrySignInFailure> {
        do {
            let token = try await EliotWebJourney(wire: URLSessionEliotWire()).submitSignIn(
                identifier: email,
                password: password,
                client: product.eliotClient
            )
            lastToken = token
            apply(profile: nil, product: product, token: token, sendsBearer: true)
            let plants = try await catalogPlants(token: token, subscriptionKey: product.subscriptionKey)
            if plants.isEmpty { return .failure(.noPlant) }
            return .success(plants)
        } catch let failure as DoorEntrySignInFailure {
            return .failure(failure)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    private func apply(profile: PortalSignIn.Profile?, product: DoorProduct, token: String?, sendsBearer: Bool) {
        let route = product.sipRoute
        if let provisioning = provisioning as? EliotSipProvisioning {
            if let profile {
                provisioning.userAgent = profile.userAgent
                provisioning.projectName = profile.projectName
            }
            provisioning.authToken = token
            provisioning.sendsBearer = sendsBearer
            provisioning.fallbackProxy = route.proxy
            provisioning.fallbackPort = route.port
            provisioning.panelUser = route.panelUser
        }
        if let profile {
            certificateProvisioning.userAgent = profile.userAgent
            certificateProvisioning.projectName = profile.projectName
            certificateProvisioning.host = "https://www.myhomeweb.com"
            certificateProvisioning.certificatePath = "/eliot/users/cert/signcert"
            certificateProvisioning.subscriptionKey = nil
        } else {
            certificateProvisioning.host = "https://api.developer.legrand.com"
            certificateProvisioning.certificatePath = "/certificate/api/v1.0/ca/information/clientCerts"
            certificateProvisioning.subscriptionKey = product.subscriptionKey
        }
        certificateProvisioning.authToken = token
        certificateProvisioning.sendsBearer = sendsBearer
        developerAPI = product.subscriptionKey != nil
        subscriptionKey = product.subscriptionKey
        panelUser = route.panelUser
        fallbackProxy = route.proxy
        fallbackPort = route.port
    }

    private func signPortal(email: String, password: String, profile: PortalSignIn.Profile) async throws -> PortalSignIn.Ticket {
        guard let url = URL(string: "https://www.myhomeweb.com/eliot/users/sign_in") else {
            throw DoorEntrySignInFailure.unreachable("Portal sign-in URL could not be built.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(profile.projectName, forHTTPHeaderField: "prj_name")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = PortalSignIn.jsonBody(username: email, password: password, profile: profile)
        let (data, response) = try await portalHTTP.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let warning = http?.value(forHTTPHeaderField: "Warning") ?? ""
        let headerToken = http?.value(forHTTPHeaderField: "auth_token")
        let outcome = try PortalSignIn.outcome(status: status, warning: warning, body: data).get()
        if outcome.token == nil, let headerToken, !headerToken.isEmpty {
            return PortalSignIn.Ticket(token: headerToken, plants: outcome.plants)
        }
        return outcome
    }

    private func listedPlants(profile: PortalSignIn.Profile, token: String?, sendsBearer: Bool) async throws -> [DoorEntryPlant] {
        guard let url = URL(string: "https://www.myhomeweb.com/eliot/plants") else {
            throw DoorEntrySignInFailure.unreachable("Portal plant URL could not be built.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(profile.projectName, forHTTPHeaderField: "prj_name")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue(token, forHTTPHeaderField: "auth_token")
            if sendsBearer {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        let (data, response) = try await portalHTTP.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let warning = http?.value(forHTTPHeaderField: "Warning") ?? ""
        return try DoorEntryAccountDocument.portalPlants(status: status, warning: warning, body: data).get()
    }

    /// Service catalog used by Classe 100X and EasyKit. The catalog rejects a call that
    /// omits `Ocp-Apim-Subscription-Key`.
    private func catalogPlants(token: String, subscriptionKey: String?) async throws -> [DoorEntryPlant] {
        guard let url = URL(string: "https://api.developer.legrand.com/servicecatalog/api/v3.0/plants") else {
            throw DoorEntrySignInFailure.unreachable("Catalog URL could not be built.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let subscriptionKey {
            request.setValue(subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 || (status == 200 && data.isEmpty) {
            throw DoorEntrySignInFailure.noPlant
        }
        guard (200..<300).contains(status) else {
            throw DoorEntrySignInFailure.unreachable("The service catalog answered HTTP \(status).")
        }
        let listed = DoorEntryAccountDocument.catalogPlants(in: data)
        if listed.isEmpty { return [] }
        var plants: [DoorEntryPlant] = []
        for row in listed {
            let gateway = await catalogGateway(plantID: row.id, token: token, subscriptionKey: subscriptionKey) ?? row.id
            plants.append(DoorEntryPlant(plantID: row.id, gatewayID: gateway, name: row.name))
        }
        return plants
    }

    private func catalogGateway(plantID: String, token: String, subscriptionKey: String?) async -> String? {
        guard let url = URL(string: "https://api.developer.legrand.com/servicecatalog/api/v3.0/plants/\(plantID)/modules") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let subscriptionKey {
            request.setValue(subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status) else { return nil }
        return DoorEntryAccountDocument.gatewayID(in: data)
    }

    /// Uses the token from the last sign-in to read the gateway's SIP account.
    /// Classe 300X and Home Touch read `/eliot/sip/users/...` on the portal.
    /// Classe 100X and EasyKit read `/devicemanagement/api/v2.0/modules/{id}/vde/sip`.
    func sipAccount(plantID: String, gatewayID: String) async throws -> SipAccount {
        guard let token = lastToken else {
            throw SipProvisioningFailure.unreachable("Sign in before provisioning the SIP account.")
        }
        if developerAPI {
            return try await developerSipAccount(plantID: plantID, gatewayID: gatewayID, token: token)
        }
        return try await provisioning.sipAccount(plantID: plantID, gatewayID: gatewayID, token: token)
    }

    private func developerSipAccount(plantID: String, gatewayID: String, token: String) async throws -> SipAccount {
        guard let url = URL(string: "https://api.developer.legrand.com/devicemanagement/api/v2.0/modules/\(gatewayID)/vde/sip") else {
            throw SipProvisioningFailure.unreachable("SIP users URL could not be built.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let subscriptionKey {
            request.setValue(subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SipProvisioningFailure.unreachable("SIP provisioning answered HTTP \(status).")
        }
        return try SipAccountDocument.parse(
            data,
            fallbackDomain: "\(plantID).bs.iotleg.com",
            fallbackProxy: fallbackProxy,
            fallbackPort: fallbackPort,
            panelUser: panelUser
        )
    }
}
