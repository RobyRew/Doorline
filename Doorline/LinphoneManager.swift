#if canImport(linphonesw)
import Foundation
import linphonesw

/// The Door Entry 1.13.5 SIP configuration, mirrored from the official app's
/// `LinphoneManager` (see docs/reverse-engineering.md):
///
/// - TLS transport on port 443 against the `bs.iotleg.com` Flexisip proxy,
///   `verify_server_certificates` on and `verify_server_cn` off.
/// - Registration expiry 5,184,000 s (60 days).
/// - Media encryption SRTP, mandatory.
/// - STUN on `stun.linphone.org`, DNS SRV off.
/// - Video activation policy auto-accept and auto-initiate; video display on, capture off.
/// - In-call and no-RTP timeouts 60 s without video, 180 s with video.
/// - The client TLS certificate from the Keychain, when one is provisioned.
@MainActor
@Observable
final class LinphoneManager: SipRegistrar {
    private(set) var registration: SipRegistrationState = .idle
    var onIncomingCall: ((String) -> Void)?
    var onCallEnded: (() -> Void)?
    var onMessageBody: ((String) -> Void)?

    private var core: Core?
    private var coreDelegate: CoreDelegate?
    private var account: SipAccount?

    /// Creates and starts the `Core` once. liblinphone drives itself off the main run loop while
    /// `autoIterateEnabled` is on, so no manual iterate timer is needed.
    func start() {
        guard core == nil else { return }
        do {
            let core = try Factory.Instance.createCore(configPath: nil, factoryConfigPath: nil, systemContext: nil)
            core.autoIterateEnabled = true
            let delegate = CoreDelegateStub(
                onCallStateChanged: { [weak self] _, call, state, _ in
                    Task { @MainActor in self?.apply(call, state) }
                },
                onMessageReceived: { [weak self] _, _, message in
                    Task { @MainActor in self?.deliver(message) }
                },
                onAccountRegistrationStateChanged: { [weak self] _, _, state, message in
                    Task { @MainActor in self?.apply(state, message) }
                }
            )
            core.addDelegate(delegate: delegate)
            coreDelegate = delegate
            applyCoreSettings(core)
            try core.start()
            self.core = core
        } catch {
            registration = .failed(error.localizedDescription)
        }
    }

    /// Settings the official app applies in `finishCoreConfiguration()`.
    private func applyCoreSettings(_ core: Core) {
        try? core.setMediaencryption(newValue: .SRTP)
        core.mediaEncryptionMandatory = true
        core.verifyServerCertificates(yesno: true)
        core.verifyServerCn(yesno: false)
        core.dnsSrvEnabled = false
        core.inCallTimeout = 60
        core.nortpTimeout = 60
        if let policy = try? core.createNatPolicy() {
            policy.stunEnabled = true
            policy.stunServer = "stun.linphone.org"
            core.natPolicy = policy
        }
        if let policy = core.videoActivationPolicy {
            policy.automaticallyAccept = true
            policy.automaticallyInitiate = true
        }
        core.videoDisplayEnabled = true
        core.videoCaptureEnabled = false
        let certificates = SipCertificateStore.shared.material
        if let material = certificates {
            core.tlsCert = material.clientCert
            core.tlsKey = material.privateKey
            core.rootCaData = material.rootCA
        }
    }

    /// Replaces any existing account with `account` and begins a SIP REGISTER.
    func register(_ account: SipAccount) {
        start()
        guard let core else { return }
        do {
            core.clearAccounts()
            core.clearAllAuthInfo()

            let factory = Factory.Instance
            let authInfo = try factory.createAuthInfo(
                username: account.username,
                userid: account.username,
                passwd: account.password,
                ha1: nil,
                realm: nil,
                domain: account.domain
            )
            core.addAuthInfo(info: authInfo)

            let params = try core.createAccountParams()
            let identity = try factory.createAddress(addr: account.identity)
            try params.setIdentityaddress(newValue: identity)

            let server = try factory.createAddress(addr: account.serverAddress)
            try server.setTransport(newValue: account.transport.linphone)
            try params.setServeraddress(newValue: server)
            params.registerEnabled = true
            // Door Entry registers for 60 days so the Flexisip proxy can push calls.
            params.expires = 5_184_000

            let created = try core.createAccount(params: params)
            try core.addAccount(account: created)
            core.defaultAccount = created
            self.account = account
            registration = .connecting
        } catch {
            registration = .failed(error.localizedDescription)
        }
    }

    func unregister() {
        core?.clearAccounts()
        core?.clearAllAuthInfo()
        account = nil
        registration = .idle
    }

    // MARK: - Call control

    /// Answers with audio in both directions and video receive-only when the caller
    /// offered video — the official app never sends video back.
    func answer() {
        guard let core, let call = core.currentCall else { return }
        do {
            let params = try core.createCallParams(call: call)
            if call.remoteParams?.videoEnabled == true {
                params.videoEnabled = true
                params.videoDirection = .RecvOnly
            }
            params.audioEnabled = true
            params.audioDirection = .SendRecv
            try call.acceptWithParams(params: params)
            core.micEnabled = true
        } catch {
            // The delegate reports the resulting call state; a failed accept leaves the call ringing.
        }
    }

    func decline() {
        try? core?.currentCall?.decline(reason: .Declined)
    }

    func endCall() {
        try? core?.currentCall?.terminate()
    }

    /// Dials the internal unit of the registered plant.
    func callHome() {
        guard let core, let account else { return }
        do {
            let params = try core.createCallParams(call: nil)
            params.audioEnabled = true
            params.audioDirection = .SendRecv
            params.videoEnabled = true
            params.videoDirection = .RecvOnly
            guard let address = try? Factory.Instance.createAddress(addr: "sip:c300x@\(account.domain)") else { return }
            _ = core.inviteAddressWithParams(addr: address, params: params)
        } catch {
            // The delegate reports the resulting call state.
        }
    }

    /// Sends a SIP MESSAGE to the gateway SIP user with Door Entry's
    /// `msg: <body>, addr: <address>` body shape.
    func sendMessage(_ body: String) {
        guard let core, let account else { return }
        let gateway = "sip:c300x@\(account.domain)"
        guard let address = try? Factory.Instance.createAddress(addr: gateway),
              let room = core.searchChatRoom(params: nil, localAddr: nil, remoteAddr: address, participants: nil) else { return }
        let message = "msg: \(body), addr: \(gateway)"
        if let chatMessage = try? room.createMessageFromUtf8(message: message) {
            chatMessage.send()
        }
    }

    // MARK: - Linphone events

    private func apply(_ call: Call, _ state: Call.State) {
        switch state {
        case .IncomingReceived:
            let caller = call.remoteAddress?.displayName ?? call.remoteAddress?.asStringUriOnly() ?? "Entrance"
            onIncomingCall?(caller)
        case .End, .Error, .Released:
            onCallEnded?()
        default:
            break
        }
    }

    private func deliver(_ message: ChatMessage) {
        // Gateway messages arrive as `msg: <body>, addr: <address>`; the session parses
        // the body (answering-machine lists among others). Unknown senders are dropped.
        guard let body = message.utf8Text, !body.isEmpty else { return }
        onMessageBody?(body)
    }

    private func apply(_ state: RegistrationState, _ message: String) {
        switch state {
        case .None, .Cleared: registration = .idle
        case .Progress, .Refreshing: registration = .connecting
        case .Ok: registration = .registered
        case .Failed: registration = .failed(message.isEmpty ? "Registration failed." : message)
        }
    }
}

private extension SipTransport {
    var linphone: TransportType {
        switch self {
        case .tls: .Tls
        case .tcp: .Tcp
        case .udp: .Udp
        }
    }
}

@MainActor
func makeSipRegistrar() -> SipRegistrar { LinphoneManager() }

#else

@MainActor
func makeSipRegistrar() -> SipRegistrar { StubSipRegistrar() }

#endif
