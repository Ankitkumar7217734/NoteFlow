import AppKit
import UniformTypeIdentifiers

// The file formats a note can be imported from. This is the inverse of
// ExportFormat / NoteExporter: where the exporter turns a note's rich text
// into Markdown / plain text, the importer turns a Markdown / plain-text file
// back into rich text using NoteFlow's own conventions (bullet `• `, checklist
// `☐ `, numbered `N. `, monospaced inline code, themed ink, …).
enum ImportFormat {
    case markdown
    case plainText

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mkdn", "mdwn":
            self = .markdown
        case "txt", "text":
            self = .plainText
        default:
            return nil
        }
    }

    // Content types the open panel constrains selection to. Markdown's UTType
    // isn't guaranteed to be registered on every machine, so we try a couple
    // of spellings and fall back to plain text.
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = []
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let md = UTType("net.daringfireball.markdown") { types.append(md) }
        types.append(.plainText)
        types.append(.text)
        var seen = Set<UTType>()
        return types.filter { seen.insert($0).inserted }
    }
}

// Reads a Markdown / plain-text file and produces an NSAttributedString ready
// to become a note. Markdown formatting is rendered with NoteFlow's editor
// conventions so an imported file looks the same as a note typed in the app.
enum NoteImporter {

    /// Decode the file at `url` and convert it to rich text. Markdown is run
    /// through `MarkdownParser`; plain text is wrapped in the editor's base
    /// font + themed ink. Bare URLs are linkified afterward (same as paste).
    static func attributedString(forFileAt url: URL) throws -> NSAttributedString {
        let format = ImportFormat(fileExtension: url.pathExtension) ?? .plainText
        let raw = try readText(at: url)
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")

        let attributed: NSAttributedString
        switch format {
        case .markdown:
            attributed = MarkdownParser.attributedString(from: normalized)
        case .plainText:
            attributed = NSAttributedString(string: normalized, attributes: [
                .font: EditorTypography.baseFont,
                .foregroundColor: Palette.dynamicInkNS
            ])
        }
        // Linkify bare URLs the way the editor does on paste.
        return NoteTextView.autoLink(attributed)
    }

    /// Read the file as text. Tries UTF-8, then any encoding Foundation can
    /// detect (BOM / heuristics), then Latin-1 — which decodes any byte
    /// sequence — so a stray non-UTF-8 byte never makes an import fail.
    private static func readText(at url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        var used: String.Encoding = .utf8
        if let detected = try? String(contentsOf: url, usedEncoding: &used) {
            return detected
        }
        if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
            return latin1
        }
        // Surface a real error (unreadable / missing file) to the caller.
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Warn the user about files that couldn't be read. Other files in the
    /// same import still come through — this is informational, not fatal.
    static func presentImportError(files: [String]) {
        let alert = NSAlert()
        alert.messageText = files.count == 1
            ? "Couldn’t import a file"
            : "Couldn’t import \(files.count) files"
        alert.informativeText = "These files couldn’t be read:\n• "
            + files.joined(separator: "\n• ")
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// Converts Markdown text into an NSAttributedString using NoteFlow's editor
// conventions. It's the deliberate inverse of `NoteExporter.markdown(from:)`:
// every marker the exporter emits is parsed back here, so an export → import
// round-trip reproduces the same formatting.
//
// Block level (per line): ATX headings, fenced code, unordered / ordered /
// task lists, blockquotes, horizontal rules. Inline level: backslash escapes,
// code spans, `<u>`, links / images, `*`/`_` emphasis, `~~` strikethrough.
//
// Scope notes (documented limitations): nested-list indentation is flattened
// (NoteFlow's lists are flat plain-text prefixes), and setext headings
// (`===` / `---` underlines) are not supported — a lone `---` is a rule.
enum MarkdownParser {

    // MARK: – Fonts / default attributes

    private static var baseFont: NSFont { EditorTypography.baseFont }
    private static var monoFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: EditorTypography.baseFontSize, weight: .regular)
    }
    private static var defaultAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: Palette.dynamicInkNS]
    }
    // Code runs (inline + fenced) get a translucent background so they read
    // as code chips, clearly distinct from body text. A 50%-gray composites
    // over whichever editor background is current, so it adapts to light/dark
    // for free; NoteLayoutManager already paints background runs with rounded
    // corners. The alpha is deliberately strong enough to be obvious — a
    // monospace font alone reads too much like the proportional body text.
    private static let codeBackground = NSColor(white: 0.5, alpha: 0.22)
    private static var codeAttributes: [NSAttributedString.Key: Any] {
        [.font: monoFont,
         .foregroundColor: Palette.dynamicInkNS,
         .backgroundColor: codeBackground]
    }

    // Heading point sizes by level (index 0 = H1). All render bold; sizes stay
    // at or near the 14pt body so every level reads as a heading without
    // dwarfing it. Must keep six entries — renderHeading indexes by level.
    private static let headingSizes: [CGFloat] = [24, 20, 17, 15.5, 14, 13]

    // MARK: – Paragraph styles (vertical rhythm)
    //
    // These give imported notes breathing room. Only *vertical* metrics are
    // set — horizontal indents are deliberately left at 0 because
    // NoteStore.normalizeParagraphStyles zeroes them on note-open to keep one
    // straight left margin (it preserves the vertical metrics below). Block
    // structure (lists, quotes) is carried by glyph prefixes, not indents.

    private static func makeParagraphStyle(lineSpacing: CGFloat,
                                           paragraphSpacing: CGFloat,
                                           paragraphSpacingBefore: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .natural
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.paragraphSpacingBefore = paragraphSpacingBefore
        return style
    }

    private static let bodyParagraphStyle =
        makeParagraphStyle(lineSpacing: 3, paragraphSpacing: 6, paragraphSpacingBefore: 0)
    private static let listParagraphStyle =
        makeParagraphStyle(lineSpacing: 3, paragraphSpacing: 2, paragraphSpacingBefore: 0)
    private static let blockquoteParagraphStyle =
        makeParagraphStyle(lineSpacing: 3, paragraphSpacing: 6, paragraphSpacingBefore: 0)
    private static let codeParagraphStyle =
        makeParagraphStyle(lineSpacing: 3, paragraphSpacing: 0, paragraphSpacingBefore: 0)
    // Empty source lines carry an explicitly zeroed style so their height
    // doesn't stack on top of the surrounding blocks' paragraph spacing.
    private static let blankParagraphStyle =
        makeParagraphStyle(lineSpacing: 0, paragraphSpacing: 0, paragraphSpacingBefore: 0)

    private static func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        // More air above higher-level headings; a little below before the body.
        let before = max(12 - 2 * CGFloat(level - 1), 4)
        return makeParagraphStyle(lineSpacing: 2, paragraphSpacing: 4, paragraphSpacingBefore: before)
    }

    // Attach a paragraph style across the whole piece and return it.
    private static func withParagraphStyle(_ style: NSParagraphStyle,
                                           _ body: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: body)
        result.addAttribute(.paragraphStyle, value: style,
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: – Entry point

    // A rendered block. Most blocks are single-line `.line` pieces joined by
    // newlines; a `.table` piece is a self-contained NSTextTable (it carries
    // its own internal cell newlines + a trailing closing paragraph) and is
    // appended verbatim so the join logic doesn't split its structure.
    private enum Block {
        case line(NSAttributedString)
        case table(NSAttributedString)
    }

    static func attributedString(from markdown: String) -> NSAttributedString {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
                                 .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var blocks: [Block] = []
        var inFence = false
        var fenceChar: Character = "`"
        var fenceLen = 0

        var i = 0
        while i < lines.count {
            let line = lines[i]

            if let fence = fenceInfo(line) {
                if !inFence {
                    inFence = true
                    fenceChar = fence.char
                    fenceLen = fence.count
                    i += 1
                    continue // drop the opening fence line
                } else if fence.char == fenceChar && fence.count >= fenceLen && fence.pure {
                    inFence = false
                    i += 1
                    continue // drop the closing fence line
                }
                // Otherwise it's a fence-like line of the other delimiter (or
                // one carrying an info string) sitting inside a code block —
                // fall through and treat it as code content.
            }

            if inFence {
                blocks.append(.line(withParagraphStyle(codeParagraphStyle,
                    NSAttributedString(string: line, attributes: codeAttributes))))
                i += 1
                continue
            }

            // GFM table: a header row, a delimiter row (| --- | :-: | ---: |),
            // then zero or more body rows. Detect by looking one line ahead.
            if i + 1 < lines.count,
               line.contains("|"),
               let aligns = tableDelimiterAlignments(lines[i + 1]),
               splitTableRow(line).count == aligns.count {
                let header = splitTableRow(line)
                var bodyRows: [[String]] = []
                var j = i + 2
                while j < lines.count, lines[j].contains("|"),
                      tableDelimiterAlignments(lines[j]) == nil,
                      !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    bodyRows.append(splitTableRow(lines[j]))
                    j += 1
                }
                blocks.append(.table(buildTable(header: header,
                                                alignments: aligns,
                                                bodyRows: bodyRows)))
                // The table supplies its own trailing blank line, so swallow a
                // single blank source line after it to avoid a doubled gap.
                if j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    j += 1
                }
                i = j
                continue
            }

            blocks.append(.line(renderBlockLine(line)))
            i += 1
        }

        return assemble(blocks)
    }

    // Stitch blocks together. `.line` pieces are joined with newline
    // separators that carry the piece's own paragraph style (so each
    // paragraph — text plus its terminating newline — is uniform). A `.table`
    // piece already ends with its own closing newline, so it's appended as-is
    // and only needs a clean newline boundary before it.
    private static func assemble(_ blocks: [Block]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        func endsWithNewline() -> Bool {
            result.length > 0 && (result.string as NSString).hasSuffix("\n")
        }

        for (idx, block) in blocks.enumerated() {
            switch block {
            case .line(let piece):
                result.append(piece)
                if idx < blocks.count - 1 {
                    let style = piece.length > 0
                        ? (piece.attribute(.paragraphStyle, at: piece.length - 1,
                                           effectiveRange: nil) as? NSParagraphStyle)
                        : blankParagraphStyle
                    var attrs = defaultAttributes
                    attrs[.paragraphStyle] = style ?? bodyParagraphStyle
                    result.append(NSAttributedString(string: "\n", attributes: attrs))
                }
            case .table(let table):
                // Tables start on a fresh line; the table string supplies its
                // own trailing closing newline, so nothing is added after it.
                if result.length > 0 && !endsWithNewline() {
                    result.append(NSAttributedString(string: "\n", attributes: defaultAttributes))
                }
                result.append(table)
            }
        }
        return result
    }

    // MARK: – Tables (GFM)

    // Split a table row into trimmed cell strings. A backslash-escaped pipe
    // (`\|`) is a literal pipe inside a cell. The optional leading / trailing
    // pipes that delimit a GFM row are dropped.
    private static func splitTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        let chars = Array(s)
        var cells: [String] = []
        var current = ""
        var k = 0
        while k < chars.count {
            let c = chars[k]
            if c == "\\", k + 1 < chars.count, chars[k + 1] == "|" {
                current.append("|"); k += 2; continue
            }
            if c == "|" { cells.append(current); current = ""; k += 1; continue }
            current.append(c); k += 1
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // If `line` is a GFM delimiter row — cells of optional `:` + one-or-more
    // `-` + optional `:`, pipe-separated, with at least one pipe — return each
    // column's alignment; otherwise nil. The pipe requirement keeps a lone
    // `---` (a thematic break) from being read as a one-column table.
    private static func tableDelimiterAlignments(_ line: String) -> [NSTextAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-"),
              trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " })
        else { return nil }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return nil }
        var aligns: [NSTextAlignment] = []
        for cell in cells {
            guard cell.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            aligns.append((left && right) ? .center : right ? .right : left ? .left : .natural)
        }
        return aligns
    }

    // Build a self-contained NSTextTable attributed string, mirroring the
    // editor's own table construction (`FormattingToolbarView.insertTable`) so
    // imported tables render identically and trip the same contiguous-layout
    // switch (`NoteTextView.containsTables`). Each cell is one paragraph whose
    // style carries an `NSTextTableBlock`; a trailing default paragraph closes
    // the table even at end of document.
    private static func buildTable(header: [String],
                                   alignments: [NSTextAlignment],
                                   bodyRows: [[String]]) -> NSAttributedString {
        let cols = alignments.count
        let palette = ThemeStore.shared.palette
        let borderColor = palette.tableBorderNS
        let headerBg = palette.tableHeaderBgNS

        let table = NSTextTable()
        table.numberOfColumns = cols
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        var rows: [[String]] = [header]
        rows.append(contentsOf: bodyRows)

        let result = NSMutableAttributedString()
        for (r, row) in rows.enumerated() {
            for c in 0..<cols {
                let block = NSTextTableBlock(table: table,
                                             startingRow: r, rowSpan: 1,
                                             startingColumn: c, columnSpan: 1)
                block.setBorderColor(borderColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(8, type: .absoluteValueType, for: .padding)
                if r == 0 { block.backgroundColor = headerBg }

                let para = NSMutableParagraphStyle()
                para.textBlocks = [block]
                para.alignment = alignments[c]

                let raw = c < row.count ? row[c] : ""
                // A space keeps an empty cell from collapsing to zero height.
                let cellText = raw.isEmpty ? " " : raw
                let cell = NSMutableAttributedString(attributedString: parseInline(Array(cellText)))
                if r == 0 { applyBoldTrait(to: cell) }
                // The terminating newline belongs to the cell paragraph.
                cell.append(NSAttributedString(string: "\n", attributes: defaultAttributes))
                cell.addAttribute(.paragraphStyle, value: para,
                                  range: NSRange(location: 0, length: cell.length))
                result.append(cell)
            }
        }
        // Closing paragraph (no text block) terminates the table.
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: baseFont,
            .foregroundColor: Palette.dynamicInkNS,
            .paragraphStyle: NSParagraphStyle.default
        ]))
        return result
    }

    private static func applyBoldTrait(to s: NSMutableAttributedString) {
        guard s.length > 0 else { return }
        let fm = NSFontManager.shared
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length),
                             options: []) { value, range, _ in
            let font = fm.convert((value as? NSFont) ?? baseFont, toHaveTrait: .boldFontMask)
            s.addAttribute(.font, value: font, range: range)
        }
    }

    // MARK: – Fenced code detection

    private struct Fence { let char: Character; let count: Int; let pure: Bool }

    // A fence is 3+ backticks or tildes after up to 3 leading spaces. `pure`
    // means nothing but the fence chars follow (required of a *closing* fence);
    // an opening fence may carry an info string. A backtick fence's info string
    // may not contain a backtick (CommonMark), so we reject that case.
    private static func fenceInfo(_ line: String) -> Fence? {
        let trimmed = line.drop(while: { $0 == " " })
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx] == first {
            count += 1
            idx = trimmed.index(after: idx)
        }
        guard count >= 3 else { return nil }
        let rest = trimmed[idx...]
        if first == "`" && rest.contains(where: { $0 == "`" }) { return nil }
        let pure = String(rest).trimmingCharacters(in: .whitespaces).isEmpty
        return Fence(char: first, count: count, pure: pure)
    }

    // MARK: – Block-level rendering

    private static func renderBlockLine(_ line: String) -> NSAttributedString {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty source line — zeroed style so it doesn't stack height on
            // top of the neighbouring blocks' paragraph spacing.
            return withParagraphStyle(blankParagraphStyle,
                NSAttributedString(string: "", attributes: defaultAttributes))
        }
        if isHorizontalRule(line) {
            return withParagraphStyle(bodyParagraphStyle,
                NSAttributedString(string: String(repeating: "—", count: 24),
                                   attributes: defaultAttributes))
        }
        if let heading = parseHeading(line) {
            return withParagraphStyle(headingParagraphStyle(level: heading.level),
                renderHeading(text: heading.text, level: heading.level))
        }
        if let inner = parseBlockquote(line) {
            return withParagraphStyle(blockquoteParagraphStyle, renderBlockquote(inner))
        }
        if let task = parseTaskList(line) {
            return withParagraphStyle(listParagraphStyle,
                prefixed(task.checked ? "☑ " : "☐ ", parseInline(Array(task.rest))))
        }
        if let rest = parseUnorderedList(line) {
            return withParagraphStyle(listParagraphStyle,
                prefixed("• ", parseInline(Array(rest))))
        }
        if let ordered = parseOrderedList(line) {
            return withParagraphStyle(listParagraphStyle,
                prefixed("\(ordered.number). ", parseInline(Array(ordered.rest))))
        }
        return withParagraphStyle(bodyParagraphStyle, parseInline(Array(line)))
    }

    // A blockquote line: a "▎ " bar marker plus italicized body, so quotes
    // read distinctly from body text. The marker is a glyph (not a paragraph
    // indent) so it survives note-open normalization; NoteExporter maps it
    // back to "> " on export.
    private static func renderBlockquote(_ inner: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "▎ ", attributes: defaultAttributes)
        let body = NSMutableAttributedString(attributedString: parseInline(Array(inner)))
        if body.length > 0 {
            let fm = NSFontManager.shared
            body.enumerateAttribute(.font, in: NSRange(location: 0, length: body.length),
                                    options: []) { value, range, _ in
                let font = fm.convert((value as? NSFont) ?? baseFont, toHaveTrait: .italicFontMask)
                body.addAttribute(.font, value: font, range: range)
            }
        }
        result.append(body)
        return result
    }

    private static func prefixed(_ prefix: String, _ body: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: prefix, attributes: defaultAttributes)
        result.append(body)
        return result
    }

    // A line of 3+ of the same marker (-, *, _), spaces allowed between them.
    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.filter { $0 != " " && $0 != "\t" }
        guard stripped.count >= 3, let first = stripped.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private static let headingRegex = try! NSRegularExpression(
        pattern: #"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$"#
    )

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let ns = line as NSString
        guard let m = headingRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        let level = m.range(at: 1).length
        var text = ""
        let textRange = m.range(at: 2)
        if textRange.location != NSNotFound { text = ns.substring(with: textRange) }
        // Strip an ATX closing sequence ("## foo ##" → "foo"); it must be
        // preceded by whitespace, so "foo#" (a literal trailing #) is kept.
        if let r = text.range(of: #"\s+#+\s*$"#, options: .regularExpression) {
            text.removeSubrange(r)
        }
        return (level, text)
    }

    private static func renderHeading(text: String, level: Int) -> NSAttributedString {
        let size = headingSizes[min(max(level, 1), headingSizes.count) - 1]
        let result = NSMutableAttributedString(attributedString: parseInline(Array(text)))
        guard result.length > 0 else { return result }
        let fm = NSFontManager.shared
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length),
                                  options: []) { value, range, _ in
            var font = fm.convert((value as? NSFont) ?? baseFont, toSize: size)
            font = fm.convert(font, toHaveTrait: .boldFontMask)
            result.addAttribute(.font, value: font, range: range)
        }
        return result
    }

    private static func parseBlockquote(_ line: String) -> String? {
        guard let m = line.range(of: #"^ {0,3}> ?"#, options: .regularExpression) else { return nil }
        return String(line[m.upperBound...])
    }

    private static func parseTaskList(_ line: String) -> (checked: Bool, rest: String)? {
        guard let m = line.range(of: #"^\s*[-*+]\s+\[[ xX]\]\s+"#, options: .regularExpression)
        else { return nil }
        let prefix = String(line[m])
        let checked = prefix.contains { $0 == "x" || $0 == "X" }
        return (checked, String(line[m.upperBound...]))
    }

    private static func parseUnorderedList(_ line: String) -> String? {
        guard let m = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) else { return nil }
        return String(line[m.upperBound...])
    }

    private static func parseOrderedList(_ line: String) -> (number: Int, rest: String)? {
        guard let m = line.range(of: #"^\s*\d{1,9}[.)]\s+"#, options: .regularExpression)
        else { return nil }
        let digits = String(line[m]).filter { $0.isNumber }
        guard let n = Int(digits) else { return nil }
        return (n, String(line[m.upperBound...]))
    }

    // MARK: – Inline rendering

    private static let escapable = Set(##"!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##)

    // Left-to-right scanner over one line's characters. Recurses on the inner
    // content of emphasis / links / `<u>` so nesting composes.
    private static func parseInline(_ chars: [Character]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = 0
        var plainStart = 0

        func flushPlain(upTo end: Int) {
            if end > plainStart {
                result.append(NSAttributedString(string: String(chars[plainStart..<end]),
                                                 attributes: defaultAttributes))
            }
        }

        while i < chars.count {
            let c = chars[i]

            // Backslash escape: a backslash before ASCII punctuation emits that
            // punctuation literally (so `\*` is a literal asterisk).
            if c == "\\", i + 1 < chars.count, escapable.contains(chars[i + 1]) {
                flushPlain(upTo: i)
                result.append(NSAttributedString(string: String(chars[i + 1]),
                                                 attributes: defaultAttributes))
                i += 2
                plainStart = i
                continue
            }

            // Code span — highest precedence, no nested parsing inside.
            if c == "`" {
                let run = runLength(chars, i, "`")
                if let close = findBacktickRun(chars, from: i + run, length: run) {
                    flushPlain(upTo: i)
                    var start = i + run
                    var end = close
                    // CommonMark: trim one leading + trailing space if both
                    // present and the content isn't all spaces.
                    if end > start, chars[start] == " ", chars[end - 1] == " ",
                       !chars[start..<end].allSatisfy({ $0 == " " }) {
                        start += 1; end -= 1
                    }
                    result.append(NSAttributedString(string: String(chars[start..<end]),
                                                     attributes: codeAttributes))
                    i = close + run
                    plainStart = i
                    continue
                }
            }

            // <u>…</u> → underline.
            if c == "<", matchTag(chars, i, "<u>"), let close = findTag(chars, from: i + 3, tag: "</u>") {
                flushPlain(upTo: i)
                let inner = NSMutableAttributedString(attributedString:
                    parseInline(Array(chars[(i + 3)..<close])))
                inner.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                   range: NSRange(location: 0, length: inner.length))
                result.append(inner)
                i = close + 4
                plainStart = i
                continue
            }

            // Image ![alt](url) — rendered as its alt text linked to the URL.
            if c == "!", i + 1 < chars.count, chars[i + 1] == "[",
               let link = parseLink(chars, bracketOpen: i + 1) {
                flushPlain(upTo: i)
                result.append(makeLink(label: link.label, dest: link.dest))
                i = link.end
                plainStart = i
                continue
            }

            // Link [text](url).
            if c == "[", let link = parseLink(chars, bracketOpen: i) {
                flushPlain(upTo: i)
                result.append(makeLink(label: link.label, dest: link.dest))
                i = link.end
                plainStart = i
                continue
            }

            // Strikethrough ~~…~~.
            if c == "~", runLength(chars, i, "~") >= 2,
               let close = findRun(chars, from: i + 2, char: "~", minLength: 2) {
                flushPlain(upTo: i)
                let inner = NSMutableAttributedString(attributedString:
                    parseInline(Array(chars[(i + 2)..<close])))
                inner.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                   range: NSRange(location: 0, length: inner.length))
                result.append(inner)
                i = close + 2
                plainStart = i
                continue
            }

            // Emphasis * / _ / ** / __ / *** / ___.
            if c == "*" || c == "_", let emph = parseEmphasis(chars, start: i) {
                flushPlain(upTo: i)
                result.append(emph.attributed)
                i = emph.end
                plainStart = i
                continue
            }

            i += 1
        }
        flushPlain(upTo: chars.count)
        return result
    }

    private static func makeLink(label: [Character], dest: String) -> NSAttributedString {
        let inner = NSMutableAttributedString(attributedString: parseInline(label))
        if inner.length == 0 {
            inner.append(NSAttributedString(string: dest, attributes: defaultAttributes))
        }
        // Match the editor's link normalization: add a scheme if there's none.
        let normalized = dest.contains("://") ? dest : "https://\(dest)"
        if let url = URL(string: normalized) {
            inner.addAttribute(.link, value: url, range: NSRange(location: 0, length: inner.length))
        }
        return inner
    }

    // MARK: – Inline scanning helpers

    private static func runLength(_ chars: [Character], _ i: Int, _ c: Character) -> Int {
        var n = 0
        var j = i
        while j < chars.count, chars[j] == c { n += 1; j += 1 }
        return n
    }

    // Start index of the next run of exactly `length` backticks at/after `from`.
    private static func findBacktickRun(_ chars: [Character], from: Int, length: Int) -> Int? {
        var j = from
        while j < chars.count {
            if chars[j] == "`" {
                let len = runLength(chars, j, "`")
                if len == length { return j }
                j += len
            } else {
                j += 1
            }
        }
        return nil
    }

    // Start index of the next run of `char` with length >= minLength.
    private static func findRun(_ chars: [Character], from: Int, char: Character, minLength: Int) -> Int? {
        var j = from
        while j < chars.count {
            if chars[j] == char {
                let len = runLength(chars, j, char)
                if len >= minLength { return j }
                j += len
            } else {
                j += 1
            }
        }
        return nil
    }

    private static func matchTag(_ chars: [Character], _ i: Int, _ tag: String) -> Bool {
        let t = Array(tag)
        guard i + t.count <= chars.count else { return false }
        for k in 0..<t.count where String(chars[i + k]).lowercased() != String(t[k]).lowercased() {
            return false
        }
        return true
    }

    private static func findTag(_ chars: [Character], from: Int, tag: String) -> Int? {
        let t = Array(tag)
        guard !t.isEmpty else { return nil }
        var j = from
        while j + t.count <= chars.count {
            if matchTag(chars, j, tag) { return j }
            j += 1
        }
        return nil
    }

    // Parses `[label](dest)` starting at the `[`. Returns the label characters,
    // the (cleaned) destination, and the index just past the closing `)`.
    private static func parseLink(_ chars: [Character], bracketOpen: Int)
        -> (label: [Character], dest: String, end: Int)? {
        guard bracketOpen < chars.count, chars[bracketOpen] == "[" else { return nil }

        // Matching ] (allowing nested brackets + escapes).
        var depth = 0
        var j = bracketOpen
        var closeBracket = -1
        while j < chars.count {
            let c = chars[j]
            if c == "\\" { j += 2; continue }
            if c == "[" { depth += 1 }
            else if c == "]" { depth -= 1; if depth == 0 { closeBracket = j; break } }
            j += 1
        }
        guard closeBracket >= 0, closeBracket + 1 < chars.count,
              chars[closeBracket + 1] == "(" else { return nil }

        // Matching ) (allowing nested parens + escapes).
        let parenOpen = closeBracket + 1
        var k = parenOpen + 1
        var depthP = 1
        var closeParen = -1
        while k < chars.count {
            let c = chars[k]
            if c == "\\" { k += 2; continue }
            if c == "(" { depthP += 1 }
            else if c == ")" { depthP -= 1; if depthP == 0 { closeParen = k; break } }
            k += 1
        }
        guard closeParen >= 0 else { return nil }

        let label = Array(chars[(bracketOpen + 1)..<closeBracket])
        var dest = String(chars[(parenOpen + 1)..<closeParen]).trimmingCharacters(in: .whitespaces)
        if dest.hasPrefix("<"), dest.hasSuffix(">"), dest.count >= 2 {
            dest = String(dest.dropFirst().dropLast())
        } else if let space = dest.firstIndex(of: " ") {
            // `url "title"` → keep only the url part.
            dest = String(dest[..<space])
        }
        return (label, dest, closeParen + 1)
    }

    // Parses a `*`/`_` emphasis run starting at `start`. Returns the styled
    // inner string and the index just past the closing delimiter, or nil if
    // there's no valid match (which leaves the delimiter as literal text).
    private static func parseEmphasis(_ chars: [Character], start: Int)
        -> (attributed: NSAttributedString, end: Int)? {
        let delim = chars[start]
        let openLen = min(runLength(chars, start, delim), 3)

        // `_` only opens at a word boundary, so snake_case and underscores in
        // URLs are left literal. `*` is unrestricted.
        if delim == "_" && !boundaryBefore(chars, start) { return nil }
        let afterOpen = start + openLen
        guard afterOpen < chars.count, !chars[afterOpen].isWhitespace else { return nil }

        var j = afterOpen
        while j < chars.count {
            let c = chars[j]
            if c == "\\" { j += 2; continue }
            // Skip over code spans and links so a delimiter inside them can't
            // close this emphasis.
            if c == "`" {
                let run = runLength(chars, j, "`")
                if let close = findBacktickRun(chars, from: j + run, length: run) {
                    j = close + run; continue
                }
            }
            if c == "[" || (c == "!" && j + 1 < chars.count && chars[j + 1] == "[") {
                let bracket = c == "!" ? j + 1 : j
                if let link = parseLink(chars, bracketOpen: bracket) { j = link.end; continue }
            }
            if c == delim {
                let closeLen = runLength(chars, j, delim)
                let precededBySpace = j == 0 || chars[j - 1].isWhitespace
                let valid = !precededBySpace && (delim != "_" || boundaryAfter(chars, j, closeLen))
                if closeLen >= openLen && valid {
                    let inner = parseInline(Array(chars[afterOpen..<j]))
                    return (applyEmphasis(inner, length: openLen), j + openLen)
                }
                j += closeLen
                continue
            }
            j += 1
        }
        return nil
    }

    private static func applyEmphasis(_ inner: NSAttributedString, length: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: inner)
        guard result.length > 0 else { return result }
        let fm = NSFontManager.shared
        let bold = length >= 2
        let italic = length == 1 || length >= 3
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length),
                                  options: []) { value, range, _ in
            var font = (value as? NSFont) ?? baseFont
            if bold { font = fm.convert(font, toHaveTrait: .boldFontMask) }
            if italic { font = fm.convert(font, toHaveTrait: .italicFontMask) }
            result.addAttribute(.font, value: font, range: range)
        }
        return result
    }

    // Word-boundary tests for `_` emphasis: the char just outside the
    // delimiter run must not be alphanumeric.
    private static func boundaryBefore(_ chars: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let b = chars[i - 1]
        return !(b.isLetter || b.isNumber)
    }

    private static func boundaryAfter(_ chars: [Character], _ j: Int, _ runLen: Int) -> Bool {
        let after = j + runLen
        guard after < chars.count else { return true }
        let a = chars[after]
        return !(a.isLetter || a.isNumber)
    }
}
