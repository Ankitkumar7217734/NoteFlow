import SwiftUI

// API Key Manager — one page per `.apiManager` note. Uses the same Paper & Ink
// palette as the rest of the app. Each provider card stacks: provider name on
// top, base URL next, then API keys below with + to add more.
struct APIManagerView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeStore
    let noteId: UUID
    var compact: Bool = false

    /// Provider id that should auto-focus its name field (just created).
    @State private var focusNameForProviderId: UUID?
    /// Provider id showing the paste field for a new key.
    @State private var addingKeyToProviderId: UUID?
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var note: Note {
        store.notes.first(where: { $0.id == noteId }) ?? Note(id: noteId)
    }
    private var providers: [APIProvider] { note.providers ?? [] }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Provider names, base URLs, and key labels — never secret values.
    private var filteredProviders: [APIProvider] {
        let query = trimmedSearch
        guard !query.isEmpty else { return providers }
        return providers.filter { provider in
            provider.name.localizedCaseInsensitiveContains(query)
                || provider.baseURL.localizedCaseInsensitiveContains(query)
                || provider.keys.contains { $0.label.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            ScrollView {
                VStack(spacing: 12) {
                    if !trimmedSearch.isEmpty && filteredProviders.isEmpty {
                        Text("No providers match “\(trimmedSearch)”.")
                            .font(.system(size: 13))
                            .foregroundColor(theme.palette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }

                    ForEach(filteredProviders) { provider in
                        ProviderCard(
                            noteId: noteId,
                            provider: provider,
                            compact: compact,
                            autoFocusName: focusNameForProviderId == provider.id,
                            isAddingKey: addingKeyToProviderId == provider.id,
                            onNameFocused: { focusNameForProviderId = nil },
                            onBeginAddKey: {
                                addingKeyToProviderId = provider.id
                                focusNameForProviderId = nil
                            },
                            onEndAddKey: { addingKeyToProviderId = nil }
                        )
                        .id(provider.id)
                    }

                    if trimmedSearch.isEmpty {
                        AddProviderCard(compact: compact, onAdd: createProvider)
                    }
                }
                .padding(.horizontal, compact ? 14 : 24)
                .padding(.vertical, compact ? 14 : 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.palette.iconColorDim)
            TextField("Search providers…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.palette.text)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.palette.iconColorDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.palette.searchFieldBackground, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, compact ? 14 : 24)
        .padding(.top, compact ? 14 : 20)
        .padding(.bottom, 8)
    }

    private func createProvider() {
        guard let id = store.addProvider(to: noteId) else { return }
        addingKeyToProviderId = nil
        // Defer focus until after the new card is in the view tree.
        DispatchQueue.main.async {
            focusNameForProviderId = id
        }
    }
}

// MARK: – Provider card

private struct ProviderCard: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeStore
    @ObservedObject private var menuBarPins = MenuBarPinStore.shared
    let noteId: UUID
    let provider: APIProvider
    var compact: Bool
    let autoFocusName: Bool
    let isAddingKey: Bool
    let onNameFocused: () -> Void
    let onBeginAddKey: () -> Void
    let onEndAddKey: () -> Void

    @State private var draftName = ""
    @State private var draftBaseURL = ""
    @State private var draftKey = ""
    @State private var isEditingName = false
    @State private var confirmingDelete = false
    @State private var urlCopied = false
    @FocusState private var nameFocused: Bool
    @FocusState private var baseURLFocused: Bool
    @FocusState private var keyFocused: Bool

    private var isUnnamed: Bool { provider.name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var showNameEditor: Bool { isUnnamed || isEditingName }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(theme.palette.dividerColor)
                .frame(height: 1)
            baseURLSection
            Rectangle()
                .fill(theme.palette.dividerColor)
                .frame(height: 1)
            keysSection
        }
        .background(theme.palette.searchFieldBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.palette.dividerColor, lineWidth: 1)
        )
        .onAppear {
            draftName = provider.name
            draftBaseURL = provider.baseURL
            if isUnnamed { isEditingName = true }
            if autoFocusName { focusNameField() }
        }
        .onChange(of: provider.baseURL) { _, new in
            if !baseURLFocused { draftBaseURL = new }
        }
        .onChange(of: autoFocusName) { _, shouldFocus in
            guard shouldFocus else { return }
            isEditingName = true
            draftName = provider.name
            focusNameField()
        }
        .onChange(of: isAddingKey) { _, adding in
            guard adding else { return }
            draftKey = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { keyFocused = true }
        }
    }

    // Provider name — top of the card.
    private var header: some View {
        HStack(spacing: 8) {
            if showNameEditor {
                nameEditor
            } else {
                Text(provider.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.palette.text)
                    .lineLimit(2)
                    .onTapGesture(count: 2) { beginRename() }
                    .help("Double-click to rename")

                Spacer(minLength: 4)

                Button {
                    menuBarPins.toggleProviderPin(provider.id)
                } label: {
                    Image(systemName: menuBarPins.isProviderPinned(provider.id) ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundColor(theme.palette.iconColorDim)
                }
                .buttonStyle(.plain)
                .help(menuBarPins.isProviderPinned(provider.id)
                      ? "Unpin provider from menu bar"
                      : "Pin provider to menu bar")

                Button { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(theme.palette.iconColorDim)
                }
                .buttonStyle(.plain)
                .help("Delete provider")
            }
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, 12)
        .confirmationDialog(
            "Delete “\(provider.name)” and its \(provider.keys.count) key\(provider.keys.count == 1 ? "" : "s")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Provider", role: .destructive) {
                store.deleteProvider(provider.id, in: noteId)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var nameEditor: some View {
        HStack(spacing: 8) {
            TextField("Provider name…", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.palette.text)
                .focused($nameFocused)
                .onSubmit(saveName)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.palette.searchFieldBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.palette.dividerColor, lineWidth: 1)
                )

            Button(action: saveName) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(theme.palette.iconColor)
            }
            .buttonStyle(.plain)
            .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(draftName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.35 : 1)
            .help("Save name")

            Button(action: cancelNaming) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(theme.palette.iconColorDim)
            }
            .buttonStyle(.plain)
            .help(isUnnamed ? "Remove provider" : "Cancel")
        }
    }

    // Base URL — below the provider name.
    private var baseURLSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Base URL")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.palette.secondaryText)

            HStack(spacing: 8) {
                TextField("https://api.example.com/v1", text: $draftBaseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.palette.text)
                    .focused($baseURLFocused)
                    .onSubmit(commitBaseURL)
                    .onChange(of: baseURLFocused) { _, focused in
                        if !focused { commitBaseURL() }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(theme.palette.searchFieldBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.palette.dividerColor, lineWidth: 1)
                    )

                Button(action: copyBaseURL) {
                    HStack(spacing: 6) {
                        Image(systemName: urlCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                        Text(urlCopied ? "Copied" : "Copy")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(theme.palette.copyButtonText)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(theme.palette.copyButtonBackground, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(trimmedDraftBaseURL.isEmpty)
                .opacity(trimmedDraftBaseURL.isEmpty ? 0.35 : 1)
                .help("Copy base URL")
            }
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, 12)
    }

    private var trimmedDraftBaseURL: String {
        draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // API keys — bottom of the card.
    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isUnnamed {
                Text("Enter a provider name, then press Return or ✓.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.palette.secondaryText)
            } else if provider.keys.isEmpty && !isAddingKey {
                Text("No API keys yet.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.palette.secondaryText)
            } else {
                ForEach(provider.keys) { key in
                    APIKeyRow(
                        noteId: noteId,
                        providerId: provider.id,
                        entry: key
                    )
                }
            }

            if isAddingKey {
                keyPasteRow
            } else if !isUnnamed {
                addKeyButton
            }
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addKeyButton: some View {
        Button(action: onBeginAddKey) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("Add API key")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(theme.palette.iconColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.palette.activeRowBackground, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var keyPasteRow: some View {
        HStack(spacing: 8) {
            TextField("Paste API key…", text: $draftKey)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(theme.palette.text)
                .focused($keyFocused)
                .onSubmit(saveKey)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.palette.searchFieldBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.palette.dividerColor, lineWidth: 1)
                )

            Button(action: saveKey) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(theme.palette.iconColor)
            }
            .buttonStyle(.plain)
            .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(draftKey.trimmingCharacters(in: .whitespaces).isEmpty ? 0.35 : 1)

            Button {
                onEndAddKey()
                draftKey = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(theme.palette.iconColorDim)
            }
            .buttonStyle(.plain)
        }
    }

    private func focusNameField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            nameFocused = true
            onNameFocused()
        }
    }

    private func beginRename() {
        draftName = provider.name
        isEditingName = true
        focusNameField()
    }

    private func commitBaseURL() {
        let trimmed = trimmedDraftBaseURL
        guard trimmed != provider.baseURL else { return }
        store.updateProviderBaseURL(provider.id, to: trimmed, in: noteId)
    }

    private func copyBaseURL() {
        commitBaseURL()
        let url = trimmedDraftBaseURL
        guard !url.isEmpty else { return }
        store.copyToPasteboard(url)
        withAnimation { urlCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { urlCopied = false }
        }
    }

    private func saveName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed != provider.name {
            store.renameProvider(provider.id, to: trimmed, in: noteId)
        }
        isEditingName = false
        nameFocused = false
        onNameFocused()
    }

    private func cancelNaming() {
        if isUnnamed && provider.keys.isEmpty {
            store.deleteProvider(provider.id, in: noteId)
        } else {
            draftName = provider.name
            isEditingName = false
            nameFocused = false
        }
        onNameFocused()
    }

    private func saveKey() {
        let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addKey(trimmed, toProvider: provider.id, in: noteId)
        draftKey = ""
        onEndAddKey()
    }
}

// MARK: – API key row

private struct APIKeyRow: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeStore
    @ObservedObject private var menuBarPins = MenuBarPinStore.shared
    let noteId: UUID
    let providerId: UUID
    let entry: APIKeyEntry

    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if revealed {
                        Text(entry.value)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(theme.palette.text)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    } else {
                        Text(maskedValue)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(theme.palette.text)
                    }
                }

                Text(APIKeyRow.timestampFormatter.string(from: entry.createdAt))
                    .font(.system(size: 11))
                    .foregroundColor(theme.palette.secondaryText)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button {
                    menuBarPins.toggleKeyPin(entry.id)
                } label: {
                    Image(systemName: menuBarPins.isKeyPinned(entry.id) ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundColor(theme.palette.iconColorDim)
                }
                .buttonStyle(.plain)
                .help(menuBarPins.isKeyPinned(entry.id)
                      ? "Unpin from menu bar"
                      : "Pin to menu bar")

                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundColor(theme.palette.iconColorDim)
                }
                .buttonStyle(.plain)
                .help(revealed ? "Hide" : "Reveal")

                Button(action: copy) {
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(theme.palette.copyButtonText)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(theme.palette.copyButtonBackground, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Copy")

                Button {
                    store.deleteKey(entry.id, inProvider: providerId, note: noteId)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(theme.palette.iconColorDim)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.palette.searchFieldBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var maskedValue: String {
        let v = entry.value
        guard v.count > 4 else { return String(repeating: "•", count: max(v.count, 8)) }
        return String(repeating: "•", count: min(v.count - 4, 12)) + v.suffix(4)
    }

    private func copy() {
        store.copyToPasteboard(entry.value)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { copied = false }
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: – Add provider card

private struct AddProviderCard: View {
    @EnvironmentObject var theme: ThemeStore
    var compact: Bool
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("Add provider")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .foregroundColor(theme.palette.secondaryText)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, 14)
            .background(theme.palette.searchFieldBackground.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(theme.palette.dividerColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
