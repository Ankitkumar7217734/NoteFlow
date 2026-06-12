import Testing
import Foundation
import AppKit
@testable import NoteFlow

// Each test gets its own temp directory so NoteStore never touches the real
// notes.json in Application Support.
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NoteFlowTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: – Corrupt store handling

@Test func corruptNotesFileIsBackedUpNotOverwritten() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")
    let garbage = Data("this is not valid JSON {][".utf8)
    try garbage.write(to: notesURL)

    let store = NoteStore(saveURL: notesURL)

    // The store recovers with a fresh note rather than crashing.
    #expect(!store.notes.isEmpty)

    // The unreadable original must survive somewhere on disk — losing the
    // user's entire history to one corrupt byte is not acceptable.
    let backups = try FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("notes.json.corrupt-") }
    #expect(backups.count == 1, "expected the corrupt file to be moved to a backup")
    if let backup = backups.first {
        #expect(try Data(contentsOf: backup) == garbage, "backup must contain the original bytes")
    }
}

@Test func healthyNotesFileRoundTrips() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")

    let first = NoteStore(saveURL: notesURL)
    let id = first.notes[0].id
    first.updateNote(id: id, title: "Groceries")

    let second = NoteStore(saveURL: notesURL)
    #expect(second.notes.first(where: { $0.id == id })?.title == "Groceries")
}

// MARK: – Debounced save

@Test func flushPendingSavesEncodesLiveStorage() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: notesURL)
    let id = store.notes[0].id

    let storage = store.sharedTextStorage(for: id)
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello world")
    store.noteBodyDidChange(id)
    store.flushPendingSaves()

    let rtf = try #require(store.notes.first(where: { $0.id == id })?.rtfData)
    let decoded = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
    #expect(decoded.string == "hello world")
}

@Test func backgroundFlushPersistsEdits() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: notesURL)
    let id = store.notes[0].id
    let storage = store.sharedTextStorage(for: id)
    storage.replaceCharacters(in: NSRange(location: 0, length: 0),
                              with: "typed before a background flush")
    store.noteBodyDidChange(id)

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        store.flushPendingSavesInBackground { cont.resume() }
    }

    let rtf = try #require(store.notes.first(where: { $0.id == id })?.rtfData)
    let decoded = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
    #expect(decoded.string == "typed before a background flush")

    // And the dirty mark must be gone — a later sync flush has nothing to redo.
    store.flushPendingSaves()
    let reloaded = NoteStore(saveURL: notesURL)
    #expect(reloaded.notes.first(where: { $0.id == id })?.rtfData != nil)
}
