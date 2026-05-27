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
                if windowState.viewingTrash {
                    trashList
                } else {
                    notesList
                }
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
                // Creating a new note implies wanting the active list,
                // so leave the Trash view if we're in it.
                windowState.viewingTrash = false
                store.newNote()
            }

            // Search doesn't make sense while viewing Trash — hide it.
            if !windowState.viewingTrash {
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
        let visible = store.filteredNotes(
            matching: windowState.searchText,
            tag: windowState.selectedTag
        )
        let pinned = visible.filter { $0.isPinned }
        let regular = visible.filter { !$0.isPinned }

        return VStack(spacing: 0) {
            tagFilterStrip

            Divider()
                .opacity(0.4)
                .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if !pinned.isEmpty {
                        sectionHeader("Pinned")
                        ForEach(pinned) { note in noteListRow(note) }
                        if !regular.isEmpty {
                            sectionHeader("Notes")
                                .padding(.top, 8)
                        }
                    }
                    ForEach(regular) { note in noteListRow(note) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func noteListRow(_ note: Note) -> some View {
        NoteListRow(noteId: note.id)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.palette.secondaryText)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    // Horizontal strip of every tag in the store. Tap to filter the list
    // to that tag; tap again (or the × on the selected chip) to clear.
    private var tagFilterStrip: some View {
        let tags = store.allTags
        return Group {
            if tags.isEmpty && windowState.selectedTag == nil {
                EmptyView()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let selected = windowState.selectedTag {
                            FilterTagChip(text: "#\(selected)", isActive: true) {
                                windowState.selectedTag = nil
                            }
                        }
                        ForEach(tags, id: \.self) { tag in
                            if tag != windowState.selectedTag {
                                FilterTagChip(text: "#\(tag)", isActive: false) {
                                    windowState.selectedTag = tag
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                }
            }
        }
    }

    // MARK: – Trash list (expanded only)

    private var trashList: some View {
        let trashed = store.trashedNotes
        return VStack(spacing: 0) {
            HStack {
                Text("Trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.palette.secondaryText)
                    .tracking(0.5)
                Spacer()
                if !trashed.isEmpty {
                    Button("Empty") {
                        store.emptyTrash()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.palette.secondaryText)
                    .help("Permanently delete all trashed notes")
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider()
                .opacity(0.4)
                .padding(.bottom, 4)

            if trashed.isEmpty {
                Text("Trash is empty")
                    .font(.system(size: 12))
                    .foregroundColor(theme.palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(trashed) { note in
                            NoteRow(note: note, isActive: false, query: "")
                                .opacity(0.65)
                                .contentShape(Rectangle())
                                .contextMenu {
                                    Button {
                                        store.restoreNote(note.id)
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                    }
                                    Button(role: .destructive) {
                                        store.permanentlyDeleteNote(note.id)
                                    } label: {
                                        Label("Delete Forever", systemImage: "trash.fill")
                                    }
                                }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: – Bottom actions

    private var bottomActions: some View {
        VStack(spacing: 4) {
            SidebarRow(
                icon: windowState.viewingTrash ? "trash.fill" : "trash",
                label: "Trash",
                expanded: isExpanded,
                isActive: windowState.viewingTrash,
                tooltip: "Trash"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    windowState.viewingTrash.toggle()
                    // Entering Trash with a collapsed sidebar leaves
                    // nothing visible — auto-expand so the list shows.
                    if windowState.viewingTrash {
                        windowState.sidebarOpen = true
                    }
                }
            }

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

// One row in the sidebar's notes list. Lives as its own View struct (rather
// than a function in SidebarIconBar) so it has stable SwiftUI identity and
// observes the store directly. The `.id("\(noteId)-\(isPinned)")` modifier
// is the load-bearing fix for the stale-menu bug: SwiftUI's macOS
// `.contextMenu` caches its label content and doesn't always re-render
// when the parent body does, so changing the row's identity on every pin
// toggle forces SwiftUI to discard the cached menu and build a fresh one.
struct NoteListRow: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var windowState: WindowState
    let noteId: UUID

    var body: some View {
        // Look up the note live each render so we never read a stale snapshot.
        let liveNote = store.notes.first(where: { $0.id == noteId }) ?? Note(id: noteId)
        let pinned = liveNote.isPinned

        return NoteRow(
            note: liveNote,
            isActive: noteId == store.activeTabId,
            query: windowState.searchText
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectNote(noteId)
        }
        .contextMenu {
            Button {
                store.togglePin(noteId)
            } label: {
                Label(pinned ? "Unpin" : "Pin",
                      systemImage: pinned ? "pin.slash" : "pin")
            }
            Divider()
            Button(role: .destructive) {
                store.deleteNote(noteId)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
        .id("\(noteId.uuidString)-\(pinned)")
    }
}

// Compact chip used in the tag filter strip at the top of the notes list.
struct FilterTagChip: View {
    @EnvironmentObject var theme: ThemeStore
    let text: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isActive ? theme.palette.text : theme.palette.secondaryText)
                if isActive {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.palette.secondaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isActive ? theme.palette.activeRowBackground : theme.palette.searchFieldBackground,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}
