import SwiftUI

@main
struct NoteFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var theme = ThemeStore.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(theme)
                .preferredColorScheme(theme.palette.colorScheme)
        }
        .commands {
            // File ▸ Import… (⌘O) — the menu twin of the sidebar Import row.
            CommandGroup(after: .newItem) {
                Button("Import…") {
                    NoteStore.shared.importFiles()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
