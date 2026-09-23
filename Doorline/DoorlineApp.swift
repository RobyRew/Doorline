import SwiftUI

@main
struct DoorlineApp: App {
    var body: some Scene {
        WindowGroup {
            EntranceView()
                .environment(HomeStore.shared)
                .frame(minWidth: 420, minHeight: 640)
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Refresh Home") {
                    HomeStore.shared.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        #if os(macOS)
        Settings {
            PreferencesView()
                .environment(HomeStore.shared)
                .frame(width: 420, height: 360)
        }
        #endif
    }
}
