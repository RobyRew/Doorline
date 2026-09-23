import AppIntents
import SwiftUI

struct UnlockEntranceIntent: AppIntent {
    static var title: LocalizedStringResource = "Open the door"
    static var description = IntentDescription("Unlocks the lock you chose in Doorline.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = await HomeStore.shared
        await store.waitUntilReady()
        guard await store.lock != nil else {
            return .result(dialog: "No lock is selected in Doorline.")
        }
        await store.setLocked(false)
        if let error = await store.lastError {
            return .result(dialog: "Could not open it. \(error)")
        }
        return .result(dialog: "Opening the door.")
    }
}

struct LockEntranceIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock the door"
    static var description = IntentDescription("Locks the lock you chose in Doorline.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = await HomeStore.shared
        await store.waitUntilReady()
        guard await store.lock != nil else {
            return .result(dialog: "No lock is selected in Doorline.")
        }
        await store.setLocked(true)
        if let error = await store.lastError {
            return .result(dialog: "Could not lock it. \(error)")
        }
        return .result(dialog: "Locking the door.")
    }
}

struct DoorStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Door status"
    static var description = IntentDescription("Reads the lock and the door sensor from Home.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = await HomeStore.shared
        await store.waitUntilReady()
        let lock = await store.lockState().rawValue
        let leaf = await store.contactState().rawValue
        return .result(dialog: "Lock is \(lock). Leaf is \(leaf).")
    }
}

struct ShowEntranceIntent: AppIntent {
    static var title: LocalizedStringResource = "Show the entrance"
    static var description = IntentDescription("Opens Doorline on the entrance camera.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Showing the entrance.")
    }
}

struct DoorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UnlockEntranceIntent(),
            phrases: [
                "Open the door with \(.applicationName)",
                "Unlock the entrance with \(.applicationName)"
            ],
            shortTitle: "Open the door",
            systemImageName: "lock.open"
        )
        AppShortcut(
            intent: LockEntranceIntent(),
            phrases: [
                "Lock the door with \(.applicationName)"
            ],
            shortTitle: "Lock the door",
            systemImageName: "lock"
        )
        AppShortcut(
            intent: DoorStatusIntent(),
            phrases: [
                "Is the door open in \(.applicationName)",
                "Check the door with \(.applicationName)"
            ],
            shortTitle: "Door status",
            systemImageName: "door.left.hand.open"
        )
        AppShortcut(
            intent: ShowEntranceIntent(),
            phrases: [
                "Show the entrance in \(.applicationName)"
            ],
            shortTitle: "Show entrance",
            systemImageName: "video"
        )
    }
}

extension HomeStore {
    static let shared = HomeStore()

    func waitUntilReady() async {
        if ready { return }
        for _ in 0..<20 {
            if ready { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }
}
