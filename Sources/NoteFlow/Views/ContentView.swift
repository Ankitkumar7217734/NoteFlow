import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeStore
    /// Per-window UI state (sidebar open, search text, formatting toolbar).
    /// Each ContentView instance gets its own, so toggling in the main
    /// window doesn't toggle in the floating panel.
    @StateObject private var windowState = WindowState()
    /// True only for the main window (which has macOS traffic-light buttons
    /// in its title bar). The floating panel passes false.
    var inTitledWindow: Bool = false
    /// True when this ContentView is hosted inside the floating NSPanel,
    /// so the tab bar can hide the expand button and route the close
    /// action to dismissing the panel rather than closing the main window.
    var isFloatingPanel: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Title bar / tab bar ──────────────────────────────────
            TabBarView(
                needsTrafficLightSpace: inTitledWindow,
                isFloatingPanel: isFloatingPanel
            )
                .environmentObject(store)

            Rectangle()
                .fill(theme.palette.dividerColor)
                .frame(height: 1)

            // ── Body ─────────────────────────────────────────────────
            HStack(spacing: 0) {
                // Unified sidebar: collapses to an icon rail, expands to
                // icons + labels + the notes list as one continuous panel.
                SidebarIconBar()
                    .environmentObject(store)

                Rectangle()
                    .fill(theme.palette.dividerColor)
                    .frame(width: 1)

                // Main editor area
                Group {
                    if let note = store.activeNote {
                        VStack(spacing: 0) {
                            // Editor fills available space
                            NoteEditorView(note: note)
                                .id(note.id)
                                .environmentObject(store)
                                .background(theme.palette.editorBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.top, 12)
                                .padding(.trailing, 16)
                                .padding(.bottom, windowState.formattingVisible ? 0 : 16)

                            // Formatting toolbar
                            if windowState.formattingVisible {
                                FormattingToolbarView()
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 12)
                                    )
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    } else {
                        EmptyEditorPlaceholder()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.palette.chromeBackground)
        .preferredColorScheme(theme.palette.colorScheme)
        // Let the tab bar overlap the macOS title-bar area so the traffic
        // lights and the tabs/icons sit on the same row.
        .ignoresSafeArea(.all, edges: .top)
        .environmentObject(windowState)
        .onAppear {
            if store.activeNote == nil { store.newNote() }
        }
    }
}

struct EmptyEditorPlaceholder: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No note selected")
                .foregroundColor(.secondary)
            Button("New Note") { store.newNote() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
