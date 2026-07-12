import Testing
import Foundation
import AppKit
@testable import NoteFlow

// Each test gets its own temp directory so NoteStore never touches the real
// notes.json in Application Support (mirrors NoteStoreTests).
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NoteFlowAPITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: – Page creation

@Test @MainActor func newAPIPageCreatesPinnedApiManagerNote() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))

    store.newAPIPage()

    let note = try #require(store.activeNote)
    #expect(note.kind == .apiManager)
    #expect(note.isAPIManager)
    #expect(note.isPinned)                 // auto-pinned → sidebar "Pinned" section
    #expect(note.providers == [])
    #expect(note.rtfData == nil)
    #expect(store.openTabIds.contains(note.id))
}

// MARK: – Provider / key CRUD round-trips through save()/load()

@Test @MainActor func providerAndKeyCRUDRoundTripsThroughSaveLoad() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notes.json")

    let first = NoteStore(saveURL: url)
    first.newAPIPage()
    let id = try #require(first.activeTabId)

    first.addProvider(named: "OpenRouter", to: id)
    let openRouter = try #require(first.notes.first(where: { $0.id == id })?.providers?.first)
    first.addKey("sk-or-abc", label: "prod", toProvider: openRouter.id, in: id)
    first.addKey("sk-or-def", label: "dev", toProvider: openRouter.id, in: id)
    first.addProvider(named: "OpenAI", to: id)

    // Reload from disk in a fresh store.
    let second = NoteStore(saveURL: url)
    let note = try #require(second.notes.first(where: { $0.id == id }))
    let providers = try #require(note.providers)
    #expect(providers.count == 2)
    #expect(providers.contains { $0.name == "OpenAI" })

    let reloaded = try #require(providers.first(where: { $0.name == "OpenRouter" }))
    #expect(reloaded.keys.count == 2)
    #expect(reloaded.keys.map { $0.value }.sorted() == ["sk-or-abc", "sk-or-def"])
    #expect(reloaded.keys.first(where: { $0.value == "sk-or-abc" })?.label == "prod")
}

@Test @MainActor func providerBaseURLPersistsThroughSaveLoad() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: url)
    store.newAPIPage()
    let id = try #require(store.activeTabId)
    store.addProvider(named: "OpenAI", to: id)
    let prov = try #require(store.notes.first(where: { $0.id == id })?.providers?.first)
    store.updateProviderBaseURL(prov.id, to: "https://api.openai.com/v1", in: id)

    let reloaded = NoteStore(saveURL: url)
    let provider = try #require(reloaded.notes.first(where: { $0.id == id })?.providers?.first)
    #expect(provider.baseURL == "https://api.openai.com/v1")
}

@Test @MainActor func legacyProviderJSONWithoutBaseURLDecodes() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notes.json")

    let legacy = """
    [{"id":"\(UUID().uuidString)","title":"API Keys","createdAt":804592078.957198,\
    "updatedAt":804592291.036567,"isPinned":true,"tags":[],"kind":"apiManager",\
    "providers":[{"id":"\(UUID().uuidString)","name":"ChatGPT","keys":[],"createdAt":804592248.902}]}]
    """
    try Data(legacy.utf8).write(to: url)

    let store = NoteStore(saveURL: url)
    let note = try #require(store.notes.first)
    #expect(note.kind == .apiManager)
    #expect(store.notes.first?.providers?.first?.baseURL == "")
}

// MARK: – Key createdAt is set on paste and preserved on edit

@Test @MainActor func keyCreatedAtIsSetOnPasteAndPreservedOnEdit() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: url)
    store.newAPIPage()
    let id = try #require(store.activeTabId)
    store.addProvider(named: "ChatGPT", to: id)
    let prov = try #require(store.notes.first(where: { $0.id == id })?.providers?.first)

    let before = Date()
    store.addKey("sk-test", toProvider: prov.id, in: id)
    let key = try #require(store.notes.first(where: { $0.id == id })?.providers?.first?.keys.first)
    #expect(key.createdAt >= before)
    #expect(key.createdAt <= Date())
    let originalCreatedAt = key.createdAt

    store.updateKey(key.id, value: "sk-updated", inProvider: prov.id, note: id)

    let reloaded = NoteStore(saveURL: url)
    let updated = try #require(
        reloaded.notes.first(where: { $0.id == id })?.providers?.first?.keys.first
    )
    #expect(updated.value == "sk-updated")
    #expect(updated.createdAt == originalCreatedAt)
}

// MARK: – Legacy migration: old bare [Note] JSON without kind/providers

@Test @MainActor func oldBareNoteJSONWithoutKindDecodesAsRichText() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notes.json")

    // Hand-write the OLD on-disk shape: a [Note] array with no kind/providers.
    let legacy = """
    [{"id":"\(UUID().uuidString)","title":"Legacy",\
    "createdAt":749000000,"updatedAt":749000000,"isPinned":false,"tags":[]}]
    """
    try Data(legacy.utf8).write(to: url)

    let store = NoteStore(saveURL: url)
    let note = try #require(store.notes.first(where: { $0.title == "Legacy" }))
    #expect(note.kind == .richText)       // missing key → default
    #expect(note.providers == nil)
    #expect(!note.isAPIManager)
}

// MARK: – API pages stay out of the RTF / search code paths

@Test @MainActor func apiManagerNoteExcludedFromRTFPathsButSearchableByProvider() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))

    store.newAPIPage()
    let id = try #require(store.activeTabId)
    store.addProvider(named: "Anthropic", to: id)
    let provider = try #require(store.notes.first(where: { $0.id == id })?.providers?.first)
    store.addKey("sk-ant-supersecret", label: "main", toProvider: provider.id, in: id)

    // No RTF body — plainText must be empty (used for sidebar snippets).
    #expect(store.plainText(for: id).isEmpty)

    // Searchable by provider name…
    #expect(store.filteredNotes(matching: "Anthropic").contains { $0.id == id })
    // …and by key label…
    #expect(store.filteredNotes(matching: "main").contains { $0.id == id })
    // …but the secret value must NOT leak into the search index.
    #expect(store.apiSearchText(for: store.notes.first(where: { $0.id == id })!)
        .contains("sk-ant-supersecret") == false)
    #expect(store.filteredNotes(matching: "supersecret").contains { $0.id == id } == false)
}

// MARK: – Update / delete mutations persist

@Test @MainActor func updateAndDeleteKeyAndProviderPersist() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: url)
    store.newAPIPage()
    let id = try #require(store.activeTabId)
    store.addProvider(named: "Prov", to: id)
    let prov = try #require(store.notes.first(where: { $0.id == id })?.providers?.first)
    store.addKey("v1", label: "a", toProvider: prov.id, in: id)
    let key = try #require(store.notes.first(where: { $0.id == id })?.providers?.first?.keys.first)

    store.updateKey(key.id, value: "v2", label: "b", inProvider: prov.id, note: id)
    store.renameProvider(prov.id, to: "Renamed", in: id)

    // Persisted?
    var reloaded = NoteStore(saveURL: url)
    var p = try #require(reloaded.notes.first(where: { $0.id == id })?.providers?.first)
    #expect(p.name == "Renamed")
    #expect(p.keys.first?.value == "v2")
    #expect(p.keys.first?.label == "b")

    // Delete key, then provider.
    store.deleteKey(key.id, inProvider: prov.id, note: id)
    #expect(store.notes.first(where: { $0.id == id })?.providers?.first?.keys.isEmpty == true)
    store.deleteProvider(prov.id, in: id)

    reloaded = NoteStore(saveURL: url)
    p = APIProvider()   // placeholder; assert none remain
    #expect(reloaded.notes.first(where: { $0.id == id })?.providers?.isEmpty == true)
}

// MARK: – Provider mutations can't corrupt a rich-text note

@Test @MainActor func providerMutationsAreNoOpOnRichTextNote() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))

    // The store starts with a fresh rich-text note.
    let rich = try #require(store.notes.first)
    #expect(rich.kind == .richText)

    store.addProvider(named: "ShouldNotStick", to: rich.id)

    let after = try #require(store.notes.first(where: { $0.id == rich.id }))
    #expect(after.kind == .richText)
    #expect(after.providers == nil)       // guard prevented any mutation
}

// MARK: – Reorder providers / keys (array order is display order)

@Test @MainActor func moveProviderRoundTripThroughSaveLoad() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notes.json")

    let store = NoteStore(saveURL: url)
    store.newAPIPage()
    let id = try #require(store.activeTabId)

    store.addProvider(named: "First", to: id)
    store.addProvider(named: "Second", to: id)
    store.addProvider(named: "Third", to: id)
    var providers = try #require(store.notes.first(where: { $0.id == id })?.providers)
    #expect(providers.map(\.name) == ["First", "Second", "Third"])

    let thirdId = try #require(providers.first(where: { $0.name == "Third" })?.id)
    store.moveProvider(thirdId, toIndex: 0, in: id)
    providers = try #require(store.notes.first(where: { $0.id == id })?.providers)
    #expect(providers.map(\.name) == ["Third", "First", "Second"])

    let reloaded = NoteStore(saveURL: url)
    #expect(reloaded.notes.first(where: { $0.id == id })?.providers?.map(\.name)
        == ["Third", "First", "Second"])
}

@Test @MainActor func insertionSlotMovesLastProviderToTopInOneStep() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))
    store.newAPIPage()
    let id = try #require(store.activeTabId)
    store.addProvider(named: "A", to: id)
    store.addProvider(named: "B", to: id)
    store.addProvider(named: "C", to: id)

    // Slot math: last item (from 2) into top slot (0) → final index 0.
    #expect(NoteStore.finalIndex(from: 2, insertionSlot: 0, count: 3) == 0)
    #expect(NoteStore.finalIndex(from: 0, insertionSlot: 3, count: 3) == 2)
    #expect(NoteStore.finalIndex(from: 1, insertionSlot: 1, count: 3) == nil) // no-op

    let providers = try #require(store.notes.first(where: { $0.id == id })?.providers)
    let lastId = try #require(providers.last?.id)
    store.moveProvider(lastId, toInsertionSlot: 0, in: id)
    #expect(store.notes.first(where: { $0.id == id })?.providers?.map(\.name) == ["C", "A", "B"])
}

@Test @MainActor func moveProviderIsNoOpOnRichTextNote() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))
    let rich = try #require(store.notes.first)
    store.moveProvider(UUID(), toIndex: 0, in: rich.id)
    #expect(store.notes.first(where: { $0.id == rich.id })?.providers == nil)
}

// MARK: – Export is refused for API pages

@Test @MainActor func exportIsRefusedForAPIPage() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))
    store.newAPIPage()
    let id = try #require(store.activeTabId)
    // Should be a no-op (no save panel, no crash) — the note has no RTF body.
    store.exportNote(id, as: .markdown)
    #expect(store.notes.first(where: { $0.id == id })?.kind == .apiManager)
}
