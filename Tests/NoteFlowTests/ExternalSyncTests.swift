import Testing
import Foundation
import AppKit
@testable import NoteFlow

// Tests for live syncing of notes.json changes made by another process
// (the NoteFlow MCP server, a hand edit, …) into a running NoteStore.
// They call reloadFromDiskIfExternallyChanged() directly rather than waiting
// on the (debounced) directory watcher, so the merge logic is tested
// deterministically; one watcher test at the end covers the event plumbing.

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NoteFlowExternalSync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Rewrite notes.json the way an external tool would: read, mutate, write new
/// bytes. JSONEncoder output differs byte-for-byte from what the store wrote
/// (key order), which is exactly the situation the hash check must catch.
private func externallyRewrite(_ url: URL, _ mutate: (inout [Note]) -> Void) throws {
    var notes = try JSONDecoder().decode([Note].self, from: Data(contentsOf: url))
    mutate(&notes)
    try JSONEncoder().encode(notes).write(to: url, options: .atomic)
}

private func rtf(_ text: String) -> Data {
    try! NSAttributedString(string: text).data(
        from: NSRange(location: 0, length: text.count),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
}

// MARK: – Merge logic

@Test @MainActor func externallyCreatedNoteAppearsAfterReload() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))

    var external = Note(title: "From MCP")
    external.rtfData = rtf("hello from the MCP server")
    try externallyRewrite(dir.appendingPathComponent("notes.json")) { $0.insert(external, at: 0) }

    #expect(store.reloadFromDiskIfExternallyChanged())
    #expect(store.notes.contains(where: { $0.id == external.id }))
    #expect(store.plainText(for: external.id) == "hello from the MCP server")
}

@Test @MainActor func externalBodyEditRefreshesLiveStorage() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")
    let store = NoteStore(saveURL: notesURL)
    let id = try #require(store.notes.first?.id)

    // Open the note so a live shared storage exists (as if it's on screen).
    let storage = store.sharedTextStorage(for: id)
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "original")
    store.noteBodyDidChange(id)
    store.flushPendingSaves()

    try externallyRewrite(notesURL) { notes in
        let idx = notes.firstIndex(where: { $0.id == id })!
        notes[idx].rtfData = rtf("rewritten externally")
        notes[idx].updatedAt = Date()
    }

    #expect(store.reloadFromDiskIfExternallyChanged())
    // The live storage every open editor renders from must show the new text.
    #expect(storage.string == "rewritten externally")
    #expect(store.plainText(for: id) == "rewritten externally")
}

@Test @MainActor func unflushedLocalTypingBeatsExternalWrite() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")
    let store = NoteStore(saveURL: notesURL)
    let id = try #require(store.notes.first?.id)

    let storage = store.sharedTextStorage(for: id)
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "user is typing")
    store.noteBodyDidChange(id)   // dirty, debounce armed, NOT flushed

    try externallyRewrite(notesURL) { notes in
        let idx = notes.firstIndex(where: { $0.id == id })!
        notes[idx].rtfData = rtf("external overwrite")
        notes[idx].updatedAt = Date().addingTimeInterval(60)
    }

    #expect(store.reloadFromDiskIfExternallyChanged())
    // Mid-edit keystrokes must never be replaced from disk.
    #expect(storage.string == "user is typing")
    store.flushPendingSaves()
    #expect(store.plainText(for: id) == "user is typing")
}

@Test @MainActor func saveDoesNotClobberExternalWrite() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")
    let store = NoteStore(saveURL: notesURL)
    let localId = try #require(store.notes.first?.id)

    // External writer adds a note; the store hasn't noticed yet (debounced
    // watcher). A local mutation + save must merge it in, not erase it.
    var external = Note(title: "Added by MCP")
    external.rtfData = rtf("mcp body")
    try externallyRewrite(notesURL) { $0.insert(external, at: 0) }

    store.updateNote(id: localId, title: "Renamed locally")   // triggers save()

    #expect(store.notes.contains(where: { $0.id == external.id }))
    #expect(store.notes.first(where: { $0.id == localId })?.title == "Renamed locally")

    // And both survive on disk.
    let onDisk = try JSONDecoder().decode([Note].self, from: Data(contentsOf: notesURL))
    #expect(onDisk.contains(where: { $0.id == external.id }))
    #expect(onDisk.first(where: { $0.id == localId })?.title == "Renamed locally")
}

@Test @MainActor func externalTitleAndTagEditsApply() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")
    let store = NoteStore(saveURL: notesURL)
    let id = try #require(store.notes.first?.id)

    try externallyRewrite(notesURL) { notes in
        let idx = notes.firstIndex(where: { $0.id == id })!
        notes[idx].title = "MCP Title"
        notes[idx].titleIsManual = true
        notes[idx].tags = ["mcp"]
        notes[idx].updatedAt = Date()
    }

    #expect(store.reloadFromDiskIfExternallyChanged())
    let note = try #require(store.notes.first(where: { $0.id == id }))
    #expect(note.title == "MCP Title")
    #expect(note.tags == ["mcp"])
}

@Test @MainActor func permanentlyDeletedNoteIsNotResurrectedBySaveMerge() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")
    let store = NoteStore(saveURL: notesURL)
    store.newNote()
    let doomed = try #require(store.activeTabId)
    store.flushPendingSaves()

    // Unrelated external write lands between our delete and its save —
    // the merge inside save() must not bring the deleted note back.
    var external = Note(title: "Bystander")
    external.rtfData = rtf("still here")
    try externallyRewrite(notesURL) { $0.insert(external, at: 0) }

    store.permanentlyDeleteNote(doomed)

    #expect(!store.notes.contains(where: { $0.id == doomed }))
    #expect(store.notes.contains(where: { $0.id == external.id }))
    let onDisk = try JSONDecoder().decode([Note].self, from: Data(contentsOf: notesURL))
    #expect(!onDisk.contains(where: { $0.id == doomed }))
}

@Test @MainActor func ownSaveDoesNotTriggerAMerge() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))
    // The bytes on disk are ours — reload must recognize them and no-op.
    #expect(!store.reloadFromDiskIfExternallyChanged())
    store.updateNote(id: store.notes[0].id, title: "self write")
    #expect(!store.reloadFromDiskIfExternallyChanged())
}

@Test @MainActor func invalidExternalContentIsIgnored() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")
    let store = NoteStore(saveURL: notesURL)
    let countBefore = store.notes.count

    try Data("not json {".utf8).write(to: notesURL, options: .atomic)

    #expect(!store.reloadFromDiskIfExternallyChanged())
    #expect(store.notes.count == countBefore)
}

// MARK: – MCP wire-format compatibility

// Pins the exact JSON shape the Python MCP server writes (float Apple-epoch
// dates, base64 RTF string, uppercase UUID) so a server-side change that
// breaks decoding fails a test here instead of silently corrupt-backing-up
// the user's store.
@Test @MainActor func mcpServerJSONShapeDecodes() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")
    let store = NoteStore(saveURL: notesURL)

    let rtfBase64 = rtf("from python").base64EncodedString()
    let json = """
    [{
        "id": "\(UUID().uuidString)",
        "title": "Python note",
        "rtfData": "\(rtfBase64)",
        "createdAt": 774300000.0,
        "updatedAt": 774300000.0,
        "isPinned": false,
        "tags": ["mcp"],
        "kind": "richText",
        "titleIsManual": true
    }]
    """
    try Data(json.utf8).write(to: notesURL, options: .atomic)

    #expect(store.reloadFromDiskIfExternallyChanged())
    let note = try #require(store.notes.first(where: { $0.title == "Python note" }))
    #expect(store.plainText(for: note.id) == "from python")
}

// MARK: – Directory watcher plumbing

@Test @MainActor func directoryWatcherPicksUpExternalWrite() async throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")
    let store = NoteStore(saveURL: notesURL)

    var external = Note(title: "Watched")
    external.rtfData = rtf("caught by the watcher")
    try externallyRewrite(notesURL) { $0.insert(external, at: 0) }

    // Watcher event → 0.25 s debounce → main-thread merge. Poll up to 3 s.
    for _ in 0..<30 {
        if store.notes.contains(where: { $0.id == external.id }) { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(store.notes.contains(where: { $0.id == external.id }))
}
