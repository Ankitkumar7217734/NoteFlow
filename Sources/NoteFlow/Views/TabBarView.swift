import SwiftUI
import AppKit

// NoteFlow logo — uses AppLogo.processed (already cropped to the alpha
// bounding box and clipped to a 22% rounded-corner squircle). The image
// is pre-rendered once at full resolution, so SwiftUI just downsamples
// it crisply with .interpolation(.high).
struct NoteFlowLogo: View {
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: AppLogo.processed)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct TabBarView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var windowState: WindowState
    /// In the main window we reserve ~70pt of leading space so the macOS
    /// red/yellow/green buttons don't overlap the logo and tabs.
    var needsTrafficLightSpace: Bool = false
    /// True when this tab bar lives inside the floating panel. Used to hide
    /// the expand-to-full button and to route the close (✕) button to
    /// dismissing the panel instead of closing the main window.
    var isFloatingPanel: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // App logo
            NoteFlowLogo(size: 22)
                .padding(.leading, needsTrafficLightSpace ? 78 : 8)
                .padding(.trailing, 6)

            // Sidebar toggle — only in the floating panel, which otherwise
            // has no sidebar rail (ContentView hides it for maximum text
            // width). This reveals the notes list (SidebarIconBar) so the
            // user can browse / switch notes without expanding to the full
            // window. The main window's sidebar has its own toggle in the
            // rail, so this button isn't needed there.
            if isFloatingPanel {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        windowState.sidebarOpen.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(windowState.sidebarOpen
                                         ? theme.palette.text
                                         : theme.palette.iconColor)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.001))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(windowState.sidebarOpen ? "Hide Notes" : "Show Notes")
                .padding(.trailing, 2)
            }

            // Scrollable tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.openTabs) { note in
                        TabChip(note: note, isActive: note.id == store.activeTabId)
                    }
                }
                .padding(.vertical, 6)
            }

            // New tab
            Button { store.newNote() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.palette.iconColor)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            Spacer()

            // Expand & close
            HStack(spacing: 10) {
                // The floating panel has no sidebar rail, so the Text
                // Formatting toggle lives here instead.
                if isFloatingPanel {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            windowState.formattingVisible.toggle()
                        }
                    } label: {
                        Text("AA")
                            .font(.system(size: 12, weight: windowState.formattingVisible ? .bold : .regular))
                            .foregroundColor(windowState.formattingVisible
                                             ? theme.palette.text
                                             : theme.palette.iconColor)
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.001))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Text Formatting")
                }

                // Expand-to-full only makes sense from the floating panel —
                // it dismisses the panel and brings the main window forward.
                // In the main window it would be a no-op.
                if isFloatingPanel {
                    Button {
                        DispatchQueue.main.async {
                            (NSApp.delegate as? AppDelegate)?.expandToFull()
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13))
                            .foregroundColor(theme.palette.iconColor)
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.001)) // makes the entire frame hit-testable
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Expand to Full App")
                }

                Button {
                    let floating = isFloatingPanel
                    // Defer so SwiftUI fully processes the click before
                    // anything tears the hosting view down.
                    DispatchQueue.main.async {
                        if floating {
                            closeFloatingPanel()
                        } else {
                            // Close the regular main window only — skip
                            // NSPanels so we never target the floating one.
                            NSApp.windows
                                .first(where: { $0.isVisible && !($0 is NSPanel) })?
                                .close()
                        }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13))
                        .foregroundColor(theme.palette.iconColor)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.001))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 14)
        }
        .frame(height: 38)
        .background(WindowDragView())
    }

    /// Close the floating panel reliably. Try the AppDelegate path first
    /// (it also restores the previously-active app), then force-close any
    /// NSPanel that's still on screen as a defensive backup. We've seen
    /// SwiftUI button actions in non-activating panels intermittently fail
    /// to reach AppDelegate, so the backup is essential.
    private func closeFloatingPanel() {
        (NSApp.delegate as? AppDelegate)?.toggleFloating()
        // If the panel is still visible (toggleFloating didn't fire, or
        // the flag was out of sync), bring it down manually.
        for window in NSApp.windows where (window is NSPanel) && window.isVisible {
            window.orderOut(nil)
        }
        if NoteStore.shared.isFloating {
            NoteStore.shared.isFloating = false
        }
    }
}

// Tap inactive tab to switch; tap active tab title to rename it
struct TabChip: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeStore
    let note: Note
    let isActive: Bool

    @State private var isEditing = false
    @State private var editTitle = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isActive && isEditing {
                TextField("", text: $editTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.palette.text)
                    .frame(minWidth: 60, maxWidth: 180)
                    .focused($fieldFocused)
                    .onSubmit { commitTitle() }
                    .onExitCommand { cancelEdit() }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commitTitle() }
                    }
            } else {
                Text(note.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundColor(isActive ? theme.palette.text : theme.palette.iconColorDim)
            }

            Button { store.closeTab(note.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.palette.iconColorDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? theme.palette.activeTabBackground : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isActive {
                editTitle = note.title
                isEditing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
            } else {
                store.activeTabId = note.id
            }
        }
        .contextMenu {
            ExportSubmenu(noteId: note.id)
            Divider()
            Button {
                store.closeTab(note.id)
            } label: {
                Label("Close Tab", systemImage: "xmark")
            }
        }
    }

    private func commitTitle() {
        let trimmed = editTitle.trimmingCharacters(in: .whitespaces)
        store.updateNote(id: note.id, title: trimmed.isEmpty ? "Untitled" : trimmed)
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
    }
}

struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableView { DraggableView() }
    func updateNSView(_ nsView: DraggableView, context: Context) {}

    class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
