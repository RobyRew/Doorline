#if canImport(linphonesw)
import Foundation
import linphonesw

/// Registers a Classe 300X SIP account with liblinphone, the same stack the official Door Entry
/// app uses, so the panel's INVITE reaches us on the `bs.iotleg.com` Flexisip proxy.
///
/// This step wires registration only. Call handling (incoming INVITE, answer/decline, media,
/// and the door-open command carried over the call) is added on top of the same `Core`.
@MainActor
@Observable
final class LinphoneManager: SipRegistrar {
    private(set) var registration: SipRegistrationState = .idle

    private var core: Core?
    private var coreDelegate: CoreDelegate?

    /// Creates and starts the `Core` once. liblinphone drives itself off the main run loop while
    /// `autoIterateEnabled` is on, so no manual iterate timer is needed.
    func start() {
        guard core == nil else { return }
        do {
            let core = try Factory.Instance.createCore(configPath: nil, factoryConfigPath: nil, systemContext: nil)
            core.autoIterateEnabled = true
            let delegate = CoreDelegateStub(onAccountRegistrationStateChanged: { [weak self] _, _, state, message in
                Task { @MainActor in self?.apply(state, message) }
            })
            core.addDelegate(delegate: delegate)
            coreDelegate = delegate
            try core.start()
            self.core = core
        } catch {
            registration = .failed(error.localizedDescription)
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

            let created = try core.createAccount(params: params)
            try core.addAccount(account: created)
            core.defaultAccount = created
            registration = .connecting
        } catch {
            registration = .failed(error.localizedDescription)
        }
    }

    func unregister() {
        core?.clearAccounts()
        core?.clearAllAuthInfo()
        registration = .idle
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
