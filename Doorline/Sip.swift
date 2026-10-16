import Foundation

/// SIP transport the registrar opens to the Flexisip proxy. The Door Entry cloud uses TLS.
enum SipTransport: String, Equatable, Sendable, Codable {
    case tls
    case tcp
    case udp
}

/// A SIP account provisioned for a Classe 300X gateway.
///
/// Read from `/sip/users/plants/{plant}/gateway/{gateway}` on the Door Entry portal. The
/// official app registers this account with liblinphone against the `bs.iotleg.com` Flexisip
/// proxy; the panel places the door call to it as a SIP INVITE.
struct SipAccount: Equatable, Sendable, Codable {
    var username: String
    var password: String
    /// Address-of-record domain, e.g. `{plant}.bs.iotleg.com`.
    var domain: String
    /// Registrar / proxy host, e.g. `sipserver.bs.iotleg.com`.
    var proxy: String
    var port: Int?
    var transport: SipTransport

    /// `sip:username@domain`.
    var identity: String { "sip:\(username)@\(domain)" }

    /// `sip:proxy[:port]` — the transport is set on the address, not embedded here.
    var serverAddress: String {
        let host = port.map { "\(proxy):\($0)" } ?? proxy
        return "sip:\(host)"
    }
}

enum SipProvisioningFailure: Error, Equatable {
    case unreachable(String)
    case malformed(String)

    var message: String {
        switch self {
        case .unreachable(let reason), .malformed(let reason): reason
        }
    }
}

/// Fetches the SIP account the portal provisions for a gateway.
protocol SipProvisioning: Sendable {
    func sipAccount(plantID: String, gatewayID: String, token: String) async throws -> SipAccount
}

/// `GET {host}/sip/users/plants/{plant}/gateway/{gateway}` with the Eliot bearer token and
/// `PRJ_NAME: C3X`, the same portal and headers Door Entry's plant list uses.
struct EliotSipProvisioning: SipProvisioning {
    var host: String = "https://www.myhomeweb.com"
    var userAgent: String = "doorentryforc300x-ios-1.13.5"

    func sipAccount(plantID: String, gatewayID: String, token: String) async throws -> SipAccount {
        guard let url = URL(string: "\(host)/sip/users/plants/\(plantID)/gateway/\(gatewayID)") else {
            throw SipProvisioningFailure.unreachable("SIP users URL could not be built.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("C3X", forHTTPHeaderField: "PRJ_NAME")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SipProvisioningFailure.unreachable("SIP provisioning answered HTTP \(status).")
        }
        return try SipAccountDocument.parse(data, fallbackDomain: "\(plantID).bs.iotleg.com")
    }
}

/// Reads a SIP account out of the portal JSON. The field names are not pinned by a schema, so
/// each value is looked up under the spellings seen across Door Entry payloads, and the account
/// object is found wherever it sits in the response (some portals wrap it in an envelope).
enum SipAccountDocument {
    // The Door Entry 1.13.5 sip-users document spells the user as `sipUser`/`sipAccount`
    // and the password as `sipPassword` (SipRepository.swift strings in the binary).
    static let usernameKeys = ["username", "sipUsername", "sip_username", "sipUser", "sipAccount", "user", "sip_user", "login"]
    static let passwordKeys = ["password", "sipPassword", "sip_password", "passwd", "secret"]
    static let domainKeys = ["domain", "sipDomain", "sip_domain", "realm"]
    static let proxyKeys = ["proxy", "sipProxy", "sip_proxy", "registrar", "server", "sipServer", "outboundProxy"]
    static let portKeys = ["port", "sipPort", "sip_port"]
    static let transportKeys = ["transport", "sipTransport", "sip_transport"]

    static func parse(_ data: Data, fallbackDomain: String) throws -> SipAccount {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw SipProvisioningFailure.malformed("SIP account response was not JSON.")
        }
        guard let node = firstObject(json, anyKey: usernameKeys) else {
            throw SipProvisioningFailure.malformed("SIP account had no username field.")
        }
        guard let username = text(node, usernameKeys), !username.isEmpty,
              let password = text(node, passwordKeys), !password.isEmpty else {
            throw SipProvisioningFailure.malformed("SIP account was missing credentials.")
        }
        let domain = text(node, domainKeys) ?? fallbackDomain
        let proxy = text(node, proxyKeys) ?? domain
        let transport = SipTransport(rawValue: (text(node, transportKeys) ?? "tls").lowercased()) ?? .tls
        return SipAccount(
            username: username,
            password: password,
            domain: domain,
            proxy: proxy,
            port: int(node, portKeys),
            transport: transport
        )
    }

    /// First object in the tree that carries any of `anyKey`.
    static func firstObject(_ value: Any, anyKey keys: [String]) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if keys.contains(where: { object[$0] != nil }) { return object }
            for child in object.values {
                if let found = firstObject(child, anyKey: keys) { return found }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = firstObject(item, anyKey: keys) { return found }
            }
        }
        return nil
    }

    static func text(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let string = object[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = object[key] as? NSNumber { return number.stringValue }
        }
        return nil
    }

    static func int(_ object: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let number = object[key] as? NSNumber { return number.intValue }
            if let string = object[key] as? String, let value = Int(string) { return value }
        }
        return nil
    }
}

/// Fetches the current account's SIP credentials. The portal token comes from the sign-in that
/// already happened, so this is a separate capability from the plant directory.
@MainActor
protocol SipCredentials: AnyObject {
    func sipAccount(plantID: String, gatewayID: String) async throws -> SipAccount
}

/// Registration lifecycle the screens read. `connecting` covers the SIP REGISTER in flight.
enum SipRegistrationState: Equatable, Sendable {
    case idle
    case connecting
    case registered
    case failed(String)
}

/// Call control and the SIP MESSAGE channel, alongside registration.
///
/// Door Entry 1.13.5 answers with audio in both directions and video receive-only (the
/// phone never sends video), and carries the answering-machine and door commands as SIP
/// MESSAGE bodies of the form `msg: <body>, addr: <address>` to the gateway's SIP user.
@MainActor
protocol SipCallControl: AnyObject {
    /// Called with the caller display string when an INVITE arrives.
    var onIncomingCall: ((String) -> Void)? { get set }
    /// Called when the linphone call ends for any reason (remote hang-up, error, our end).
    var onCallEnded: (() -> Void)? { get set }
    /// Called with the body of a SIP MESSAGE received from the gateway.
    var onMessageBody: ((String) -> Void)? { get set }

    func answer()
    func decline()
    func endCall()
    /// Dials the internal unit (`sip:c300x@{domain}` for the registered account).
    func callHome()
    /// Sends a SIP MESSAGE to the gateway's SIP user.
    func sendMessage(_ body: String)
}

/// Registers a `SipAccount` with a SIP stack and reports the registration state.
@MainActor
protocol SipRegistrar: SipCallControl {
    var registration: SipRegistrationState { get }
    func start()
    func register(_ account: SipAccount)
    func unregister()
}

/// No-op registrar for platforms without the Linphone SDK (macOS) and for tests that do not
/// exercise a real registration. A missing SIP stack must not read as a successful registration.
@MainActor
final class StubSipRegistrar: SipRegistrar {
    private(set) var registration: SipRegistrationState = .idle
    var onIncomingCall: ((String) -> Void)?
    var onCallEnded: (() -> Void)?
    var onMessageBody: ((String) -> Void)?
    private(set) var answered = false
    private(set) var declined = false
    private(set) var ended = false
    private(set) var calledHome = false
    private(set) var sentMessages: [String] = []

    func start() {}
    func register(_ account: SipAccount) { registration = .idle }
    func unregister() { registration = .idle }
    func answer() { answered = true }
    func decline() { declined = true }
    func endCall() { ended = true }
    func callHome() { calledHome = true }
    func sendMessage(_ body: String) { sentMessages.append(body) }
}
