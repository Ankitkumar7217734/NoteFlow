import Foundation
import AppKit

/// What kind of page a `Note` is. `.richText` is the default RTF editor page
/// (everything the app has ever stored); `.apiManager` is the API Key Manager
/// page, which carries a structured `providers` payload instead of `rtfData`.
enum NoteKind: String, Codable {
    case richText
    case apiManager
}

/// A single stored API key inside an `APIProvider`. `value` is the secret.
struct APIKeyEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var label: String = ""       // optional user label, e.g. "prod" / "personal"
    var value: String = ""       // the secret itself
    var createdAt: Date = Date()
}

/// An AI provider (e.g. "OpenRouter") holding any number of API keys.
struct APIProvider: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// Endpoint base URL for this provider (e.g. `https://api.openai.com/v1`).
    var baseURL: String = ""
    var name: String = ""
    var keys: [APIKeyEntry] = []
    var createdAt: Date = Date()

    init(id: UUID = UUID(), baseURL: String = "", name: String = "",
         keys: [APIKeyEntry] = [], createdAt: Date = Date()) {
        self.id = id
        self.baseURL = baseURL
        self.name = name
        self.keys = keys
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, baseURL, name, keys, createdAt
    }

    // Older notes.json files omit `baseURL`; default to "" so the whole store
    // still loads (without this, one legacy provider bricks every note).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        name = try c.decode(String.self, forKey: .name)
        keys = try c.decodeIfPresent([APIKeyEntry].self, forKey: .keys) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct Note: Identifiable, Codable {
    var id: UUID
    var title: String
    var rtfData: Data?
    var createdAt: Date
    var updatedAt: Date
    /// Non-nil when the note is in the Trash. Codable handles missing key
    /// by leaving this nil, so notes.json files written by older versions
    /// still decode (those notes are treated as not-trashed).
    var deletedAt: Date?
    var isPinned: Bool
    var tags: [String]
    /// The page kind. Older notes.json files lack this key and decode to
    /// `.richText` (see init(from:)), so existing notes keep working.
    var kind: NoteKind
    /// Structured payload for `.apiManager` pages. `nil` for RTF notes; the
    /// key is simply omitted from their JSON.
    var providers: [APIProvider]?
    /// When false, the title is derived from the note body until the user
    /// renames the tab themselves.
    var titleIsManual: Bool = false

    var isTrashed: Bool { deletedAt != nil }

    // MARK: – API Manager helpers
    var isAPIManager: Bool { kind == .apiManager }
    var providerCount: Int { providers?.count ?? 0 }
    var keyCount: Int { providers?.reduce(0) { $0 + $1.keys.count } ?? 0 }

    init(id: UUID = UUID(), title: String = "Untitled", rtfData: Data? = nil) {
        self.id = id
        self.title = title
        self.rtfData = rtfData
        self.createdAt = Date()
        self.updatedAt = Date()
        self.deletedAt = nil
        self.isPinned = false
        self.tags = []
        self.kind = .richText
        self.providers = nil
    }

    /// Build an API Key Manager page: no RTF body, an empty provider list, and
    /// auto-pinned so it lives in the sidebar's "Pinned" section.
    init(apiManagerTitled title: String) {
        self.init(title: title)
        self.kind = .apiManager
        self.providers = []
        self.isPinned = true
        self.titleIsManual = true
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, rtfData, createdAt, updatedAt, deletedAt, isPinned, tags, kind, providers, titleIsManual
    }

    // Custom decode so JSON files written by older versions (which lack
    // isPinned / tags / kind / providers) still load — missing keys default to
    // not-pinned, an empty tag list, and a plain rich-text note.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        rtfData = try c.decodeIfPresent(Data.self, forKey: .rtfData)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        kind = try c.decodeIfPresent(NoteKind.self, forKey: .kind) ?? .richText
        providers = try c.decodeIfPresent([APIProvider].self, forKey: .providers)
        // Notes saved before auto-titles existed: treat any non-default title
        // as user-chosen so we don't overwrite it from the body on open.
        titleIsManual = try c.decodeIfPresent(Bool.self, forKey: .titleIsManual)
            ?? (!title.isEmpty && title != "Untitled")
    }

    var attributedContent: NSAttributedString {
        guard let data = rtfData,
              let str = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ) else {
            return NSAttributedString()
        }
        return str
    }
}
