import SwiftUI

// A single row in the notes list inside the sidebar. Renders the title
// with the search query highlighted and, when the body of the note matches
// the query, a short context snippet around the match in place of the
// "X min ago" timestamp.
struct NoteRow: View {
    let note: Note
    let isActive: Bool
    let query: String

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(highlighted(
                source: note.title,
                query: query,
                size: 13,
                baseWeight: isActive ? .semibold : .regular
            ))
            .foregroundColor(Color.black)
            .lineLimit(1)

            if let snippet = bodySnippet() {
                Text(snippet)
                    .lineLimit(1)
                    .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
            } else {
                Text(Self.dateFormatter.localizedString(for: note.updatedAt, relativeTo: Date()))
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isActive ? Color.black.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    // MARK: – Highlight helpers

    private func highlighted(source: String, query: String, size: CGFloat, baseWeight: Font.Weight) -> AttributedString {
        var attr = AttributedString(source)
        attr.font = .system(size: size, weight: baseWeight)
        guard !query.isEmpty else { return attr }

        var cursor = source.startIndex
        while cursor < source.endIndex,
              let range = source.range(of: query, options: .caseInsensitive, range: cursor..<source.endIndex) {
            if let attrRange = Range<AttributedString.Index>(range, in: attr) {
                attr[attrRange].backgroundColor = Color.yellow.opacity(0.55)
                attr[attrRange].font = .system(size: size, weight: .bold)
            }
            cursor = range.upperBound
        }
        return attr
    }

    private func bodySnippet() -> AttributedString? {
        guard !query.isEmpty else { return nil }
        let body = NoteStore.shared.plainText(for: note.id)
        guard let matchRange = body.range(of: query, options: .caseInsensitive) else { return nil }

        let prefixCount = min(30, body.distance(from: body.startIndex, to: matchRange.lowerBound))
        let suffixCount = min(30, body.distance(from: matchRange.upperBound, to: body.endIndex))
        let startIdx = body.index(matchRange.lowerBound, offsetBy: -prefixCount)
        let endIdx = body.index(matchRange.upperBound, offsetBy: suffixCount)

        var snippet = String(body[startIdx..<endIdx]).replacingOccurrences(of: "\n", with: " ")
        if startIdx > body.startIndex { snippet = "…" + snippet }
        if endIdx < body.endIndex { snippet = snippet + "…" }

        return highlighted(source: snippet, query: query, size: 11, baseWeight: .regular)
    }
}
