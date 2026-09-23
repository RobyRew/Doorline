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

    private let transport: C300XTransport
    private let shelf: Classe300XShelf
    private let now: () -> Date

    init(
        transport: C300XTransport = PortalTransport(),
        shelf: Classe300XShelf = UserDefaultsShelf(),
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.shelf = shelf
        self.now = now
        restore(shelf.load())
    }

    static let shared = Classe300XSession()

    var currentCamera: EntranceCamera? {
        cameras.first { $0.id == currentCameraID }
    }

    var link: AccountLink? {
        if case .saved(let link) = association { return link }
        return nil
    }

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

    func signOut() {
        association = .signedOut
        call = CallState()
        cameras = []
        currentCameraID = nil
        playingMessageID = nil
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
        guard call.phase == .ringing, let link else { return }
        call.phase = .active
        call.audioLive = true
        call.videoLive = true
        await emit(.callAnswer, C300XCodec.answer(plant: link.plantID))
    }

    func decline() async {
        guard call.phase == .ringing, let link else { return }
        call.phase = .declined
        call.audioLive = false
        call.videoLive = false
        await emit(.callDecline, C300XCodec.decline(plant: link.plantID))
    }

    func endCall() {
        guard call.phase == .active || call.phase == .declined else { return }
        call = CallState()
    }

    func callHome() async {
        guard let link, call.phase == .idle || call.phase == .declined else { return }
        call = CallState(phase: .active, direction: .callHome, audioLive: true, videoLive: false, caller: "Internal unit")
        record(.call, "Internal unit")
        await emit(.callHome, C300XCodec.callHome(plant: link.plantID))
        persist()
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

    private func emit(_ kind: C300XFrame.Kind, _ wire: String) async {
        let frame = C300XFrame(kind: kind, wire: wire)
        sent.append(frame)
        lastReceipt = await transport.send(frame)
    }

    private func record(_ kind: HistoryEntry.Kind, _ detail: String) {
        history.insert(HistoryEntry(id: UUID(), date: now(), kind: kind, detail: detail), at: 0)
    }

    private func persist() {
        var snapshot = Classe300XSnapshot()
        if let link {
            snapshot.account = link.account
            snapshot.plantID = link.plantID
            snapshot.gatewayID = link.gatewayID
        }
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
        forwarding = snapshot.forwarding
        professionalStudio = snapshot.professionalStudio
        answeringMachineEnabled = snapshot.answeringMachineEnabled
        history = snapshot.history
        messages = snapshot.messages
        currentCameraID = snapshot.currentCameraID ?? cameras.first?.id
    }
}
