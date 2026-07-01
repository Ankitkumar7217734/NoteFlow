import AppKit
import UniformTypeIdentifiers

// The file formats a note can be exported to. Each case knows its menu
// label, file extension and the UTType to constrain the save panel with.
enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case word
    case markdown
    case plainText

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf:       return "PDF"
        case .word:      return "Word (.docx)"
        case .markdown:  return "Markdown"
        case .plainText: return "Plain Text"
        }
    }

    var systemImage: String {
        switch self {
        case .pdf:       return "doc.richtext"
        case .word:      return "doc.text"
        case .markdown:  return "chevron.left.forwardslash.chevron.right"
        case .plainText: return "doc.plaintext"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf:       return "pdf"
        case .word:      return "docx"
        case .markdown:  return "md"
        case .plainText: return "txt"
        }
    }

    var contentType: UTType {
        switch self {
        case .pdf:       return .pdf
        case .word:      return UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .markdown:  return UTType(filenameExtension: "md") ?? .plainText
        case .plainText: return .plainText
        }
    }
}

// Converts a note's rich-text content into PDF / Word / Markdown / plain text
// and drives an NSSavePanel so the user picks where the file lands. The aim is
// fidelity: whatever bold / italic / underline / inline-code / color / link
// formatting the user applied in the editor survives into the exported file.
enum NoteExporter {

    // MARK: – Entry point

    /// Show a save panel for `note` in `format`, then write the generated
    /// document. `content` is the live attributed string from the editor so
    /// the export reflects exactly what's on screen (including edits that
    /// haven't been re-encoded to RTF on disk yet).
    static func export(note: Note, content: NSAttributedString, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFilename(for: note, format: format)
        panel.title = "Export Note"
        panel.prompt = "Export"

        // The floating panel is a non-activating panel; bring the app forward
        // so the save sheet is interactive and front-most.
        NSApp.activate(ignoringOtherApps: true)

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try data(for: format, content: content)
                try data.write(to: url, options: .atomic)
            } catch {
                presentError(error, format: format)
            }
        }
    }

    private static func suggestedFilename(for note: Note, format: ExportFormat) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled" : trimmed
        // Strip characters that are illegal in filenames.
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
        return "\(cleaned).\(format.fileExtension)"
    }

    private static func presentError(_ error: Error, format: ExportFormat) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t export note"
        alert.informativeText = "The \(format.label) export failed: \(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: – Format generation

    static func data(for format: ExportFormat, content: NSAttributedString) throws -> Data {
        switch format {
        case .plainText:
            return Data(content.string.utf8)

        case .markdown:
            return Data(markdown(from: content).utf8)

        case .word:
            let body = normalizingFontSizes(content)
            let range = NSRange(location: 0, length: body.length)
            return try body.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )

        case .pdf:
            return pdfData(from: normalizingFontSizes(content))
        }
    }

    // MARK: – Font-size normalization (PDF / Word)

    // The size default body text is exported at.
    static let exportDefaultFontSize: CGFloat = 10

    // Sizes treated as "default body text" — the current editor default plus
    // the legacy 15pt one old notes were written at. Runs at any of these are
    // re-based to the export default; anything else is a size the user chose
    // deliberately and is preserved.
    private static var defaultBodySizes: [CGFloat] { [15, EditorTypography.baseFontSize] }

    // Re-bases the document so default body text exports at 10pt regardless
    // of the editor default in effect when the note was written. Runs at a
    // default body size are mapped to 10pt (family + bold/italic/mono
    // preserved); runs with no font get the 10pt system font. Sizes the user
    // explicitly picked from the Font Size control (12, 18, 24, …) are left
    // untouched.
    static func normalizingFontSizes(_ content: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        guard result.length > 0 else { return result }
        let full = NSRange(location: 0, length: result.length)
        let fm = NSFontManager.shared
        result.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            if let font = value as? NSFont {
                if defaultBodySizes.contains(where: { abs(font.pointSize - $0) < 0.5 }) {
                    result.addAttribute(.font, value: fm.convert(font, toSize: exportDefaultFontSize), range: range)
                }
            } else {
                result.addAttribute(.font, value: NSFont.systemFont(ofSize: exportDefaultFontSize), range: range)
            }
        }
        return result
    }

    // MARK: – PDF

    // Lays the attributed string out across US-Letter pages with an
    // NSLayoutManager and draws each page into a PDF context. Pagination is
    // automatic: we keep adding text containers until every glyph is placed.
    static func pdfData(from content: NSAttributedString) -> Data {
        let pageWidth: CGFloat = 612   // 8.5" * 72
        let pageHeight: CGFloat = 792  // 11"  * 72
        let margin: CGFloat = 56
        let textSize = CGSize(width: pageWidth - margin * 2,
                              height: pageHeight - margin * 2)

        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        // The editor bakes NSColor.textColor (a *dynamic* color) into every
        // run. In dark theme it resolves to near-white, which would draw
        // invisibly on the white PDF page. Render the whole document under a
        // forced light (aqua) appearance so NSColor.textColor resolves to
        // black and the user's picked colors (red, blue, …) resolve to their
        // normal light-mode values — i.e. a printed document on white paper.
        let aqua = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        aqua.performAsCurrentDrawingAppearance {
            // Drop any literal foreground color that matches a theme default
            // (e.g. RTF saved from dark theme with a baked-in 0.91 white) so
            // it falls back to black; user-picked colors are preserved.
            let body = NSMutableAttributedString(attributedString: content)
            NoteStore.stripThemeDefaultForegroundColors(in: body)

            let textStorage = NSTextStorage(attributedString: body)
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)

            // Build one container per page until all glyphs are laid out.
            var containers: [NSTextContainer] = []
            var lastRange = NSRange(location: 0, length: 0)
            repeat {
                let container = NSTextContainer(size: textSize)
                container.lineFragmentPadding = 0
                layoutManager.addTextContainer(container)
                lastRange = layoutManager.glyphRange(for: container)
                containers.append(container)
                // Safety valve so a pathological layout can never spin forever.
                if containers.count > 2000 { break }
            } while NSMaxRange(lastRange) < layoutManager.numberOfGlyphs

            for container in containers {
                ctx.beginPDFPage(nil)

                // flipped: true so AppKit text drawing renders upright once we
                // flip the CTM below into a top-left origin. The flag and the
                // manual flip must agree or glyphs come out upside-down.
                let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = nsContext

                // Paint a white page (PDF pages are otherwise transparent),
                // then flip into a top-left origin so the layout manager
                // (which draws y-down) lands text where expected.
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(mediaBox)
                ctx.translateBy(x: 0, y: pageHeight)
                ctx.scaleBy(x: 1, y: -1)

                let glyphRange = layoutManager.glyphRange(for: container)
                let origin = CGPoint(x: margin, y: margin)
                layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)

                NSGraphicsContext.restoreGraphicsState()
                ctx.endPDFPage()
            }
        }

        ctx.closePDF()
        return pdfData as Data
    }

    // MARK: – Markdown

    // Walks the attributed string line by line, mapping the editor's list
    // prefixes to Markdown markers and each styled run to Markdown emphasis.
    static func markdown(from content: NSAttributedString) -> String {
        let ns = content.string as NSString
        guard ns.length > 0 else { return "" }

        var lines: [String] = []
        var index = 0
        while index < ns.length {
            let raw = ns.lineRange(for: NSRange(location: index, length: 0))
            // Trim the trailing line terminator(s) so we format the line's
            // text without the newline.
            var contentLen = raw.length
            while contentLen > 0 {
                let c = ns.character(at: raw.location + contentLen - 1)
                if c == 0x0A || c == 0x0D { contentLen -= 1 } else { break }
            }
            let lineRange = NSRange(location: raw.location, length: contentLen)
            lines.append(markdownLine(content, lineRange: lineRange, fullString: ns))
            index = NSMaxRange(raw)
        }
        return lines.joined(separator: "\n")
    }

    private static func markdownLine(_ content: NSAttributedString,
                                     lineRange: NSRange,
                                     fullString ns: NSString) -> String {
        if lineRange.length == 0 { return "" }
        let lineText = ns.substring(with: lineRange)

        // Map the editor's list / checklist prefixes to Markdown. The number
        // of UTF-16 units consumed becomes the offset where inline text starts.
        var marker = ""
        var prefixLen = 0
        if lineText.hasPrefix("▎ ") {
            // Imported blockquote marker (see MarkdownParser.renderBlockquote)
            // maps back to Markdown's "> ".
            marker = "> "; prefixLen = 2
        } else if lineText.hasPrefix("• ") {
            marker = "- "; prefixLen = 2
        } else if lineText.hasPrefix("☐ ") {
            marker = "- [ ] "; prefixLen = 2
        } else if lineText.hasPrefix("☑ ") || lineText.hasPrefix("☑️ ") {
            marker = "- [x] "; prefixLen = lineText.hasPrefix("☑️ ") ? 3 : 2
        } else if let n = orderedListPrefixLength(lineText) {
            // Keep the user's numbering verbatim ("1. ", "2. ", …).
            marker = String(lineText.prefix(n)); prefixLen = n
        }

        let innerRange = NSRange(location: lineRange.location + prefixLen,
                                 length: lineRange.length - prefixLen)
        let inline = inlineMarkdown(content, range: innerRange, fullString: ns)
        return marker + inline
    }

    // Returns the UTF-16 length of a leading "<digits>. " ordered-list prefix,
    // or nil if the line doesn't start with one.
    private static func orderedListPrefixLength(_ line: String) -> Int? {
        var digits = 0
        let chars = Array(line)
        while digits < chars.count, chars[digits].isNumber { digits += 1 }
        guard digits > 0, digits + 1 < chars.count,
              chars[digits] == ".", chars[digits + 1] == " " else { return nil }
        return digits + 2
    }

    private static func inlineMarkdown(_ content: NSAttributedString,
                                       range: NSRange,
                                       fullString ns: NSString) -> String {
        guard range.length > 0 else { return "" }
        var out = ""
        content.enumerateAttributes(in: range, options: []) { attrs, runRange, _ in
            let text = ns.substring(with: runRange)
            let font = attrs[.font] as? NSFont
            let isUnderline = (attrs[.underlineStyle] as? Int ?? 0) != 0
            let link = linkString(attrs[.link])
            out += styleRun(text, font: font, underline: isUnderline, link: link)
        }
        return out
    }

    private static func linkString(_ value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        if let s = value as? String, !s.isEmpty { return s }
        return nil
    }

    // Wraps a single run's text in the Markdown markers implied by its font
    // traits / underline / link. Whitespace is kept outside the markers so
    // emphasis renders (Markdown ignores "** bold **").
    private static func styleRun(_ text: String,
                                 font: NSFont?,
                                 underline: Bool,
                                 link: String?) -> String {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return text }

        let leading = String(text.prefix(while: { $0 == " " }))
        let trailing = String(text.reversed().prefix(while: { $0 == " " }).reversed())
        var core = String(text.dropFirst(leading.count).dropLast(trailing.count))

        if let link = link {
            core = "[\(core)](\(link))"
        } else if font?.isFixedPitch == true {
            // Inline code is literal in Markdown — no nested emphasis.
            core = "`\(core)`"
        } else {
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let bold = traits.contains(.boldFontMask)
            let italic = traits.contains(.italicFontMask)
            if bold && italic { core = "***\(core)***" }
            else if bold { core = "**\(core)**" }
            else if italic { core = "*\(core)*" }
            if underline { core = "<u>\(core)</u>" }
        }
        return leading + core + trailing
    }
}
