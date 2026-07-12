import Testing
import Foundation
import AppKit
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

@Test @MainActor func allMenuBarProviderEntriesListsBaseURLs() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuBarURLTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))
    store.newAPIPage()
    let pageId = try #require(store.activeTabId)
    store.addProvider(named: "OpenAI", to: pageId)
    let provider = try #require(store.notes.first(where: { $0.id == pageId })?.providers?.first)
    store.updateProviderBaseURL(provider.id, to: "https://api.openai.com/v1", in: pageId)

    let entries = store.allMenuBarProviderEntries()
    #expect(entries.count == 1)
    #expect(entries.first?.providerName == "OpenAI")
    #expect(entries.first?.baseURL == "https://api.openai.com/v1")
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

// MARK: – API submenu is a small scrollable list (not a tall native menu)

private func makeKeyEntries(
    count: Int, provider: UUID, providerName: String, page: UUID
) -> [MenuBarAPIEntry] {
    (0..<count).map { i in
        MenuBarAPIEntry(
            keyId: UUID(), providerId: provider, pageId: page,
            pageTitle: "API Keys", providerName: providerName,
            keyValue: "sk-\(providerName.lowercased())-\(i)", createdAt: Date()
        )
    }
}

@Test @MainActor func apiMenuRowsGroupPageThenProviderThenCopyActions() {
    let page = UUID()
    let gemini = UUID()
    let openAI = UUID()
    let keys = makeKeyEntries(count: 2, provider: gemini, providerName: "Gemini", page: page)
        + makeKeyEntries(count: 1, provider: openAI, providerName: "OpenAI", page: page)
    let urls = [MenuBarProviderEntry(
        providerId: gemini, pageId: page, pageTitle: "API Keys",
        providerName: "Gemini", baseURL: "https://gemini.example/v1"
    )]

    let rows = MenuBarController.apiMenuRows(
        keyEntries: keys, urlEntries: urls, pageOrder: [page]
    )

    #expect(rows == [
        .pageHeader("API Keys"),
        .providerHeader("Gemini"),
        .copyURL(urls[0]),
        .copyKey(keys[0]),
        .copyKey(keys[1]),
        .providerHeader("OpenAI"),
        .copyKey(keys[2]),
    ])
}

@Test @MainActor func apiMenuInstallsFixedHeightScrollableList() {
    let page = UUID()
    let provider = UUID()
    // More content rows than maxVisibleRows so the list must scroll.
    let keys = makeKeyEntries(
        count: MenuBarAPIListView.maxVisibleRows + 8,
        provider: provider, providerName: "Gemini", page: page
    )

    let menu = NSMenu()
    MenuBarController.shared.populateAPIMenu(
        menu, keyEntries: keys, urlEntries: [], pageOrder: [page]
    )

    #expect(menu.items.count == 1)
    let list = menu.items[0].view as? MenuBarAPIListView
    #expect(list != nil)
    let cappedHeight = CGFloat(MenuBarAPIListView.maxVisibleRows) * MenuBarAPIListView.rowHeight
    #expect(list?.frame.height == cappedHeight)
    #expect(list?.scrollView.documentView?.frame.height ?? 0 > cappedHeight)

    // Every key is still present as a copy row inside the scrolled content.
    let copyValues = list?.rowViews.compactMap(\.copyValue) ?? []
    #expect(copyValues.filter { $0.hasPrefix("sk-") }.count == keys.count)
}

@Test @MainActor func apiListRowCopyCallsHandler() {
    var copied: String?
    let entry = MenuBarAPIEntry(
        keyId: UUID(), providerId: UUID(), pageId: UUID(),
        pageTitle: "API Keys", providerName: "Gemini",
        keyValue: "sk-copy-me-9999", createdAt: Date()
    )
    let row = MenuBarAPIListRowView(row: .copyKey(entry)) { copied = $0 }
    row.triggerCopy()
    #expect(copied == "sk-copy-me-9999")
}
