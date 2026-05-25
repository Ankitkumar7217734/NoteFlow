import Foundation
import SwiftUI

// Per-window UI state. The shared NoteStore.shared owns the data (notes,
// open tabs, active note); each NSWindow / NSPanel that hosts a ContentView
// gets its own WindowState so opening the sidebar in the main window
// doesn't also open it in the floating panel, etc.
final class WindowState: ObservableObject {
    @Published var sidebarOpen = false
    @Published var formattingVisible = false
    @Published var searchText = ""
    /// Flip to true to ask the sidebar's search TextField to take keyboard
    /// focus. The sidebar resets it back to false once focus is granted.
    @Published var searchFocusRequested = false
}
