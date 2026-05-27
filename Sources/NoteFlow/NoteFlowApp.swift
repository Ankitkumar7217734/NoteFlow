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
    }
}
