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

    func sharedTextStorage(for id: UUID) -> NSTextStorage {
        if let existing = sharedStorages[id] {
            return existing
        }
        let storage = NSTextStorage()
        if let note = notes.first(where: { $0.id == id }) {
            let attr = note.attributedContent
            if attr.length > 0 {
                // Strip baked-in foreground color so the text view's
                // theme-driven textColor drives the default. Otherwise notes
                // saved in light mode (with NSColor.black baked into the RTF)
                // would render black-on-dark in dark mode.
                let mutable = NSMutableAttributedString(attributedString: attr)
                mutable.removeAttribute(.foregroundColor,
                                        range: NSRange(location: 0, length: mutable.length))
                storage.setAttributedString(mutable)
            }
        }
        sharedStorages[id] = storage
        return storage
    }

    private var saveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.json")
    }

    var openTabs: [Note] { openTabIds.compactMap { id in notes.first(where: { $0.id == id }) } }

    var activeNote: Note? { notes.first(where: { $0.id == activeTabId }) }

    /// Notes sorted by most-recently-updated, optionally filtered by a
    /// per-window search query (matches title or body).
    func filteredNotes(matching query: String = "") -> [Note] {
        let sorted = notes.sorted { $0.updatedAt > $1.updatedAt }
        if query.isEmpty { return sorted }
        return sorted.filter { note in
            if note.title.localizedCaseInsensitiveContains(query) { return true }
            return plainText(for: note.id).localizedCaseInsensitiveContains(query)
        }
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

    init() { load() }

    func newNote() {
        var note = Note()
        notes.insert(note, at: 0)
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

    func deleteNote(_ id: UUID) {
        closeTab(id)
        notes.removeAll { $0.id == id }
        sharedStorages.removeValue(forKey: id)
        plainTextCache.removeValue(forKey: id)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let decoded = try? JSONDecoder().decode([Note].self, from: data) else {
            newNote()
            return
        }
        notes = decoded
        if let first = notes.first {
            openTabIds = [first.id]
            activeTabId = first.id
        } else {
            newNote()
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }
}
