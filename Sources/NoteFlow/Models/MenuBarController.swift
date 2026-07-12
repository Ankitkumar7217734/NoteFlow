import AppKit

/// Menu-bar extra (system tray): NoteFlow logo → pinned keys/URLs, API submenu with
/// copy-only actions, show window, quit. Rebuilt whenever the menu opens so
/// keys stay in sync with NoteStore.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            if let cg = AppLogo.processed.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                button.image = NSImage(cgImage: cg, size: NSSize(width: 18, height: 18))
            }
            button.image?.isTemplate = false
            button.toolTip = "NoteFlow"
        }

        menu.delegate = self
        item.menu = menu
        rebuildMenu()

        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuildMenu),
            name: .menuBarPinsChanged, object: nil
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    @objc private func rebuildMenu() {
        menu.removeAllItems()

        let keyEntries = NoteStore.shared.allMenuBarAPIEntries()
        let urlEntries = NoteStore.shared.allMenuBarProviderEntries()
        let pins = MenuBarPinStore.shared

        let pinnedURLs = urlEntries.filter { pins.isProviderPinned($0.providerId) }
        let pinnedKeys = keyEntries.filter { pins.isPinned(entry: $0) }

        if !pinnedURLs.isEmpty || !pinnedKeys.isEmpty {
            let header = NSMenuItem(title: "Pinned", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in pinnedURLs {
                menu.addItem(copyURLItem(for: entry, indent: false))
            }
            for entry in pinnedKeys {
                menu.addItem(copyKeyItem(for: entry, indent: false))
            }
            menu.addItem(.separator())
        }

        let apiItem = NSMenuItem(title: "API", action: nil, keyEquivalent: "")
        let apiMenu = NSMenu()
        populateAPIMenu(
            apiMenu,
            keyEntries: keyEntries,
            urlEntries: urlEntries,
            pageOrder: NoteStore.shared.apiManagerPages().map(\.id)
        )
        apiItem.submenu = apiMenu
        menu.addItem(apiItem)

        menu.addItem(.separator())

        let show = NSMenuItem(
            title: "Show NoteFlow",
            action: #selector(showApp),
            keyEquivalent: ""
        )
        show.target = self
        menu.addItem(show)

        let quit = NSMenuItem(
            title: "Quit NoteFlow",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    /// Page → provider → copy rows for the API submenu. Internal so tests can
    /// pin grouping without touching NoteStore.shared.
    static func apiMenuRows(
        keyEntries: [MenuBarAPIEntry],
        urlEntries: [MenuBarProviderEntry],
        pageOrder: [UUID]
    ) -> [APIMenuRow] {
        var rows: [APIMenuRow] = []
        let keysByPage = Dictionary(grouping: keyEntries, by: \.pageId)
        let urlsByPage = Dictionary(grouping: urlEntries, by: \.pageId)

        for pageId in pageOrder {
            let pageKeys = keysByPage[pageId] ?? []
            let pageURLs = urlsByPage[pageId] ?? []
            guard !pageKeys.isEmpty || !pageURLs.isEmpty else { continue }

            if !rows.isEmpty {
                rows.append(.pageSeparator)
            }

            let pageTitle = pageKeys.first?.pageTitle
                ?? pageURLs.first?.pageTitle
                ?? "API Keys"
            rows.append(.pageHeader(pageTitle))

            var providerIds: [UUID] = []
            for entry in pageKeys where !providerIds.contains(entry.providerId) {
                providerIds.append(entry.providerId)
            }
            for entry in pageURLs where !providerIds.contains(entry.providerId) {
                providerIds.append(entry.providerId)
            }

            let keysByProvider = Dictionary(grouping: pageKeys, by: \.providerId)
            let urlsByProvider = Dictionary(uniqueKeysWithValues: pageURLs.map { ($0.providerId, $0) })

            for providerId in providerIds {
                let keys = keysByProvider[providerId] ?? []
                let providerName = keys.first?.providerName
                    ?? urlsByProvider[providerId]?.providerName
                    ?? "Provider"
                rows.append(.providerHeader(providerName))

                if let urlEntry = urlsByProvider[providerId] {
                    rows.append(.copyURL(urlEntry))
                }
                for entry in keys {
                    rows.append(.copyKey(entry))
                }
            }
        }
        return rows
    }

    /// Installs the API submenu: empty placeholder, or a fixed-height scrollable
    /// list. NSMenu has no height cap of its own — a long native item list
    /// stretches toward full screen — so the rows live in `MenuBarAPIListView`.
    /// Internal so MenuBarTests can drive the layout without NoteStore.shared.
    func populateAPIMenu(
        _ apiMenu: NSMenu,
        keyEntries: [MenuBarAPIEntry],
        urlEntries: [MenuBarProviderEntry],
        pageOrder: [UUID]
    ) {
        if keyEntries.isEmpty && urlEntries.isEmpty {
            let empty = NSMenuItem(title: "No API keys saved", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            apiMenu.addItem(empty)
            return
        }

        let rows = Self.apiMenuRows(
            keyEntries: keyEntries,
            urlEntries: urlEntries,
            pageOrder: pageOrder
        )
        let list = MenuBarAPIListView(rows: rows) { value in
            NoteStore.shared.copyToPasteboard(value)
        }
        let item = NSMenuItem()
        item.view = list
        apiMenu.addItem(item)
    }

    private func copyKeyItem(for entry: MenuBarAPIEntry, indent: Bool) -> NSMenuItem {
        let prefix = indent ? "    Copy key  ·  " : "Copy key  ·  "
        let item = NSMenuItem(
            title: prefix + entry.menuTitle,
            action: #selector(copyAPIKey(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = entry.keyValue
        return item
    }

    private func copyURLItem(for entry: MenuBarProviderEntry, indent: Bool) -> NSMenuItem {
        let prefix = indent ? "    Copy URL  ·  " : "Copy URL  ·  "
        let item = NSMenuItem(
            title: prefix + entry.menuTitle,
            action: #selector(copyBaseURL(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = entry.baseURL
        return item
    }

    @objc private func copyAPIKey(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NoteStore.shared.copyToPasteboard(value)
    }

    @objc private func copyBaseURL(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NoteStore.shared.copyToPasteboard(value)
    }

    @objc private func showApp() {
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
