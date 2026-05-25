import Foundation
import AppKit

struct Note: Identifiable, Codable {
    var id: UUID
    var title: String
    var rtfData: Data?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "Untitled", rtfData: Data? = nil) {
        self.id = id
        self.title = title
        self.rtfData = rtfData
        self.createdAt = Date()
        self.updatedAt = Date()
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
