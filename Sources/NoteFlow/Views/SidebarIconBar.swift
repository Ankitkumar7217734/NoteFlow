import SwiftUI

// Unified sidebar. In the collapsed state it shows a column of icon
// buttons. In the expanded state (store.sidebarOpen == true) it widens, the
// icons gain text labels next to them, the search icon swaps for an inline
// search field, and the notes list fills the middle — so the whole thing
// reads as one panel rather than an icon rail plus a separate overlay.
struct SidebarIconBar: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var windowState: WindowState
    @EnvironmentObject var theme: ThemeStore
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool

    private var isExpanded: Bool { windowState.sidebarOpen }

    var body: some View {
        VStack(spacing: 0) {
            topActions

            if isExpanded {
                notesList
            } else {
                Spacer(minLength: 0)
            }

            bottomActions
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(width: isExpanded ? 248 : 52)
        .onAppear {
            if windowState.searchFocusRequested {
                searchFocused = true
                windowState.searchFocusRequested = false
            }
        }
        .onChange(of: windowState.searchFocusRequested) { _, requested in
            guard requested else { return }
            searchFocused = true
            windowState.searchFocusRequested = false
        }
    }

    // MARK: – Top actions: toggle, new note, search

    private var topActions: some View {
        VStack(spacing: 4) {
            SidebarRow(
                icon: "sidebar.left",
                label: isExpanded ? "Collapse Notes" : "Show Notes",
                expanded: isExpanded,
                isActive: isExpanded,
                tooltip: "Show Notes"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    windowState.sidebarOpen.toggle()
                }
            }

            SidebarRow(
                icon: "square.and.pencil",
                label: "New note",
                expanded: isExpanded,
                tooltip: "New Note"
            ) {
                store.newNote()
            }

            if isExpanded {
                searchField
            } else {
                SidebarRow(
                    icon: "magnifyingglass",
                    label: "Search",
                    expanded: false,
                    isActive: !windowState.searchText.isEmpty,
                    tooltip: "Search"
                ) {
                    windowState.sidebarOpen = true
                    DispatchQueue.main.async {
                        windowState.searchFocusRequested = true
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.palette.iconColorDim)
            TextField("Search notes…", text: $windowState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.palette.text)
                .focused($searchFocused)
            if !windowState.searchText.isEmpty {
                Button { windowState.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.palette.iconColorDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.palette.searchFieldBackground, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 4)
    }

    // MARK: – Notes list (expanded only)

    private var notesList: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.4)
                .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.filteredNotes(matching: windowState.searchText)) { note in
                        NoteRow(
                            note: note,
                            isActive: note.id == store.activeTabId,
                            query: windowState.searchText
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.selectNote(note.id)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                store.deleteNote(note.id)
                            } label: {
                                Label("Delete Note", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: – Bottom actions

    private var bottomActions: some View {
        VStack(spacing: 4) {
            SidebarRow(
                icon: "gearshape",
                label: "Settings",
                expanded: isExpanded,
                tooltip: "Settings"
            ) {
                openSettings()
            }

            SidebarRow(
                text: "AA",
                label: "Text Formatting",
                expanded: isExpanded,
                isActive: windowState.formattingVisible,
                tooltip: "Text Formatting"
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    windowState.formattingVisible.toggle()
                }
            }
        }
    }
}

// One row of the sidebar. Icon (or short text like "AA") sits in a 36×36
// rounded slot; when the sidebar is expanded, a label appears next to it.
struct SidebarRow: View {
    @EnvironmentObject var theme: ThemeStore
    var icon: String? = nil
    var text: String? = nil
    let label: String
    let expanded: Bool
    var isActive: Bool = false
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(isActive ? theme.palette.text : theme.palette.iconColorDim)
                    } else if let text = text {
                        Text(text)
                            .font(.system(size: 13, weight: isActive ? .bold : .regular))
                            .foregroundColor(isActive ? theme.palette.text : theme.palette.iconColorDim)
                    }
                }
                .frame(width: 36, height: 36)
                .background(
                    isActive ? theme.palette.activeRowBackground : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )

                if expanded {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundColor(theme.palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
