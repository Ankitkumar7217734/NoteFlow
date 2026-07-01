import Testing
import Foundation
@testable import NoteFlow

private func isolatedPinDefaults() -> (UserDefaults, String) {
    let suite = "MenuBarPinTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

@Test @MainActor func menuBarPinStorePersistsKeyProviderAndPagePins() {
    let (defaults, suite) = isolatedPinDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let key = UUID()
    let provider = UUID()
    let page = UUID()

    let store = MenuBarPinStore(defaults: defaults)
    store.toggleKeyPin(key)
    store.toggleProviderPin(provider)
    store.togglePagePin(page)

    let reloaded = MenuBarPinStore(defaults: defaults)
    #expect(reloaded.isKeyPinned(key))
    #expect(reloaded.isProviderPinned(provider))
    #expect(reloaded.isPagePinned(page))

    store.toggleKeyPin(key)
    #expect(MenuBarPinStore(defaults: defaults).isKeyPinned(key) == false)
}

@Test @MainActor func allMenuBarAPIEntriesListsKeysAcrossPages() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuBarAPITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let noteStore = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))
    noteStore.newAPIPage()
    let page1 = try #require(noteStore.activeTabId)
    noteStore.addProvider(named: "Gemini", to: page1)
    let gemini = try #require(noteStore.notes.first(where: { $0.id == page1 })?.providers?.first)
    noteStore.addKey("sk-gem-1", toProvider: gemini.id, in: page1)

    noteStore.newAPIPage()
    let page2 = try #require(noteStore.activeTabId)
    noteStore.addProvider(named: "OpenAI", to: page2)
    let openAI = try #require(noteStore.notes.first(where: { $0.id == page2 })?.providers?.first)
    noteStore.addKey("sk-oai-1", toProvider: openAI.id, in: page2)

    let entries = noteStore.allMenuBarAPIEntries()
    #expect(entries.count == 2)
    #expect(entries.contains { $0.providerName == "Gemini" && $0.keyValue == "sk-gem-1" })
    #expect(entries.contains { $0.providerName == "OpenAI" && $0.keyValue == "sk-oai-1" })
}

@Test @MainActor func menuBarEntryMaskShowsRecognizableSuffix() {
    let entry = MenuBarAPIEntry(
        keyId: UUID(),
        providerId: UUID(),
        pageId: UUID(),
        pageTitle: "API Keys",
        providerName: "Gemini",
        keyValue: "sk-test-secret-1234",
        createdAt: Date()
    )
    #expect(entry.menuTitle.contains("Gemini"))
    #expect(entry.menuTitle.hasSuffix("1234"))
    #expect(entry.menuTitle.contains("•"))
}
