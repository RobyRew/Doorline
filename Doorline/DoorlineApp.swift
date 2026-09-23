import SwiftUI

@main
struct DoorlineApp: App {
    var body: some Scene {
        WindowGroup {
            DoorlineRootView()
                .environment(Classe300XSession.shared)
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
            ClasseSettingsView()
                .environment(Classe300XSession.shared)
                .frame(width: 420, height: 480)
        }
        #endif
    }
}
