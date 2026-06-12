import SwiftUI
import AppKit

struct FormattingToolbarView: View {
    @State private var showLinkPopover = false
    @State private var linkInitialText = ""
    @State private var savedTextView: NSTextView?
    @State private var savedRange = NSRange(location: 0, length: 0)
    @State private var showTablePopover = false
    @State private var showColorPopover = false
    @State private var showFontSizePopover = false
    @State private var fontSizeValue: CGFloat = EditorTypography.baseFontSize

    var body: some View {
        HStack(spacing: 2) {
            // Bold
            FormatButton(label: "B", weight: .bold, tooltip: "Bold (⌘B)") {
                toggleFontTrait(.boldFontMask)
            }
            // Italic
            FormatButton(label: "I", isItalic: true, tooltip: "Italic (⌘I)") {
                toggleFontTrait(.italicFontMask)
            }
            // Underline
            FormatButton(label: "U", underline: true, tooltip: "Underline (⌘U)") {
                toggleUnderline()
            }
            // Code
            FormatButton(label: "<>", mono: true, tooltip: "Inline Code") {
                applyCodeStyle()
            }

            ToolbarDivider()

            // Font size: a popover with −/+ steppers and preset sizes.
            // Capture the editor's text view + selection before the popover
            // steals focus (same pattern as link/table/color).
            Button {
                if let tv = activeTextView() {
                    savedTextView = tv
                    savedRange = tv.selectedRange()
                }
                fontSizeValue = currentFontSize()
                showFontSizePopover = true
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
            .help("Font Size")
            .popover(isPresented: $showFontSizePopover, arrowEdge: .bottom) {
                fontSizePopover
            }

            ToolbarDivider()

            // Bullet list
            FormatIconButton(icon: "list.bullet", tooltip: "Bullet List") {
                insertListPrefix("• ")
            }
            // Ordered list
            FormatIconButton(icon: "list.number", tooltip: "Numbered List") {
                insertListPrefix("1. ")
            }
            // Checklist
            FormatIconButton(icon: "checklist", tooltip: "Checklist") {
                insertListPrefix("☐ ")
            }

            ToolbarDivider()

            // Blockquote
            FormatIconButton(icon: "text.quote", tooltip: "Quote") {
                insertListPrefix("  ")
            }
            // Indent
            FormatIconButton(icon: "increase.indent", tooltip: "Indent") {
                runFormatAction(#selector(NSTextView.insertTab(_:)))
            }

            ToolbarDivider()

            // Link
            Button {
                openLinkDialog()
            } label: {
                Image(systemName: "link")
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
            .help("Add Link")
            .popover(isPresented: $showLinkPopover, arrowEdge: .bottom) {
                LinkPopover(
                    initialText: linkInitialText,
                    onApply: { text, url in
                        applyLink(text: text, url: url)
                        showLinkPopover = false
                    },
                    onCancel: { showLinkPopover = false }
                )
            }

            // Table
            Button {
                // Capture the editor's text view + selection BEFORE the popover
                // steals focus, so the table inserts at the right spot.
                if let tv = activeTextView() {
                    savedTextView = tv
                    savedRange = tv.selectedRange()
                }
                showTablePopover = true
            } label: {
                Image(systemName: "tablecells")
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
            .help("Insert Table")
            .popover(isPresented: $showTablePopover, arrowEdge: .bottom) {
                TablePicker { rows, cols in
                    insertTable(rows: rows, cols: cols)
                    showTablePopover = false
                }
            }

            ToolbarDivider()

            // Text color: collapsed into a single swatch that opens a popover
            // with the palette + reset, so the toolbar stays compact instead
            // of laying all 7 colors inline. Capture the editor's text view +
            // selection before the popover steals focus (same as link/table).
            Button {
                if let tv = activeTextView() {
                    savedTextView = tv
                    savedRange = tv.selectedRange()
                }
                showColorPopover = true
            } label: {
                Image(systemName: "paintpalette")
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
            .help("Text Color")
            .popover(isPresented: $showColorPopover, arrowEdge: .bottom) {
                colorPopover
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    // Palette + "default color" reset shown when the text-color button is
    // tapped. Each choice applies to the selection captured when the popover
    // opened, then dismisses.
    private var colorPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Self.colorPalette, id: \.label) { swatch in
                    ColorSwatchButton(color: swatch.color, tooltip: swatch.label) {
                        applyForegroundColor(swatch.color)
                        showColorPopover = false
                    }
                }
            }
            Divider()
            Button {
                applyForegroundColor(nil)
                showColorPopover = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "drop.halffull")
                        .font(.system(size: 13))
                    Text("Default color")
                        .font(.system(size: 12))
                }
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    // MARK: – Text color

    private struct ColorSwatch {
        let label: String
        let color: NSColor
    }

    private static let colorPalette: [ColorSwatch] = [
        .init(label: "Red",    color: .systemRed),
        .init(label: "Orange", color: .systemOrange),
        .init(label: "Yellow", color: .systemYellow),
        .init(label: "Green",  color: .systemGreen),
        .init(label: "Blue",   color: .systemBlue),
        .init(label: "Purple", color: .systemPurple),
        .init(label: "Pink",   color: .systemPink)
    ]

    /// Apply `color` (or strip the foreground attribute when `nil`) to the
    /// active text view's selection. With no selection, update the typing
    /// attributes so the next typed run picks up the chosen color.
    private func applyForegroundColor(_ color: NSColor?) {
        // Prefer the text view + selection captured when the popover opened —
        // presenting it takes first responder, so the live selection is gone.
        let tv = savedTextView ?? activeTextView()
        guard let tv = tv else { return }
        let range = (savedTextView != nil) ? savedRange : tv.selectedRange()
        savedTextView = nil
        tv.window?.makeFirstResponder(tv)

        if range.length == 0 {
            var typing = tv.typingAttributes
            if let color = color {
                typing[.foregroundColor] = color
            } else {
                typing.removeValue(forKey: .foregroundColor)
            }
            tv.typingAttributes = typing
            return
        }

        guard let storage = tv.textStorage,
              tv.shouldChangeText(in: range, replacementString: nil) else { return }

        storage.beginEditing()
        if let color = color {
            storage.addAttribute(.foregroundColor, value: color, range: range)
        } else {
            storage.removeAttribute(.foregroundColor, range: range)
        }
        storage.endEditing()
        tv.didChangeText()
        // Restore the selection so the user can see what they recolored.
        tv.setSelectedRange(range)
    }

    // MARK: – Font size

    // Preset sizes shown as quick-pick chips in the font-size popover.
    private static let fontSizePresets: [CGFloat] = [10, 12, 14, 18, 24, 36]

    // Popover with a −/+ fine adjuster (current size in the middle) and a
    // row of preset sizes. Mirrors the color popover's layout.
    private var fontSizePopover: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button { adjustFontSize(-1) } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Text("\(Int(fontSizeValue.rounded()))")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 32)

                Button { adjustFontSize(1) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack(spacing: 6) {
                ForEach(Self.fontSizePresets, id: \.self) { size in
                    let isCurrent = Int(size) == Int(fontSizeValue.rounded())
                    Button {
                        chooseFontSize(size)
                    } label: {
                        Text("\(Int(size))")
                            .font(.system(size: 12, weight: isCurrent ? .bold : .regular))
                            .foregroundColor(.primary)
                            .frame(width: 30, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(isCurrent ? 0.18 : 0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
    }

    /// Current point size at the captured selection (or the typing
    /// attributes when nothing is selected), so the popover opens showing
    /// the right number.
    private func currentFontSize() -> CGFloat {
        guard let tv = savedTextView ?? activeTextView() else { return EditorTypography.baseFontSize }
        let range = (savedTextView != nil) ? savedRange : tv.selectedRange()
        if range.length == 0 {
            let font = (tv.typingAttributes[.font] as? NSFont) ?? tv.font ?? EditorTypography.baseFont
            return font.pointSize
        }
        if let storage = tv.textStorage, range.location < storage.length,
           let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
            return font.pointSize
        }
        return EditorTypography.baseFontSize
    }

    /// Resize the captured selection to `size`, preserving each run's family
    /// and traits (bold / italic / mono) via NSFontManager.convert(_:toSize:).
    /// With no selection, updates typing attributes so the next typed run
    /// picks up the size. Doesn't steal first responder, so the popover stays
    /// open across repeated −/+ taps.
    private func applyFontSize(_ size: CGFloat) {
        guard let tv = savedTextView ?? activeTextView() else { return }
        let range = (savedTextView != nil) ? savedRange : tv.selectedRange()
        let fm = NSFontManager.shared

        if range.length == 0 {
            var typing = tv.typingAttributes
            let current = (typing[.font] as? NSFont) ?? tv.font ?? EditorTypography.baseFont
            typing[.font] = fm.convert(current, toSize: size)
            tv.typingAttributes = typing
            return
        }

        guard let storage = tv.textStorage,
              tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            let font = (value as? NSFont) ?? EditorTypography.baseFont
            storage.addAttribute(.font, value: fm.convert(font, toSize: size), range: subRange)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    private func adjustFontSize(_ delta: CGFloat) {
        let newSize = min(200, max(6, fontSizeValue + delta))
        fontSizeValue = newSize
        applyFontSize(newSize)
    }

    private func chooseFontSize(_ size: CGFloat) {
        fontSizeValue = size
        applyFontSize(size)
        savedTextView = nil
        showFontSizePopover = false
    }

    // MARK: – Lookup helpers

    /// Walks the key window's view tree to find the editor's NSTextView.
    /// The SwiftUI button steals first-responder when clicked, so we can't
    /// rely on `keyWindow.firstResponder`.
    private func activeTextView() -> NSTextView? {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView { return tv }
        if let tv = findTextView(in: NSApp.keyWindow?.contentView) { return tv }
        return findTextView(in: NSApp.mainWindow?.contentView)
    }

    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view = view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let tv = findTextView(in: sub) { return tv }
        }
        return nil
    }

    private func runFormatAction(_ selector: Selector) {
        guard let tv = activeTextView() else { return }
        tv.window?.makeFirstResponder(tv)
        if tv.responds(to: selector) {
            _ = tv.perform(selector, with: nil)
        }
    }

    // MARK: – Bold / Italic via direct font trait manipulation

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let tv = activeTextView(), let storage = tv.textStorage else { return }
        tv.window?.makeFirstResponder(tv)
        let range = tv.selectedRange()
        let fm = NSFontManager.shared

        if range.length == 0 {
            // No selection — flip the typing attributes for the next characters typed
            var typing = tv.typingAttributes
            let current = (typing[.font] as? NSFont) ?? tv.font ?? EditorTypography.baseFont
            let has = fm.traits(of: current).contains(trait)
            typing[.font] = has
                ? fm.convert(current, toNotHaveTrait: trait)
                : fm.convert(current, toHaveTrait: trait)
            tv.typingAttributes = typing
            return
        }

        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }

        // Toggle: if every character has the trait, remove it; otherwise add it.
        var allHave = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            let font = (value as? NSFont) ?? EditorTypography.baseFont
            if !fm.traits(of: font).contains(trait) {
                allHave = false
                stop.pointee = true
            }
        }

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            let font = (value as? NSFont) ?? EditorTypography.baseFont
            let newFont = allHave
                ? fm.convert(font, toNotHaveTrait: trait)
                : fm.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: newFont, range: subRange)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    private func toggleUnderline() {
        guard let tv = activeTextView(), let storage = tv.textStorage else { return }
        tv.window?.makeFirstResponder(tv)
        let range = tv.selectedRange()

        if range.length == 0 {
            var typing = tv.typingAttributes
            let current = (typing[.underlineStyle] as? Int) ?? 0
            typing[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.typingAttributes = typing
            return
        }

        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }

        var allUnderlined = true
        storage.enumerateAttribute(.underlineStyle, in: range, options: []) { value, _, stop in
            let style = (value as? Int) ?? 0
            if style == 0 {
                allUnderlined = false
                stop.pointee = true
            }
        }

        storage.beginEditing()
        if allUnderlined {
            storage.removeAttribute(.underlineStyle, range: range)
        } else {
            storage.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: range)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    private func applyCodeStyle() {
        guard let tv = activeTextView(), let storage = tv.textStorage else { return }
        tv.window?.makeFirstResponder(tv)
        let size = tv.font?.pointSize ?? EditorTypography.baseFontSize
        let mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let range = tv.selectedRange()
        guard range.length > 0 else {
            var typing = tv.typingAttributes
            typing[.font] = mono
            tv.typingAttributes = typing
            return
        }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.addAttribute(.font, value: mono, range: range)
        tv.didChangeText()
    }

    private func insertListPrefix(_ prefix: String) {
        guard let tv = activeTextView() else { return }
        tv.window?.makeFirstResponder(tv)
        let range = tv.selectedRange()
        let str = tv.string as NSString
        let lineStart = str.lineRange(for: NSRange(location: range.location, length: 0)).location
        let insertRange = NSRange(location: lineStart, length: 0)
        guard tv.shouldChangeText(in: insertRange, replacementString: prefix) else { return }
        tv.insertText(prefix, replacementRange: insertRange)
    }

    // MARK: – Link

    private func openLinkDialog() {
        guard let tv = activeTextView() else { return }
        let range = tv.selectedRange()
        savedTextView = tv
        savedRange = range
        linkInitialText = range.length > 0
            ? (tv.string as NSString).substring(with: range)
            : ""
        showLinkPopover = true
    }

    private func applyLink(text: String, url: String) {
        guard let tv = savedTextView, let storage = tv.textStorage else { return }
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let normalizedURL = raw.contains("://") ? raw : "https://\(raw)"
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = trimmedText.isEmpty ? raw : trimmedText

        tv.window?.makeFirstResponder(tv)

        let attr = NSAttributedString(string: displayText, attributes: [
            .link: normalizedURL,
            .font: tv.font ?? EditorTypography.baseFont
        ])

        guard tv.shouldChangeText(in: savedRange, replacementString: displayText) else { return }
        storage.replaceCharacters(in: savedRange, with: attr)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: savedRange.location + attr.length, length: 0))
    }

    // MARK: – Table

    private func insertTable(rows: Int, cols: Int) {
        // Prefer the text view that was active when the popover opened.
        let tv = savedTextView ?? activeTextView()
        guard let tv = tv, let storage = tv.textStorage else { return }
        tv.window?.makeFirstResponder(tv)

        let baseFont = tv.font ?? EditorTypography.baseFont
        let palette = ThemeStore.shared.palette
        let borderColor = palette.tableBorderNS
        let headerBg = palette.tableHeaderBgNS

        let table = NSTextTable()
        table.numberOfColumns = cols
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let attr = NSMutableAttributedString()
        let range = (savedTextView != nil) ? savedRange : tv.selectedRange()
        let nsString = tv.string as NSString
        let needsLeadingNewline = range.location > 0
            && range.location <= nsString.length
            && nsString.character(at: range.location - 1) != UInt16(0x0A)
        if needsLeadingNewline {
            // No foreground color — let the text view's textColor drive it,
            // so the table adapts when the theme changes.
            attr.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
        }

        for r in 0..<rows {
            for c in 0..<cols {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: r, rowSpan: 1,
                    startingColumn: c, columnSpan: 1
                )
                block.setBorderColor(borderColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(8, type: .absoluteValueType, for: .padding)
                if r == 0 { block.backgroundColor = headerBg }

                let para = NSMutableParagraphStyle()
                para.textBlocks = [block]

                let text = r == 0 ? "Header \(c + 1)" : " "
                let weight: NSFont.Weight = r == 0 ? .semibold : .regular
                let font = NSFont.systemFont(ofSize: baseFont.pointSize, weight: weight)

                attr.append(NSAttributedString(string: "\(text)\n", attributes: [
                    .paragraphStyle: para,
                    .font: font
                ]))
            }
        }

        attr.append(NSAttributedString(string: "\n", attributes: [
            .font: baseFont,
            .paragraphStyle: NSParagraphStyle.default
        ]))

        // The note is gaining a table: drop every attached layout manager
        // back to contiguous mode first — tables glitch under the editor's
        // default non-contiguous (fast-typing) layout.
        NoteTextView.disableNonContiguousLayout(for: storage)

        guard tv.shouldChangeText(in: range, replacementString: attr.string) else { return }
        storage.replaceCharacters(in: range, with: attr)
        tv.didChangeText()
        savedTextView = nil
    }
}

// MARK: – Link Popover

struct LinkPopover: View {
    @State private var text: String
    @State private var url: String
    let onApply: (String, String) -> Void
    let onCancel: () -> Void

    init(initialText: String,
         initialURL: String = "",
         onApply: @escaping (String, String) -> Void,
         onCancel: @escaping () -> Void) {
        _text = State(initialValue: initialText)
        _url = State(initialValue: initialURL)
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TEXT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                TextField("Link text", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("URL")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                TextField("https://example.com", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(text, url) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 320)
    }
}

// MARK: – Table Picker

struct TablePicker: View {
    static let maxCols = 5
    static let maxRows = 10
    static let cellSize: CGFloat = 24
    static let cellSpacing: CGFloat = 4

    @State private var hoverCol = 1
    @State private var hoverRow = 1

    let onSelect: (_ rows: Int, _ cols: Int) -> Void

    private var gridWidth: CGFloat {
        CGFloat(Self.maxCols) * Self.cellSize + CGFloat(Self.maxCols - 1) * Self.cellSpacing
    }
    private var gridHeight: CGFloat {
        CGFloat(Self.maxRows) * Self.cellSize + CGFloat(Self.maxRows - 1) * Self.cellSpacing
    }

    var body: some View {
        VStack(spacing: 10) {
            gridBody
                .frame(width: gridWidth, height: gridHeight)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let step = Self.cellSize + Self.cellSpacing
                        let c = Int(loc.x / step) + 1
                        let r = Int(loc.y / step) + 1
                        hoverCol = min(Self.maxCols, max(1, c))
                        hoverRow = min(Self.maxRows, max(1, r))
                    case .ended:
                        break
                    }
                }
                .onTapGesture {
                    onSelect(hoverRow, hoverCol)
                }

            Text("\(hoverCol) × \(hoverRow)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(18)
    }

    private var gridBody: some View {
        VStack(spacing: Self.cellSpacing) {
            ForEach(0..<Self.maxRows, id: \.self) { r in
                HStack(spacing: Self.cellSpacing) {
                    ForEach(0..<Self.maxCols, id: \.self) { c in
                        let on = r < hoverRow && c < hoverCol
                        RoundedRectangle(cornerRadius: 4)
                            .fill(on ? Color.accentColor.opacity(0.22) : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(
                                        on ? Color.accentColor : Color.primary.opacity(0.32),
                                        lineWidth: 1
                                    )
                            )
                            .frame(width: Self.cellSize, height: Self.cellSize)
                    }
                }
            }
        }
    }
}

// MARK: – Sub-components

struct FormatButton: View {
    let label: String
    var weight: Font.Weight = .regular
    var isItalic: Bool = false
    var underline = false
    var mono = false
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(mono
                      ? .system(size: 13, design: .monospaced)
                      : .system(size: 14, weight: weight)
                     )
                .italic(isItalic)
                .underline(underline)
                .foregroundColor(.primary)
                .frame(width: 32, height: 28)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

struct FormatIconButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .frame(width: 32, height: 28)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }
}

// Small circular color swatch — used by the text-color picker in the
// formatting toolbar. A subtle border keeps light-colored swatches
// (yellow, pink) visible against the toolbar's translucent background.
struct ColorSwatchButton: View {
    let color: NSColor
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5)
                )
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
