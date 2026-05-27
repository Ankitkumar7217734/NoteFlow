import Foundation
import AppKit

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

    var isTrashed: Bool { deletedAt != nil }

    init(id: UUID = UUID(), title: String = "Untitled", rtfData: Data? = nil) {
        self.id = id
        self.title = title
        self.rtfData = rtfData
        self.createdAt = Date()
        self.updatedAt = Date()
        self.deletedAt = nil
        self.isPinned = false
        self.tags = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, rtfData, createdAt, updatedAt, deletedAt, isPinned, tags
    }

    // Custom decode so JSON files written by older versions (which lack
    // isPinned / tags) still load — missing keys default to not-pinned and
    // an empty tag list.
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
