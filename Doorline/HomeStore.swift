import Foundation
import Observation

struct DoorPick: Codable, Equatable, Sendable {
    var homeID: UUID?
    var lockID: UUID?
    var cameraID: UUID?
    var contactID: UUID?
}

enum LockReadout: String {
    case secured = "Locked"
    case unsecured = "Unlocked"
    case jammed = "Jammed"
    case unknown = "No reading"
    case missing = "No lock in Home"
}

enum ContactReadout: String {
    case closed = "Closed"
    case open = "Open"
    case unknown = "No reading"
    case missing = "No contact sensor"
}

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

#if canImport(HomeKit)
import HomeKit

@MainActor
@Observable
final class HomeStore: NSObject, HMHomeManagerDelegate {
    private let manager: HMHomeManager
    private(set) var homes: [HMHome] = []
    private(set) var ready = false
    var lastError: String?

    var pick: DoorPick {
        didSet { save() }
    }

    override init() {
        manager = HMHomeManager()
        pick = Self.load()
        super.init()
        manager.delegate = self
    }

    var authorized: Bool {
        manager.authorizationStatus == .authorized
    }

    var hasLock: Bool { lock != nil }

    var home: HMHome? {
        if let id = pick.homeID, let match = homes.first(where: { $0.uniqueIdentifier == id }) {
            return match
        }
        return homes.first
    }

    var locks: [HMAccessory] {
        accessories(in: home, service: HMServiceTypeLockMechanism)
    }

    var cameras: [HMAccessory] {
        (home?.accessories ?? []).filter { accessory in
            // Xcode 26 imports cameraProfiles as optional. Xcode 16.4 does not.
            #if compiler(>=6.2)
            !(accessory.cameraProfiles?.isEmpty ?? true)
            #else
            !accessory.cameraProfiles.isEmpty
            #endif
        }
    }

    var contacts: [HMAccessory] {
        accessories(in: home, service: HMServiceTypeContactSensor)
    }

    var lock: HMAccessory? { resolve(locks, pick.lockID) }
    var camera: HMAccessory? { resolve(cameras, pick.cameraID) }
    var contact: HMAccessory? { resolve(contacts, pick.contactID) }

    func refresh() {
        homes = manager.homes
        bindHomes()
        ready = true
        ensureDefaults()
    }

    func choose(home: HMHome) {
        pick.homeID = home.uniqueIdentifier
        pick.lockID = nil
        pick.cameraID = nil
        pick.contactID = nil
        ensureDefaults()
    }

    func setLocked(_ locked: Bool) async {
        guard let characteristic = lockCharacteristic(target: true) else {
            lastError = "No lock is selected in Home."
            return
        }
        let value = locked
            ? HMCharacteristicValueLockMechanismState.secured.rawValue
            : HMCharacteristicValueLockMechanismState.unsecured.rawValue
        do {
            try await write(characteristic, value: value)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func lockState() -> LockReadout {
        let current = lockCharacteristic(target: false)
        let raw = current?.value as? Int ?? -1
        switch raw {
        case HMCharacteristicValueLockMechanismState.secured.rawValue:
            return .secured
        case HMCharacteristicValueLockMechanismState.unsecured.rawValue:
            return .unsecured
        case HMCharacteristicValueLockMechanismState.jammed.rawValue:
            return .jammed
        default:
            return lock == nil ? .missing : .unknown
        }
    }

    func contactState() -> ContactReadout {
        guard let service = contact?.services.first(where: { $0.serviceType == HMServiceTypeContactSensor }),
              let characteristic = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeContactState }),
              let raw = characteristic.value as? Int else {
            return contact == nil ? .missing : .unknown
        }
        // Contact detected means the magnet is together: the leaf is closed.
        return raw == HMCharacteristicValueContactState.detected.rawValue ? .closed : .open
    }

    func snapshot() async -> PlatformImage? {
        let control: HMCameraSnapshotControl?
        #if compiler(>=6.2)
        control = camera?.cameraProfiles?.first?.snapshotControl
        #else
        control = camera?.cameraProfiles.first?.snapshotControl
        #endif
        guard let control else { return nil }
        return await SnapshotCapture.take(control)
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            self.refresh()
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in
            self.refresh()
        }
    }

    private func bindHomes() {
        for home in homes {
            home.delegate = self
        }
    }

    private func ensureDefaults() {
        guard let home else { return }
        if pick.homeID == nil { pick.homeID = home.uniqueIdentifier }
        if pick.lockID == nil { pick.lockID = locks.first?.uniqueIdentifier }
        if pick.cameraID == nil { pick.cameraID = cameras.first?.uniqueIdentifier }
        if pick.contactID == nil { pick.contactID = contacts.first?.uniqueIdentifier }
    }

    private func accessories(in home: HMHome?, service: String) -> [HMAccessory] {
        (home?.accessories ?? []).filter { accessory in
            accessory.services.contains { $0.serviceType == service }
        }
    }

    private func resolve(_ list: [HMAccessory], _ id: UUID?) -> HMAccessory? {
        if let id, let match = list.first(where: { $0.uniqueIdentifier == id }) { return match }
        return list.first
    }

    private func lockCharacteristic(target: Bool) -> HMCharacteristic? {
        let type = target ? HMCharacteristicTypeTargetLockMechanismState : HMCharacteristicTypeCurrentLockMechanismState
        return lock?
            .services.first { $0.serviceType == HMServiceTypeLockMechanism }?
            .characteristics.first { $0.characteristicType == type }
    }

    private func write(_ characteristic: HMCharacteristic, value: Any) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(value) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static let key = "doorline.pick"

    private static func load() -> DoorPick {
        guard let data = UserDefaults.standard.data(forKey: key),
              let pick = try? JSONDecoder().decode(DoorPick.self, from: data) else {
            return DoorPick()
        }
        return pick
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pick) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

extension HomeStore: HMHomeDelegate {
    // Swift imported the ObjC selector home:didUpdateHomeHubState: as home(_:didUpdate:).
    // The old Swift name is an error on the Xcode 16.4 CI toolchain.
    nonisolated func home(_ home: HMHome, didUpdate homeHubState: HMHomeHubState) {}

    nonisolated func homeDidUpdateName(_ home: HMHome) {
        Task { @MainActor in refresh() }
    }
}

private final class SnapshotCapture: NSObject, HMCameraSnapshotControlDelegate {
    private static var inflight: [SnapshotCapture] = []

    private var continuation: CheckedContinuation<PlatformImage?, Never>?
    private var control: HMCameraSnapshotControl?

    static func take(_ control: HMCameraSnapshotControl) async -> PlatformImage? {
        let capture = SnapshotCapture()
        inflight.append(capture)
        return await withCheckedContinuation { continuation in
            capture.continuation = continuation
            capture.control = control
            control.delegate = capture
            control.takeSnapshot()
        }
    }

    func cameraSnapshotControl(_ cameraSnapshotControl: HMCameraSnapshotControl, didTake snapshot: HMCameraSnapshot?, error: Error?) {
        continuation?.resume(returning: snapshot?.platformImage)
        continuation = nil
        control?.delegate = nil
        Self.inflight.removeAll { $0 === self }
    }

    func cameraSnapshotControlDidUpdateMostRecentSnapshot(_ cameraSnapshotControl: HMCameraSnapshotControl) {}
}

private extension HMCameraSnapshot {
    var platformImage: PlatformImage? {
        // The public still is `image` on the Xcode 16 SDK. This SDK's header does not declare it.
        #if compiler(>=6.2)
        nil
        #else
        image
        #endif
    }
}

#else

/// Native macOS has no public HomeKit module. The iPhone and iPad target keeps the real store.
@MainActor
@Observable
final class HomeStore {
    private(set) var ready = true
    var lastError: String?
    var hasLock: Bool { false }

    func refresh() {}

    func setLocked(_ locked: Bool) async {
        lastError = "Home accessories are available on iPhone and iPad."
    }

    func lockState() -> LockReadout { .missing }
    func contactState() -> ContactReadout { .missing }
    func snapshot() async -> PlatformImage? { nil }
}

#endif
