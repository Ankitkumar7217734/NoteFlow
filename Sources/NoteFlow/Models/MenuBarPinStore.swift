import Foundation
import Combine

extension Notification.Name {
    static let menuBarPinsChanged = Notification.Name("menuBarPinsChanged")
}

/// Which API keys / providers / pages appear in the menu-bar "Pinned" section.
final class MenuBarPinStore: ObservableObject {
    static let shared = MenuBarPinStore()

    private let defaults: UserDefaults
    private let keysKey = "menuBarPinnedKeyIds"
    private let providersKey = "menuBarPinnedProviderIds"
    private let pagesKey = "menuBarPinnedPageIds"

    @Published private(set) var pinnedKeyIds: Set<UUID>
    @Published private(set) var pinnedProviderIds: Set<UUID>
    @Published private(set) var pinnedPageIds: Set<UUID>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinnedKeyIds = Self.loadUUIDs(from: defaults.stringArray(forKey: keysKey))
        pinnedProviderIds = Self.loadUUIDs(from: defaults.stringArray(forKey: providersKey))
        pinnedPageIds = Self.loadUUIDs(from: defaults.stringArray(forKey: pagesKey))
    }

    func isKeyPinned(_ id: UUID) -> Bool { pinnedKeyIds.contains(id) }
    func isProviderPinned(_ id: UUID) -> Bool { pinnedProviderIds.contains(id) }
    func isPagePinned(_ id: UUID) -> Bool { pinnedPageIds.contains(id) }

    func isPinned(entry: MenuBarAPIEntry) -> Bool {
        pinnedKeyIds.contains(entry.keyId)
            || pinnedProviderIds.contains(entry.providerId)
            || pinnedPageIds.contains(entry.pageId)
    }

    func toggleKeyPin(_ id: UUID) {
        if pinnedKeyIds.contains(id) { pinnedKeyIds.remove(id) }
        else { pinnedKeyIds.insert(id) }
        persist()
    }

    func toggleProviderPin(_ id: UUID) {
        if pinnedProviderIds.contains(id) { pinnedProviderIds.remove(id) }
        else { pinnedProviderIds.insert(id) }
        persist()
    }

    func togglePagePin(_ id: UUID) {
        if pinnedPageIds.contains(id) { pinnedPageIds.remove(id) }
        else { pinnedPageIds.insert(id) }
        persist()
    }

    private func persist() {
        defaults.set(Array(pinnedKeyIds).map(\.uuidString), forKey: keysKey)
        defaults.set(Array(pinnedProviderIds).map(\.uuidString), forKey: providersKey)
        defaults.set(Array(pinnedPageIds).map(\.uuidString), forKey: pagesKey)
        NotificationCenter.default.post(name: .menuBarPinsChanged, object: nil)
    }

    private static func loadUUIDs(from strings: [String]?) -> Set<UUID> {
        guard let strings else { return [] }
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }
}

/// One copyable API key row for the menu bar (built from all `.apiManager` pages).
struct MenuBarAPIEntry: Equatable, Identifiable {
    var id: UUID { keyId }
    let keyId: UUID
    let providerId: UUID
    let pageId: UUID
    let pageTitle: String
    let providerName: String
    let keyValue: String
    let createdAt: Date

    /// Single-line label: provider plus a masked tail so the row is recognizable.
    var menuTitle: String {
        "\(providerName)  ·  \(Self.mask(keyValue))"
    }

    static func mask(_ value: String) -> String {
        guard value.count > 4 else { return String(repeating: "•", count: max(value.count, 4)) }
        return String(repeating: "•", count: min(value.count - 4, 8)) + value.suffix(4)
    }
}
