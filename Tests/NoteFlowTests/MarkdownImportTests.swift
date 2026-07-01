import Testing
import Foundation
import AppKit
@testable import NoteFlow

// Tests for the Markdown / plain-text import path: the MarkdownParser (the
// inverse of NoteExporter.markdown), the NoteImporter file reader, and the
// NoteStore.addNote primitive that turns parsed content into a note.

// MARK: – Helpers

private func font(_ s: NSAttributedString, at loc: Int) -> NSFont {
    (s.attribute(.font, at: loc, effectiveRange: nil) as? NSFont) ?? EditorTypography.baseFont
}

private func hasTrait(_ s: NSAttributedString, at loc: Int, _ trait: NSFontTraitMask) -> Bool {
    NSFontManager.shared.traits(of: font(s, at: loc)).contains(trait)
}

private func makeTempFile(_ contents: String, ext: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NoteFlowImport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("doc.\(ext)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

// MARK: – Block constructs

@Test func headingIsBoldAndLarger() {
    let s = MarkdownParser.attributedString(from: "# Title")
    #expect(s.string == "Title")
    #expect(hasTrait(s, at: 0, .boldFontMask))
    #expect(font(s, at: 0).pointSize > EditorTypography.baseFontSize)
}

@Test func headingStripsTrailingHashes() {
    let s = MarkdownParser.attributedString(from: "## Section ##")
    #expect(s.string == "Section")
}

@Test func unorderedListBecomesBullet() {
    #expect(MarkdownParser.attributedString(from: "- item").string == "• item")
    #expect(MarkdownParser.attributedString(from: "* item").string == "• item")
    #expect(MarkdownParser.attributedString(from: "+ item").string == "• item")
}

@Test func orderedListKeepsNumber() {
    #expect(MarkdownParser.attributedString(from: "3. third").string == "3. third")
    #expect(MarkdownParser.attributedString(from: "1) first").string == "1. first")
}

@Test func taskListMapsToCheckboxes() {
    #expect(MarkdownParser.attributedString(from: "- [ ] todo").string == "☐ todo")
    #expect(MarkdownParser.attributedString(from: "- [x] done").string == "☑ done")
    #expect(MarkdownParser.attributedString(from: "- [X] done").string == "☑ done")
}

@Test func horizontalRuleIsNotAList() {
    // A lone "---" is a thematic break, not a "- " list item.
    let s = MarkdownParser.attributedString(from: "---")
    #expect(!s.string.hasPrefix("• "))
    #expect(s.string.count >= 3)
}

@Test func blankLinesArePreserved() {
    let s = MarkdownParser.attributedString(from: "a\n\nb")
    #expect(s.string == "a\n\nb")
}

@Test func fencedCodeBlockIsMonospacedAndLiteral() {
    let md = "```swift\nlet x = **not bold**\n```"
    let s = MarkdownParser.attributedString(from: md)
    // Fence lines are dropped; inner markers stay literal (no inline parsing).
    #expect(s.string == "let x = **not bold**")
    #expect(font(s, at: 0).isFixedPitch)
}

// MARK: – Inline constructs

@Test func boldItalicAndBoth() {
    let bold = MarkdownParser.attributedString(from: "**b**")
    #expect(bold.string == "b")
    #expect(hasTrait(bold, at: 0, .boldFontMask))

    let italic = MarkdownParser.attributedString(from: "*i*")
    #expect(italic.string == "i")
    #expect(hasTrait(italic, at: 0, .italicFontMask))

    let both = MarkdownParser.attributedString(from: "***x***")
    #expect(both.string == "x")
    #expect(hasTrait(both, at: 0, .boldFontMask))
    #expect(hasTrait(both, at: 0, .italicFontMask))
}

@Test func underscoreEmphasisAtWordBoundaries() {
    let s = MarkdownParser.attributedString(from: "_em_")
    #expect(s.string == "em")
    #expect(hasTrait(s, at: 0, .italicFontMask))
}

@Test func underscoresInsideWordsStayLiteral() {
    // snake_case (and underscores in URLs) must not turn italic.
    let s = MarkdownParser.attributedString(from: "use snake_case_here now")
    #expect(s.string == "use snake_case_here now")
    var anyItalic = false
    s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { v, _, _ in
        if let f = v as? NSFont, NSFontManager.shared.traits(of: f).contains(.italicFontMask) {
            anyItalic = true
        }
    }
    #expect(!anyItalic)
}

@Test func inlineCodeIsMonospaced() {
    let s = MarkdownParser.attributedString(from: "a `code` b")
    #expect(s.string == "a code b")
    #expect(font(s, at: 2).isFixedPitch)   // 'c' of code
    #expect(!font(s, at: 0).isFixedPitch)  // 'a' is normal
}

@Test func inlineCodeIsNotReparsed() {
    // Emphasis markers inside a code span are literal.
    let s = MarkdownParser.attributedString(from: "`a*b*c`")
    #expect(s.string == "a*b*c")
}

@Test func linkAddsLinkAttribute() {
    let s = MarkdownParser.attributedString(from: "[Anthropic](https://anthropic.com)")
    #expect(s.string == "Anthropic")
    let value = s.attribute(.link, at: 0, effectiveRange: nil)
    let url = (value as? URL) ?? (value as? String).flatMap { URL(string: $0) }
    #expect(url?.absoluteString == "https://anthropic.com")
}

@Test func linkWithoutSchemeGetsHttps() {
    let s = MarkdownParser.attributedString(from: "[x](example.com)")
    let value = s.attribute(.link, at: 0, effectiveRange: nil)
    let url = (value as? URL) ?? (value as? String).flatMap { URL(string: $0) }
    #expect(url?.absoluteString == "https://example.com")
}

@Test func linkLabelEmphasisComposes() {
    let s = MarkdownParser.attributedString(from: "[**bold link**](https://x.com)")
    #expect(s.string == "bold link")
    #expect(hasTrait(s, at: 0, .boldFontMask))
    #expect(s.attribute(.link, at: 0, effectiveRange: nil) != nil)
}

@Test func underlineTagApplies() {
    let s = MarkdownParser.attributedString(from: "<u>under</u>")
    #expect(s.string == "under")
    #expect((s.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int ?? 0) != 0)
}

@Test func strikethroughApplies() {
    let s = MarkdownParser.attributedString(from: "~~gone~~")
    #expect(s.string == "gone")
    #expect((s.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int ?? 0) != 0)
}

@Test func backslashEscapesAreLiteral() {
    let s = MarkdownParser.attributedString(from: #"\*not italic\*"#)
    #expect(s.string == "*not italic*")
    #expect(!hasTrait(s, at: 0, .italicFontMask))
}

@Test func unmatchedDelimiterStaysLiteral() {
    let s = MarkdownParser.attributedString(from: "2 * 3 = 6")
    #expect(s.string == "2 * 3 = 6")
    #expect(!hasTrait(s, at: 0, .italicFontMask))
}

// MARK: – Round-trip with the exporter

@Test func exportThenImportPreservesFormatting() {
    let fm = NSFontManager.shared
    let s = NSMutableAttributedString()
    s.append(NSAttributedString(string: "• ", attributes: [.font: EditorTypography.baseFont]))
    s.append(NSAttributedString(string: "Bold",
                                attributes: [.font: fm.convert(EditorTypography.baseFont, toHaveTrait: .boldFontMask)]))
    s.append(NSAttributedString(string: " then ", attributes: [.font: EditorTypography.baseFont]))
    s.append(NSAttributedString(string: "link",
                                attributes: [.font: EditorTypography.baseFont,
                                             .link: URL(string: "https://x.com")!]))

    let md = NoteExporter.markdown(from: s)
    let back = MarkdownParser.attributedString(from: md)

    #expect(back.string == "• Bold then link")
    let boldLoc = (back.string as NSString).range(of: "Bold").location
    #expect(hasTrait(back, at: boldLoc, .boldFontMask))
    let linkLoc = (back.string as NSString).range(of: "link").location
    #expect(back.attribute(.link, at: linkLoc, effectiveRange: nil) != nil)
}

// MARK: – NoteImporter file reading

@Test func plainTextImportPreservesNewlines() throws {
    let url = try makeTempFile("line one\nline two", ext: "txt")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let s = try NoteImporter.attributedString(forFileAt: url)
    #expect(s.string == "line one\nline two")
}

@Test func markdownFileImportRendersFormatting() throws {
    let url = try makeTempFile("# Title\n\n- one\n- two", ext: "md")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let s = try NoteImporter.attributedString(forFileAt: url)
    #expect(s.string == "Title\n\n• one\n• two")
    #expect(hasTrait(s, at: 0, .boldFontMask))
}

@Test func plainTextImportLinkifiesBareURLs() throws {
    let url = try makeTempFile("see https://anthropic.com today", ext: "txt")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let s = try NoteImporter.attributedString(forFileAt: url)
    let urlLoc = (s.string as NSString).range(of: "https://anthropic.com").location
    #expect(s.attribute(.link, at: urlLoc, effectiveRange: nil) != nil)
}

@Test func importFormatDetectsExtensions() {
    #expect(ImportFormat(fileExtension: "md") == .markdown)
    #expect(ImportFormat(fileExtension: "MD") == .markdown)
    #expect(ImportFormat(fileExtension: "markdown") == .markdown)
    #expect(ImportFormat(fileExtension: "txt") == .plainText)
    #expect(ImportFormat(fileExtension: "rtf") == nil)
}

// MARK: – NoteStore.addNote

@Test @MainActor func addNoteEncodesContentToRtf() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NoteFlowImport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))
    let content = NSAttributedString(string: "imported body",
                                     attributes: [.font: EditorTypography.baseFont])
    let id = store.addNote(title: "My Import", content: content)

    let note = try #require(store.notes.first(where: { $0.id == id }))
    #expect(note.title == "My Import")
    #expect(store.activeTabId == id)
    #expect(store.openTabIds.contains(id))

    let rtf = try #require(note.rtfData)
    let decoded = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
    #expect(decoded.string == "imported body")
}

@Test @MainActor func addNoteDefaultsBlankTitle() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NoteFlowImport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))
    let id = store.addNote(title: "   ", content: NSAttributedString(string: "x"))
    #expect(store.notes.first(where: { $0.id == id })?.title == "Untitled")
}

// MARK: – Formatting: spacing, blockquote, code background

private func paragraphStyle(_ s: NSAttributedString, at loc: Int) -> NSParagraphStyle? {
    s.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
}

@Test func importedBodyHasParagraphSpacingAndLineSpacing() {
    let s = MarkdownParser.attributedString(from: "A normal paragraph of body text.")
    let ps = paragraphStyle(s, at: 0)
    #expect((ps?.paragraphSpacing ?? 0) > 0)
    #expect((ps?.lineSpacing ?? 0) > 0)
}

@Test func importedHeadingHasSpacingBefore() {
    let s = MarkdownParser.attributedString(from: "# Title")
    #expect((paragraphStyle(s, at: 0)?.paragraphSpacingBefore ?? 0) > 0)
}

@Test func blankLineParagraphHasNoSpacing() {
    // "a\n\nb" — the empty paragraph between must carry a zeroed style so it
    // doesn't stack height on top of the body blocks' paragraph spacing.
    let s = MarkdownParser.attributedString(from: "a\n\nb")
    #expect(s.string == "a\n\nb")
    let blank = paragraphStyle(s, at: 2)   // the second "\n" — the empty paragraph
    #expect((blank?.paragraphSpacing ?? -1) == 0)
    #expect((blank?.lineSpacing ?? -1) == 0)
}

@Test func blockquoteGetsMarkerAndItalic() {
    let s = MarkdownParser.attributedString(from: "> quoted")
    #expect(s.string == "▎ quoted")
    // The bar marker is plain; the quoted body is italic.
    #expect(!hasTrait(s, at: 0, .italicFontMask))   // "▎"
    #expect(hasTrait(s, at: 2, .italicFontMask))     // "q" of quoted
}

@Test func blockquoteRoundTripsThroughExporter() {
    let imported = MarkdownParser.attributedString(from: "> hello")
    let md = NoteExporter.markdown(from: imported)
    #expect(md.hasPrefix("> "))              // marker mapped back to Markdown
    #expect(MarkdownParser.attributedString(from: md).string == "▎ hello")
}

@Test func inlineCodeRunHasBackground() {
    let s = MarkdownParser.attributedString(from: "a `code` b")
    #expect(s.string == "a code b")
    #expect(s.attribute(.backgroundColor, at: 2, effectiveRange: nil) != nil)  // "c" of code
    #expect(s.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)  // "a"
}

@Test func fencedCodeRunHasBackground() {
    let s = MarkdownParser.attributedString(from: "```\nlet x = 1\n```")
    #expect(s.string == "let x = 1")
    #expect(s.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
}

// MARK: – Tables (GFM)

private func cellStyle(_ s: NSAttributedString, at loc: Int) -> NSParagraphStyle? {
    s.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
}

@Test @MainActor func markdownTableProducesTextTableCells() {
    let md = "| A | B |\n| --- | --- |\n| 1 | 2 |"
    let s = MarkdownParser.attributedString(from: md)
    #expect(NoteTextView.containsTables(s))   // real NSTextTable, not flat text
    let loc = (s.string as NSString).range(of: "A").location
    #expect(cellStyle(s, at: loc)?.textBlocks.isEmpty == false)
}

@Test func tableHeaderCellsAreBold() {
    let s = MarkdownParser.attributedString(from: "| Head |\n| --- |\n| body |")
    let ns = s.string as NSString
    #expect(hasTrait(s, at: ns.range(of: "Head").location, .boldFontMask))
    #expect(!hasTrait(s, at: ns.range(of: "body").location, .boldFontMask))
}

@Test func tableColumnAlignmentsParsed() {
    let s = MarkdownParser.attributedString(from: "| L | C | R |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |")
    let ns = s.string as NSString
    #expect(cellStyle(s, at: ns.range(of: "L").location)?.alignment == .left)
    #expect(cellStyle(s, at: ns.range(of: "C").location)?.alignment == .center)
    #expect(cellStyle(s, at: ns.range(of: "R").location)?.alignment == .right)
}

@Test func tableCellsSupportInlineFormatting() {
    let s = MarkdownParser.attributedString(from: "| Col |\n| --- |\n| has `code` |")
    let loc = (s.string as NSString).range(of: "code").location
    #expect(s.attribute(.backgroundColor, at: loc, effectiveRange: nil) != nil)
}

@Test func tableEscapedPipeStaysInCell() {
    // A backslash-escaped pipe is literal content, not a column separator.
    let s = MarkdownParser.attributedString(from: "| A | B |\n| --- | --- |\n| x \\| y | z |")
    #expect(s.string.contains("x | y"))
}

@Test @MainActor func pipesWithoutDelimiterRowStayText() {
    let s = MarkdownParser.attributedString(from: "a | b | c")
    #expect(s.string == "a | b | c")
    #expect(!NoteTextView.containsTables(s))
}

@Test @MainActor func loneDashesAreRuleNotTable() {
    // "---" with no pipes is a thematic break, never a one-column table.
    let s = MarkdownParser.attributedString(from: "text\n---\nmore")
    #expect(!NoteTextView.containsTables(s))
}
