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

// MARK: – Imported vertical spacing survives note-open (and clamps)

// An imported note sets paragraph spacing for rhythm; reopening it from disk
// runs sharedTextStorage -> normalizeParagraphStyles, which must preserve that
// vertical spacing (it only flattens horizontal layout).
@Test @MainActor func openPreservesImportedVerticalSpacing() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))

    let para = NSMutableParagraphStyle()
    para.paragraphSpacing = 6
    para.lineSpacing = 3
    let content = NSAttributedString(string: "hello", attributes: [
        .font: EditorTypography.baseFont, .paragraphStyle: para
    ])
    let id = store.addNote(title: "t", content: content)

    let storage = store.sharedTextStorage(for: id)
    let ps = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    #expect(ps?.paragraphSpacing == 6)
    #expect(ps?.lineSpacing == 3)
}

@Test @MainActor func openClampsExcessiveVerticalSpacing() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))

    let para = NSMutableParagraphStyle()
    para.paragraphSpacing = 200   // a legacy foreign paste with absurd spacing
    let content = NSAttributedString(string: "x", attributes: [
        .font: EditorTypography.baseFont, .paragraphStyle: para
    ])
    let id = store.addNote(title: "t", content: content)

    let storage = store.sharedTextStorage(for: id)
    let ps = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    #expect((ps?.paragraphSpacing ?? 0) <= 12)
}

// The paste path keeps the aggressive default (preserveVerticalSpacing: false),
// so sanitize must still flatten paragraph spacing to zero.
@Test @MainActor func pasteStillFlattensParagraphSpacing() {
    let para = NSMutableParagraphStyle()
    para.paragraphSpacing = 50
    let src = NSAttributedString(string: "x", attributes: [
        .font: EditorTypography.baseFont, .paragraphStyle: para
    ])
    let cleaned = NoteTextView.sanitize(src)
    let ps = cleaned.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    #expect((ps?.paragraphSpacing ?? -1) == 0)
}

// An imported Markdown table must survive addNote's RTF encode + the
// sharedTextStorage open path (decode + normalize) as a real NSTextTable,
// with column alignment intact — otherwise it renders as flat text.
@Test @MainActor func importedTableSurvivesOpenAsTextTable() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))

    let md = "| A | B |\n| :-- | --: |\n| 1 | 2 |"
    let id = store.addNote(title: "t", content: MarkdownParser.attributedString(from: md))
    let storage = store.sharedTextStorage(for: id)   // RTF round-trip + normalize

    #expect(NoteTextView.containsTables(storage))
    let loc = (storage.string as NSString).range(of: "B").location
    let ps = storage.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
    #expect(ps?.textBlocks.isEmpty == false)
    #expect(ps?.alignment == .right)   // right-aligned column preserved
}

// MARK: – Empty session notes on quit

@Test @MainActor func emptyUserCreatedNotePurgedOnQuit() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: notesURL)
    let bootstrapId = try #require(store.notes.first?.id)
    store.newNote()
    let emptyId = try #require(store.activeTabId)
    #expect(emptyId != bootstrapId)

    store.purgeUnusedSessionNotesOnQuit()

    #expect(store.notes.contains(where: { $0.id == bootstrapId }))
    #expect(!store.notes.contains(where: { $0.id == emptyId }))
}

@Test @MainActor func noteWithBodyTextSurvivesQuitPurge() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: notesURL)
    store.newNote()
    let id = try #require(store.activeTabId)
    let storage = store.sharedTextStorage(for: id)
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "draft")
    store.noteBodyDidChange(id)
    store.flushPendingSaves()

    store.purgeUnusedSessionNotesOnQuit()

    #expect(store.notes.contains(where: { $0.id == id }))
    #expect(store.plainText(for: id) == "draft")
}

@Test @MainActor func emptyUserCreatedNoteKeptWhileAppOpen() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: notesURL)
    store.newNote()
    let id = try #require(store.activeTabId)
    #expect(store.isNoteBodyEmpty(id))

    // No purge call — simulates the app staying open.
    #expect(store.notes.contains(where: { $0.id == id }))
}

@Test @MainActor func bootstrapNoteNotPurgedOnQuit() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: notesURL)
    let id = try #require(store.notes.first?.id)
    #expect(store.isNoteBodyEmpty(id))

    store.purgeUnusedSessionNotesOnQuit()

    #expect(store.notes.contains(where: { $0.id == id }))
}

// MARK: – Auto title from body

@Test func autoTitleUsesFirstNonEmptyLine() {
    #expect(NoteStore.autoTitle(from: "Groceries\nmilk") == "Groceries")
    #expect(NoteStore.autoTitle(from: "\n\n  Meeting notes  \n") == "Meeting notes")
}

@Test func autoTitleStripsListMarkers() {
    #expect(NoteStore.autoTitle(from: "• Buy eggs") == "Buy eggs")
    #expect(NoteStore.autoTitle(from: "1. First item") == "First item")
    #expect(NoteStore.autoTitle(from: "# Heading") == "Heading")
}

@Test func autoTitleLimitsToThreeWords() {
    let long = "one two three four five six seven eight nine ten"
    #expect(NoteStore.autoTitle(from: long) == "one two three")
    #expect(NoteStore.autoTitle(from: "alpha beta") == "alpha beta")
    #expect(NoteStore.autoTitle(from: "solo") == "solo")
}

@Test @MainActor func untitledNotePicksUpTitleFromBody() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: notesURL)
    store.newNote()
    let id = try #require(store.activeTabId)
    #expect(store.notes.first(where: { $0.id == id })?.title == "Untitled")

    let storage = store.sharedTextStorage(for: id)
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Project roadmap")
    store.noteBodyDidChange(id)

    #expect(store.notes.first(where: { $0.id == id })?.title == "Project roadmap")
}

@Test @MainActor func manualTitleIsNotOverwrittenByBody() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notesURL = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: notesURL)
    store.newNote()
    let id = try #require(store.activeTabId)
    store.updateNote(id: id, title: "My Custom Name")
    store.markTitleAsManual(id)

    let storage = store.sharedTextStorage(for: id)
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Different body text")
    store.noteBodyDidChange(id)

    #expect(store.notes.first(where: { $0.id == id })?.title == "My Custom Name")
}
