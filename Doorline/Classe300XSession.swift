import Foundation
import Observation

struct AccountLink: Equatable, Sendable, Codable {
    var account: String
    var plantID: String
    var gatewayID: String
}

enum Association: Equatable, Sendable {
    case signedOut
    case saved(AccountLink)
}

enum ForwardingMode: String, Codable, CaseIterable, Sendable {
    case allPhones
    case atHome
    case blocked

    var title: String {
        switch self {
        case .allPhones: "All phones"
        case .atHome: "At home only"
        case .blocked: "Blocked"
        }
    }
}

struct EntranceCamera: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var name: String
}

struct AnsweringMessage: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var recordedAt: Date
    var caller: String
}

struct HistoryEntry: Identifiable, Equatable, Sendable, Codable {
    enum Kind: String, Codable, Sendable {
        case call
        case unlock
    }

    var id: UUID
    var date: Date
    var kind: Kind
    var detail: String
}

struct CallState: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case idle
        case ringing
        case active
        case declined
    }

    enum Direction: String, Equatable, Sendable {
        case none
        case incoming
        case callHome
    }

    var phase: Phase = .idle
    var direction: Direction = .none
    var audioLive = false
    var videoLive = false
    var caller = ""
}

struct Classe300XSnapshot: Codable, Equatable, Sendable {
    var account = ""
    var plantID = ""
    var gatewayID = ""
    /// Panel address the OWN frames are sent to (OpenWebNet port 20000). Empty until set.
    var panelHost = ""
    var forwarding: ForwardingMode = .blocked
    var professionalStudio = false
    var answeringMachineEnabled = false
    var history: [HistoryEntry] = []
    var messages: [AnsweringMessage] = []
    var currentCameraID: String?
}

protocol Classe300XShelf: AnyObject {
    func load() -> Classe300XSnapshot
    func save(_ snapshot: Classe300XSnapshot)
}

final class MemoryShelf: Classe300XShelf {
    private var snapshot = Classe300XSnapshot()
    func load() -> Classe300XSnapshot { snapshot }
    func save(_ snapshot: Classe300XSnapshot) { self.snapshot = snapshot }
}

final class UserDefaultsShelf: Classe300XShelf {
    private let key = "doorline.classe300x"

    func load() -> Classe300XSnapshot {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Classe300XSnapshot.self, from: data) else {
            return Classe300XSnapshot()
        }
        return snapshot
    }

    func save(_ snapshot: Classe300XSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Classe 300X session the screens call. Network delivery sits behind `C300XTransport`.
@MainActor
@Observable
final class Classe300XSession {
    private(set) var association: Association = .signedOut
    private(set) var call = CallState()
    private(set) var cameras: [EntranceCamera] = []
    private(set) var currentCameraID: String?
    private(set) var messages: [AnsweringMessage] = []
    private(set) var playingMessageID: String?
    private(set) var forwarding: ForwardingMode = .blocked
    private(set) var professionalStudio = false
    private(set) var answeringMachineEnabled = false
    private(set) var history: [HistoryEntry] = []
    private(set) var sent: [C300XFrame] = []
    private(set) var lastReceipt: C300XReceipt = .queued
    private(set) var rememberedEmail: String
    /// Panel address the OWN frames are sent to. Empty until the user sets one.
    private(set) var panelHost: String = ""

    private let transport: C300XTransport
    private let router: RouterTransport?
    private let shelf: Classe300XShelf
    private let directory: DoorEntryDirectory
    private let registrar: SipRegistrar?
    private let now: () -> Date
    private var storesSession = true

    init(
        transport: C300XTransport = RouterTransport(),
        shelf: Classe300XShelf = UserDefaultsShelf(),
        directory: DoorEntryDirectory? = nil,
        registrar: SipRegistrar? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.router = transport as? RouterTransport
        self.shelf = shelf
        self.directory = directory ?? EliotDirectory()
        self.registrar = registrar
        self.now = now
        rememberedEmail = UserDefaults.standard.string(forKey: Self.rememberedEmailKey) ?? ""
        restore(shelf.load())
        registrar?.start()
        registrar?.onIncomingCall = { [weak self] caller in
            Task { @MainActor in await self?.receiveRing(caller: caller) }
        }
        registrar?.onCallEnded = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.call = CallState()
                self.persist()
            }
        }
        registrar?.onMessageBody = { [weak self] body in
            Task { @MainActor in self?.ingestGatewayMessage(body) }
        }
    }

    /// Strips Door Entry's `msg: <body>, addr: <address>` envelope and parses the body.
    private func ingestGatewayMessage(_ envelope: String) {
        var body = envelope
        if body.hasPrefix("msg: "), let separator = body.range(of: ", addr: ") {
            body = String(body[body.index(body.startIndex, offsetBy: 5)..<separator.lowerBound])
        }
        ingestMessages(body)
    }

    static let shared = Classe300XSession(registrar: makeSipRegistrar())

    var currentCamera: EntranceCamera? {
        cameras.first { $0.id == currentCameraID }
    }

    var link: AccountLink? {
        if case .saved(let link) = association { return link }
        return nil
    }

    /// SIP registration state from the registrar, or `.idle` when none is wired (tests, macOS).
    var sipRegistration: SipRegistrationState { registrar?.registration ?? .idle }

    func associate(account: String, plantID: String, gatewayID: String) async {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let plantID = plantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let gatewayID = gatewayID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !plantID.isEmpty, !gatewayID.isEmpty else { return }
        association = .saved(AccountLink(account: account, plantID: plantID, gatewayID: gatewayID))
        if cameras.isEmpty {
            cameras = [
                EntranceCamera(id: C300XCodec.entranceCameraAddress, name: "Entrance"),
                EntranceCamera(id: C300XCodec.secondaryCameraAddress, name: "Secondary"),
            ]
        }
        if currentCameraID == nil { currentCameraID = cameras.first?.id }
        await emit(.sessionOpen, C300XCodec.sessionOpen)
        persist()
    }

    /// Door Entry sign-in. The directory returns the plant and gateway for this email; the screen does not ask for them.
    func signIn(email: String, password: String, keepSignedIn: Bool = true) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !password.isEmpty else {
            lastReceipt = .rejected("Enter the email and password from Door Entry.")
            return
        }
        storesSession = keepSignedIn
        if keepSignedIn {
            rememberedEmail = email
            UserDefaults.standard.set(email, forKey: Self.rememberedEmailKey)
        }
        switch await directory.plants(email: email, password: password) {
        case .failure(let failure):
            lastReceipt = .rejected(failure.message)
        case .success(let plants):
            guard let plant = plants.first else {
                lastReceipt = .rejected(DoorEntrySignInFailure.noPlant.message)
                return
            }
            await associate(account: email, plantID: plant.plantID, gatewayID: plant.gatewayID)
            await connectSip(plantID: plant.plantID, gatewayID: plant.gatewayID)
        }
    }

    /// Reads the SIP account for the signed-in gateway and registers it. Requires a registrar and
    /// a directory that can provision SIP (the live `EliotDirectory`); otherwise it is a no-op.
    ///
    /// Door Entry refuses to register without a client certificate, so the certificate is
    /// provisioned first when the directory can do it. A provisioning failure leaves the
    /// registrar unregistered rather than reporting the sign-in as failed.
    private func connectSip(plantID: String, gatewayID: String) async {
        guard let registrar, let credentials = directory as? SipCredentials else { return }
        do {
            if let certificate = directory as? SipCertificateProvisioning {
                try? await certificate.ensureMaterial(deviceName: "doorline")
            }
            let account = try await credentials.sipAccount(plantID: plantID, gatewayID: gatewayID)
            registrar.register(account)
        } catch {
            // The registrar keeps its own state; a provisioning failure leaves it unregistered
            // rather than reporting the sign-in as failed.
        }
    }

    func signOut() {
        association = .signedOut
        call = CallState()
        cameras = []
        currentCameraID = nil
        playingMessageID = nil
        registrar?.unregister()
        persist()
    }

    func receiveRing(caller: String) async {
        guard link != nil else { return }
        guard call.phase == .idle || call.phase == .declined else { return }
        call = CallState(phase: .ringing, direction: .incoming, audioLive: false, videoLive: false, caller: caller)
        record(.call, caller)
        if professionalStudio {
            await releaseDoorLock()
        }
        persist()
    }

    func answer() async {
        guard call.phase == .ringing else { return }
        call.phase = .active
        call.audioLive = true
        call.videoLive = true
        registrar?.answer()
        await emit(.callAnswer, C300XCodec.answer(plant: link?.plantID ?? ""))
    }

    func decline() async {
        guard call.phase == .ringing else { return }
        call.phase = .declined
        call.audioLive = false
        call.videoLive = false
        registrar?.decline()
        await emit(.callDecline, C300XCodec.decline(plant: link?.plantID ?? ""))
    }

    func endCall() {
        guard call.phase == .active || call.phase == .declined else { return }
        call = CallState()
        registrar?.endCall()
    }

    func callHome() async {
        guard link != nil, call.phase == .idle || call.phase == .declined else { return }
        call = CallState(phase: .active, direction: .callHome, audioLive: true, videoLive: false, caller: "Internal unit")
        record(.call, "Internal unit")
        registrar?.callHome()
        await emit(.callHome, C300XCodec.callHome(plant: link?.plantID ?? ""))
        persist()
    }

    /// Sets the panel address the OWN frames are sent to. The session-open handshake is a
    /// separate step so editing the field does not reconnect per keystroke.
    func setPanelHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard trimmed != panelHost else { return }
        panelHost = trimmed
        router?.setPanelHost(trimmed)
        persist()
    }

    func openPanelSession() async {
        guard !panelHost.isEmpty else { return }
        await emit(.sessionOpen, C300XCodec.sessionOpen)
    }

    func selectCamera(_ id: String) async {
        guard link != nil, cameras.contains(where: { $0.id == id }) else { return }
        currentCameraID = id
        await emit(.camera, C300XCodec.cameraOn(address: id))
        persist()
    }

    func releaseDoorLock() async {
        guard link != nil else { return }
        record(.unlock, "Door lock")
        // Door Entry sends the lock as `vde_doorlock_entr_*` over SIP MESSAGE when the
        // panel is not on the local bus; the OWN frame stays for the local link.
        registrar?.sendMessage("vde_doorlock_entr_remote")
        await emit(.doorLock, C300XCodec.doorLock())
        persist()
    }

    func releaseActuator() async {
        guard link != nil else { return }
        await emit(.actuator, C300XCodec.actuator())
    }

    func setAnsweringMachineEnabled(_ enabled: Bool) async {
        guard link != nil else { return }
        answeringMachineEnabled = enabled
        // Door Entry sends the switch over the SIP MESSAGE channel as `vde_aswm_enabled`
        // / `vde_aswm_disabled`; the bus frame stays for a direct link.
        registrar?.sendMessage(enabled ? "vde_aswm_enabled" : "vde_aswm_disabled")
        await emit(.answeringMachine, C300XCodec.answeringMachine(enabled: enabled))
        persist()
    }

    func ingestMessages(_ wire: String) {
        let parsed = C300XCodec.parseMessages(wire)
        guard !parsed.isEmpty else { return }
        messages = parsed
        if let playingMessageID, !messages.contains(where: { $0.id == playingMessageID }) {
            self.playingMessageID = nil
        }
        persist()
    }

    func playMessage(_ id: String) async {
        guard messages.contains(where: { $0.id == id }) else { return }
        playingMessageID = id
        registrar?.sendMessage("ACTION action_aswm_play id=\(id)")
        await emit(.playMessage, C300XCodec.playMessage(id: id))
    }

    func setForwarding(_ mode: ForwardingMode) async {
        guard let link else { return }
        forwarding = mode
        await emit(.callForward, C300XCodec.forwarding(mode, plant: link.plantID, gateway: link.gatewayID))
        persist()
    }

    func setProfessionalStudio(_ enabled: Bool) async {
        guard let link else { return }
        professionalStudio = enabled
        await emit(.professionalStudio, C300XCodec.professionalStudio(enabled: enabled, plant: link.plantID, gateway: link.gatewayID))
        persist()
    }

    private static let rememberedEmailKey = "doorline.remembered-email"

    private func emit(_ kind: C300XFrame.Kind, _ wire: String) async {
        let frame = C300XFrame(kind: kind, wire: wire)
        sent.append(frame)
        lastReceipt = await transport.send(frame)
    }

    private func record(_ kind: HistoryEntry.Kind, _ detail: String) {
        history.insert(HistoryEntry(id: UUID(), date: now(), kind: kind, detail: detail), at: 0)
    }

    private func persist() {
        guard storesSession else {
            shelf.save(Classe300XSnapshot())
            return
        }
        var snapshot = Classe300XSnapshot()
        if let link {
            snapshot.account = link.account
            snapshot.plantID = link.plantID
            snapshot.gatewayID = link.gatewayID
        }
        snapshot.panelHost = panelHost
        snapshot.forwarding = forwarding
        snapshot.professionalStudio = professionalStudio
        snapshot.answeringMachineEnabled = answeringMachineEnabled
        snapshot.history = history
        snapshot.messages = messages
        snapshot.currentCameraID = currentCameraID
        shelf.save(snapshot)
    }

    private func restore(_ snapshot: Classe300XSnapshot) {
        let account = snapshot.account.trimmingCharacters(in: .whitespacesAndNewlines)
        let plantID = snapshot.plantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let gatewayID = snapshot.gatewayID.trimmingCharacters(in: .whitespacesAndNewlines)
        if account.isEmpty || plantID.isEmpty || gatewayID.isEmpty {
            association = .signedOut
        } else {
            association = .saved(AccountLink(account: account, plantID: plantID, gatewayID: gatewayID))
            cameras = [
                EntranceCamera(id: C300XCodec.entranceCameraAddress, name: "Entrance"),
                EntranceCamera(id: C300XCodec.secondaryCameraAddress, name: "Secondary"),
            ]
        }
        panelHost = snapshot.panelHost
        router?.setPanelHost(snapshot.panelHost)
        forwarding = snapshot.forwarding
        professionalStudio = snapshot.professionalStudio
        answeringMachineEnabled = snapshot.answeringMachineEnabled
        history = snapshot.history
        messages = snapshot.messages
        currentCameraID = snapshot.currentCameraID ?? cameras.first?.id
    }
}
