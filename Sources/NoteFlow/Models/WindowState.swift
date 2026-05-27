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
    /// When true, the sidebar's notes list shows trashed notes (with
    /// Restore / Delete Forever actions) instead of the active set. The
    /// search field is hidden in this mode.
    @Published var viewingTrash = false
    /// Non-nil filters the sidebar's notes list to only notes carrying
    /// this tag. Per-window so the floating panel can keep its own filter.
    @Published var selectedTag: String? = nil
}
