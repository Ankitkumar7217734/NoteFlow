import Foundation
import SwiftUI
import AppKit

class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published var notes: [Note] = []
    @Published var openTabIds: [UUID] = []
    @Published var activeTabId: UUID?
    /// Global: whether the floating panel is currently shown. Shared across
    /// windows so each window's TabBar can adapt. UI state like
    /// sidebarOpen, searchText and formattingVisible lives in WindowState.
    @Published var isFloating = false

    // Cache of plain-text bodies keyed by note id, populated lazily by
    // plainText(for:) and invalidated by updateNote / deleteNote.
    // Lets full-text search avoid re-decoding RTF on every keystroke.
    private var plainTextCache: [UUID: String] = [:]

    // One NSTextStorage per note, shared by every NSTextView that edits that
    // note (main window + floating panel). NSTextStorage notifies all attached
    // NSLayoutManagers on every edit, so a keystroke in one editor instantly
    // re-renders in the other without going through @Published or RTF.
    private var sharedStorages: [UUID: NSTextStorage] = [:]

    // Debounced persistence. Typing calls noteBodyDidChange(_:), which marks
    // the note's id dirty and (re)arms a timer instead of encoding RTF +
    // writing notes.json on every keystroke. The shared NSTextStorage holds
    // the live text in the meantime, so nothing is lost; flushPendingSaves()
    // encodes from it and writes once typing pauses (and on app
    // resign/terminate, so quitting never drops the last edits).
    private var pendingDirtyNoteIds: Set<UUID> = []
    private var saveDebounceTimer: Timer?
    private let saveDebounceInterval: TimeInterval = 0.6

    func sharedTextStorage(for id: UUID) -> NSTextStorage {
        if let existing = sharedStorages[id] {
            return existing
        }
        let storage = NSTextStorage()
        if let note = notes.first(where: { $0.id == id }) {
            let attr = note.attributedContent
            if attr.length > 0 {
                // Strip only the foreground colors that match a theme's
                // default text color, so notes saved in light/dark mode
                // adapt to the current theme — but user-applied colors
                // (red, blue, etc. from the Text Formatting picker) are
                // preserved.
                let mutable = NSMutableAttributedString(attributedString: attr)
                Self.stripThemeDefaultForegroundColors(in: mutable)
                storage.setAttributedString(mutable)
            }
        }
        sharedStorages[id] = storage
        return storage
    }

    // Colors the editor uses as a "default" text color (one per theme).
    // We compare against these when deciding which foreground colors to
    // strip so the user's explicitly-picked colors survive.
    private static let themeDefaultColors: [NSColor] = [
        .black,                                      // legacy + light theme
        NSColor(white: 0.91, alpha: 1)               // dark theme
    ]

    private static func isThemeDefault(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        for ref in themeDefaultColors {
            guard let r = ref.usingColorSpace(.sRGB) else { continue }
            if abs(c.redComponent - r.redComponent) < 0.02
                && abs(c.greenComponent - r.greenComponent) < 0.02
                && abs(c.blueComponent - r.blueComponent) < 0.02 {
                return true
            }
        }
        return false
    }

    static func stripThemeDefaultForegroundColors(in storage: NSMutableAttributedString) {
        guard storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        var rangesToClear: [NSRange] = []
        storage.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            if isThemeDefault(color) { rangesToClear.append(range) }
        }
        for range in rangesToClear {
            storage.removeAttribute(.foregroundColor, range: range)
        }
    }

    private var saveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.json")
    }

    var openTabs: [Note] { openTabIds.compactMap { id in notes.first(where: { $0.id == id }) } }

    var activeNote: Note? { notes.first(where: { $0.id == activeTabId }) }

    /// Notes filtered by a per-window search query and/or tag, then sorted
    /// pinned-first within each group. Excludes trashed notes — those live
    /// behind the Trash view. Pinned ordering: pinned notes by updatedAt
    /// desc, then unpinned by updatedAt desc.
    func filteredNotes(matching query: String = "", tag: String? = nil) -> [Note] {
        var result = notes.filter { !$0.isTrashed }

        if let tag = tag, !tag.isEmpty {
            result = result.filter { $0.tags.contains(tag) }
        }

        if !query.isEmpty {
            result = result.filter { note in
                if note.title.localizedCaseInsensitiveContains(query) { return true }
                if note.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
                return plainText(for: note.id).localizedCaseInsensitiveContains(query)
            }
        }

        return result.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Every distinct tag across non-trashed notes, sorted alphabetically.
    var allTags: [String] {
        var set = Set<String>()
        for note in notes where !note.isTrashed {
            for tag in note.tags { set.insert(tag) }
        }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Trashed notes, most-recently-deleted first.
    var trashedNotes: [Note] {
        notes.filter { $0.isTrashed }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Returns the note's body as plain text. Prefers the live NSTextStorage
    /// (always up-to-date with whatever the user is typing right now) and
    /// falls back to decoding the persisted RTF, caching the result.
    func plainText(for noteId: UUID) -> String {
        if let storage = sharedStorages[noteId] { return storage.string }
        if let cached = plainTextCache[noteId] { return cached }
        guard let note = notes.first(where: { $0.id == noteId }) else { return "" }
        let plain = note.attributedContent.string
        plainTextCache[noteId] = plain
        return plain
    }

    init() {
        load()
        // When the theme flips, any text the user has already typed in the
        // current session has an explicit .foregroundColor baked into its
        // shared NSTextStorage from typingAttributes. Without stripping, it
        // stays the old theme's color and renders invisible against the new
        // background. We strip across every in-memory storage so newly
        // opened notes are also correct.
        NotificationCenter.default.addObserver(
            self, selector: #selector(stripForegroundColorsAcrossStorages),
            name: .themeChanged, object: nil
        )
    }

    @objc private func stripForegroundColorsAcrossStorages() {
        // Only clear runs whose color matches a theme default (the
        // implicit black/light text color baked in by typingAttributes).
        // User-picked colors from the formatting toolbar — red, blue,
        // etc. — keep their value across theme flips.
        for (_, storage) in sharedStorages where storage.length > 0 {
            storage.beginEditing()
            Self.stripThemeDefaultForegroundColors(in: storage)
            storage.endEditing()
        }
    }

    func newNote() {
        let note = Note()
        withAnimation(.easeInOut(duration: 0.22)) {
            notes.insert(note, at: 0)
        }
        openTabIds.append(note.id)
        activeTabId = note.id
        save()
    }

    func closeTab(_ id: UUID) {
        openTabIds.removeAll { $0 == id }
        if activeTabId == id {
            activeTabId = openTabIds.last
        }
        if openTabIds.isEmpty {
            newNote()
        }
    }

    func selectNote(_ id: UUID) {
        if !openTabIds.contains(id) {
            openTabIds.append(id)
        }
        activeTabId = id
    }

    func updateNote(id: UUID, title: String? = nil, rtfData: Data? = nil) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        if let t = title { notes[idx].title = t }
        if let d = rtfData {
            notes[idx].rtfData = d
            plainTextCache.removeValue(forKey: id)
        }
        notes[idx].updatedAt = Date()
        save()
    }

    /// Called from the editor on every keystroke. Cheap: marks the note's
    /// body dirty and (re)arms the debounce timer. The actual RTF-encode +
    /// disk write happen in flushPendingSaves() once typing pauses.
    func noteBodyDidChange(_ id: UUID) {
        pendingDirtyNoteIds.insert(id)
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: saveDebounceInterval, repeats: false
        ) { [weak self] _ in
            self?.flushPendingSaves()
        }
    }

    /// Encode every dirty note's live NSTextStorage to RTF, fold it into the
    /// model, and persist. No-ops when nothing is dirty, so it's safe to call
    /// eagerly (e.g. on app resign/terminate). Synchronous so it completes
    /// before the process exits on quit.
    func flushPendingSaves() {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil
        guard !pendingDirtyNoteIds.isEmpty else { return }
        let ids = pendingDirtyNoteIds
        pendingDirtyNoteIds.removeAll()
        let now = Date()
        for id in ids {
            guard let idx = notes.firstIndex(where: { $0.id == id }),
                  let storage = sharedStorages[id] else { continue }
            let full = NSRange(location: 0, length: storage.length)
            notes[idx].rtfData = try? storage.data(
                from: full,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            notes[idx].updatedAt = now
            plainTextCache.removeValue(forKey: id)
        }
        save()
    }

    /// The note's current rich-text content. Prefers the live shared
    /// NSTextStorage (always up to date with the latest keystrokes, even
    /// ones not yet re-encoded to RTF) and falls back to decoding the
    /// persisted RTF. Used by the exporter so files match what's on screen.
    func attributedContent(for id: UUID) -> NSAttributedString {
        if let storage = sharedStorages[id] {
            return NSAttributedString(attributedString: storage)
        }
        return notes.first(where: { $0.id == id })?.attributedContent ?? NSAttributedString()
    }

    /// Export a note to a file the user picks, in the given format,
    /// preserving its formatting.
    func exportNote(_ id: UUID, as format: ExportFormat) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        NoteExporter.export(note: note, content: attributedContent(for: id), format: format)
    }

    func togglePin(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            notes[idx].isPinned.toggle()
        }
        save()
    }

    /// Add `tag` to the note if not already present. Tags are trimmed and
    /// lowercased to keep "Work" and " work " from being treated as
    /// different tags.
    func addTag(_ tag: String, to id: UUID) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        if !notes[idx].tags.contains(normalized) {
            notes[idx].tags.append(normalized)
            save()
        }
    }

    func removeTag(_ tag: String, from id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].tags.removeAll { $0 == tag }
        save()
    }

    /// Soft-delete: move the note to the Trash. Tab is closed (since the
    /// main list hides trashed notes) but storage + plain-text cache are
    /// preserved so Restore returns the note intact, including any edits
    /// that hadn't been re-encoded to RTF yet.
    func deleteNote(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            notes[idx].deletedAt = Date()
        }
        closeTab(id)
        save()
    }

    /// Bring a trashed note back to the active list. Doesn't reopen it as
    /// a tab — the user can click it in the sidebar to do that.
    func restoreNote(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            notes[idx].deletedAt = nil
        }
        save()
    }

    /// Permanent deletion — drops the note, its shared storage, and its
    /// plain-text cache. No undo.
    func permanentlyDeleteNote(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.22)) {
            notes.removeAll { $0.id == id }
        }
        sharedStorages.removeValue(forKey: id)
        plainTextCache.removeValue(forKey: id)
        save()
    }

    /// Permanently delete every trashed note.
    func emptyTrash() {
        let ids = trashedNotes.map { $0.id }
        for id in ids { permanentlyDeleteNote(id) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let decoded = try? JSONDecoder().decode([Note].self, from: data) else {
            newNote()
            return
        }
        notes = decoded
        // Don't auto-open a trashed note. If everything is trashed (or the
        // file is empty), fall through to creating a fresh note.
        if let firstActive = notes.first(where: { !$0.isTrashed }) {
            openTabIds = [firstActive.id]
            activeTabId = firstActive.id
        } else {
            newNote()
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }
}
