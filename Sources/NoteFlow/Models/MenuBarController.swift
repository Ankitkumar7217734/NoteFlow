import AppKit

/// Menu-bar extra (system tray): NoteFlow logo → pinned keys, API submenu with
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

        let entries = NoteStore.shared.allMenuBarAPIEntries()
        let pinned = entries.filter { MenuBarPinStore.shared.isPinned(entry: $0) }

        if !pinned.isEmpty {
            let header = NSMenuItem(title: "Pinned", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in pinned {
                menu.addItem(copyItem(for: entry))
            }
            menu.addItem(.separator())
        }

        let apiItem = NSMenuItem(title: "API", action: nil, keyEquivalent: "")
        let apiMenu = NSMenu()
        populateAPIMenu(apiMenu, entries: entries)
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

    private func populateAPIMenu(_ apiMenu: NSMenu, entries: [MenuBarAPIEntry]) {
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No API keys saved", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            apiMenu.addItem(empty)
            return
        }

        let byPage = Dictionary(grouping: entries, by: \.pageId)
        let pageOrder = NoteStore.shared.apiManagerPages().map(\.id)

        for pageId in pageOrder {
            guard let pageEntries = byPage[pageId], !pageEntries.isEmpty else { continue }
            let pageTitle = pageEntries[0].pageTitle

            let pageHeader = NSMenuItem(title: pageTitle, action: nil, keyEquivalent: "")
            pageHeader.isEnabled = false
            apiMenu.addItem(pageHeader)

            let byProvider = Dictionary(grouping: pageEntries, by: \.providerId)
            let providerOrder = pageEntries.map(\.providerId).reduce(into: [UUID]()) { ids, id in
                if !ids.contains(id) { ids.append(id) }
            }

            for providerId in providerOrder {
                guard let keys = byProvider[providerId], !keys.isEmpty else { continue }
                let providerName = keys[0].providerName

                let providerHeader = NSMenuItem(
                    title: "  \(providerName)",
                    action: nil,
                    keyEquivalent: ""
                )
                providerHeader.isEnabled = false
                apiMenu.addItem(providerHeader)

                for entry in keys {
                    let row = copyItem(for: entry)
                    row.title = "    Copy  ·  \(entry.menuTitle)"
                    apiMenu.addItem(row)
                }
            }

            apiMenu.addItem(.separator())
        }

        if apiMenu.items.last?.isSeparatorItem == true {
            apiMenu.removeItem(at: apiMenu.items.count - 1)
        }
    }

    private func copyItem(for entry: MenuBarAPIEntry) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Copy  ·  \(entry.menuTitle)",
            action: #selector(copyAPIKey(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = entry.keyValue
        return item
    }

    @objc private func copyAPIKey(_ sender: NSMenuItem) {
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
