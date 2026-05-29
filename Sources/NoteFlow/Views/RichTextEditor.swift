import SwiftUI
import AppKit

// Editor's canonical font — used everywhere we need to normalize incoming text.
enum EditorTypography {
    static let baseFontSize: CGFloat = 15
    static var baseFont: NSFont { .systemFont(ofSize: baseFontSize) }
}

// Draws selection (and any .backgroundColor attribute run) with rounded
// corners instead of the default sharp rectangle. The system rect-fill
// looks blocky against the dark editor background; the radius softens
// it the way modern editors render selection.
final class NoteLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>,
                                          count rectCount: Int,
                                          forCharacterRange charRange: NSRange,
                                          color: NSColor) {
        color.set()
        for i in 0..<rectCount {
            // Inset 0.5pt vertically so consecutive lines of a multi-line
            // selection don't visibly seam together at the radius corners.
            let rect = rectArray[i].insetBy(dx: 0, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.fill()
        }
    }
}

// NSTextView subclass that sanitizes pasted content: strips background colors,
// forces dark foreground, and rewrites the font family to the editor's base
// font while preserving bold/italic/monospaced traits.
final class NoteTextView: NSTextView {
    // The link the user pressed mouse-down on, if any. Held until mouseUp so
    // we can distinguish a click (open) from a drag (select).
    private var pendingLinkInfo: (url: URL, range: NSRange)?
    // Keeps the rename popover alive while it's showing.
    private var renamePopover: NSPopover?
    // The link captured at the moment the context menu was built, so the
    // "Rename Link…" action knows which range to edit.
    private var contextMenuLinkInfo: (url: URL, range: NSRange)?

    // MARK: – Keyboard shortcuts (⌘B / ⌘I / ⌘U)

    // SwiftUI doesn't install a Format menu, so ⌘B / ⌘I / ⌘U never reach the
    // text view through the normal menu route. Intercept them here. Accept
    // either ⌘X or ⌘⇧X — different keyboards / muscle memory use both.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCmd = (mods == .command) || (mods == [.command, .shift])
        if isCmd, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "b": toggleTrait(.boldFontMask);    return true
            case "i": toggleTrait(.italicFontMask);  return true
            case "u": toggleUnderlineAttribute();    return true
            default:  break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        let fm = NSFontManager.shared

        // No selection: flip the typing attributes so the next character
        // the user types comes out with the toggled trait.
        if range.length == 0 {
            var typing = typingAttributes
            let current = (typing[.font] as? NSFont) ?? font ?? EditorTypography.baseFont
            let has = fm.traits(of: current).contains(trait)
            typing[.font] = has
                ? fm.convert(current, toNotHaveTrait: trait)
                : fm.convert(current, toHaveTrait: trait)
            typingAttributes = typing
            return
        }

        guard shouldChangeText(in: range, replacementString: nil) else { return }

        // If every glyph in the selection already has the trait, the toggle
        // removes it; otherwise the toggle adds it to every glyph. Same rule
        // Pages / Word use.
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
        didChangeText()
    }

    private func toggleUnderlineAttribute() {
        guard let storage = textStorage else { return }
        let range = selectedRange()

        if range.length == 0 {
            var typing = typingAttributes
            let current = (typing[.underlineStyle] as? Int) ?? 0
            typing[.underlineStyle] = current == 0
                ? NSUnderlineStyle.single.rawValue
                : 0
            typingAttributes = typing
            return
        }

        guard shouldChangeText(in: range, replacementString: nil) else { return }

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
        didChangeText()
    }

    // MARK: – Link clicks (⌘-click or double-click opens; plain click edits)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pendingLinkInfo = linkInfo(atViewPoint: point)

        // ⌘-click or double-click on a link opens it (handled in mouseUp).
        // Swallow the default mouseDown for those gestures so they don't also
        // place a caret or select the link's word. A plain click falls
        // through to NSTextView and just positions the insertion point.
        let opensLink = event.modifierFlags.contains(.command) || event.clickCount == 2
        if pendingLinkInfo != nil && opensLink {
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let info = pendingLinkInfo
        pendingLinkInfo = nil

        // ⌘-click or double-click on a link → open it in the browser right
        // away. A plain single click falls through to NSTextView's default
        // handling, which just places the caret; links are renamed via the
        // right-click context menu, so there's no deferred popover and no
        // perceptible delay on an ordinary click.
        let opensLink = event.modifierFlags.contains(.command) || event.clickCount == 2
        if let info = info, opensLink {
            NSWorkspace.shared.open(info.url)
            return
        }

        super.mouseUp(with: event)
    }

    private func linkInfo(atViewPoint viewPoint: NSPoint) -> (url: URL, range: NSRange)? {
        guard let storage = textStorage,
              let layoutManager = layoutManager,
              let textContainer = textContainer,
              storage.length > 0 else { return nil }

        let containerPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )

        var found: (URL, NSRange)?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard rect.contains(containerPoint) else { return }

            let url: URL?
            if let u = value as? URL { url = u }
            else if let s = value as? String { url = URL(string: s) }
            else { url = nil }
            if let u = url {
                found = (u, range)
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: – Right-click context menu

    // Inject a "Rename Link…" item into NSTextView's default contextual
    // menu when the click lands on a link. Right-click is the primary way
    // to rename a link now (a plain single click just places the caret).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        let point = convert(event.locationInWindow, from: nil)
        let info = linkInfo(atViewPoint: point)
        contextMenuLinkInfo = info

        guard info != nil, let menu = menu else { return menu }

        let renameItem = NSMenuItem(
            title: "Rename Link…",
            action: #selector(renameLinkFromMenu(_:)),
            keyEquivalent: ""
        )
        renameItem.target = self

        // Place it just above the system's "Edit Link…" so the two
        // link-editing affordances sit together.
        if let editIdx = menu.items.firstIndex(where: { $0.title.lowercased().contains("edit link") }) {
            menu.insertItem(renameItem, at: editIdx)
        } else if let copyIdx = menu.items.firstIndex(where: { $0.title.lowercased().contains("copy link") }) {
            menu.insertItem(renameItem, at: copyIdx + 1)
        } else {
            menu.insertItem(renameItem, at: 0)
        }
        return menu
    }

    @objc private func renameLinkFromMenu(_ sender: Any?) {
        guard let info = contextMenuLinkInfo else { return }
        contextMenuLinkInfo = nil
        showRenamePopover(currentURL: info.url, range: info.range)
    }

    // MARK: – Rename popover

    @MainActor
    private func showRenamePopover(currentURL: URL, range: NSRange) {
        guard let storage = textStorage,
              let layoutManager = layoutManager,
              let textContainer = textContainer else { return }

        let currentText = (storage.string as NSString).substring(with: range)

        let popover = NSPopover()
        popover.behavior = .transient
        renamePopover = popover

        let view = LinkPopover(
            initialText: currentText,
            initialURL: currentURL.absoluteString,
            onApply: { [weak self, weak popover] newText, newURL in
                self?.applyLinkEdit(range: range, text: newText, urlString: newURL)
                popover?.close()
            },
            onCancel: { [weak popover] in
                popover?.close()
            }
        )
        popover.contentViewController = NSHostingController(rootView: view)

        // Anchor the popover to the link's bounding box (in view coords).
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let textRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let viewRect = textRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)

        popover.show(relativeTo: viewRect, of: self, preferredEdge: .maxY)
    }

    @MainActor
    private func applyLinkEdit(range: NSRange, text: String, urlString: String) {
        guard let storage = textStorage else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !trimmedURL.isEmpty else { return }

        let normalized = trimmedURL.contains("://") ? trimmedURL : "https://\(trimmedURL)"
        guard let url = URL(string: normalized) else { return }

        // Copy attributes from the start of the range and override the link.
        var attrs = storage.attributes(at: range.location, effectiveRange: nil)
        attrs[.link] = url
        let replacement = NSAttributedString(string: trimmedText, attributes: attrs)

        guard shouldChangeText(in: range, replacementString: trimmedText) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
    }

    // MARK: – Layout sync after every edit

    // NSTextView lays out lazily — after a storage edit, the affected lines
    // aren't re-laid-out until something forces it (a scroll, a redraw, etc).
    // Symptoms we've actually hit:
    //   • Paste in the middle of a long note → text below the insertion
    //     point is clipped until the user scrolls.
    //   • Backspace → the glyph is removed from storage but the caret keeps
    //     the old X position, leaving a "ghost" gap on the line.
    // Forcing layout on every text change keeps what's drawn in sync with
    // what's in the storage. ensureLayout is incremental, so for unchanged
    // regions it costs nothing.
    override func didChangeText() {
        super.didChangeText()
        if let lm = layoutManager, let tc = textContainer {
            lm.ensureLayout(for: tc)
        }
        needsDisplay = true
    }

    // Auto-continue bullet / checklist / numbered list when Enter is pressed.
    // Pressing Enter on an empty list item strips the prefix (ends the list).
    override func insertNewline(_ sender: Any?) {
        let nsString = string as NSString
        let cursor = selectedRange().location
        guard cursor <= nsString.length else {
            super.insertNewline(sender)
            return
        }

        let lineRange = nsString.lineRange(for: NSRange(location: cursor, length: 0))
        var line = nsString.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }

        // Static prefixes (bullet, checklist)
        for prefix in ["• ", "☐ ", "☑ "] {
            if line == prefix {
                // Empty list item — strip the prefix to end the list
                let stripRange = NSRange(location: lineRange.location, length: (prefix as NSString).length)
                if shouldChangeText(in: stripRange, replacementString: "") {
                    textStorage?.replaceCharacters(in: stripRange, with: "")
                    didChangeText()
                }
                super.insertNewline(sender)
                return
            }
            if line.hasPrefix(prefix) {
                super.insertNewline(sender)
                let newPrefix = prefix == "☑ " ? "☐ " : prefix
                insertText(newPrefix, replacementRange: selectedRange())
                return
            }
        }

        // Numbered list: ^\d+\.
        if let match = line.range(of: #"^(\d+)\. "#, options: .regularExpression) {
            let prefix = String(line[match])
            let digits = prefix.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            guard let num = Int(digits) else {
                super.insertNewline(sender)
                return
            }
            if line == prefix {
                // Empty numbered item — strip the prefix
                let stripRange = NSRange(location: lineRange.location, length: (prefix as NSString).length)
                if shouldChangeText(in: stripRange, replacementString: "") {
                    textStorage?.replaceCharacters(in: stripRange, with: "")
                    didChangeText()
                }
                super.insertNewline(sender)
                return
            }
            super.insertNewline(sender)
            insertText("\(num + 1). ", replacementRange: selectedRange())
            return
        }

        super.insertNewline(sender)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        var source: NSAttributedString?

        if let data = pb.data(forType: .rtf),
           let attr = NSAttributedString(rtf: data, documentAttributes: nil) {
            source = attr
        } else if let data = pb.data(forType: .html),
                  let attr = NSAttributedString(html: data, documentAttributes: nil) {
            source = attr
        } else if let str = pb.string(forType: .string) {
            source = NSAttributedString(string: str)
        }

        guard let src = source else {
            super.paste(sender)
            return
        }

        let cleaned = Self.sanitize(src)
        let linked = Self.autoLink(cleaned)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: linked.string) else { return }
        textStorage?.replaceCharacters(in: range, with: linked)
        didChangeText()

        // NSTextView's built-in paste: moves the caret past the inserted text
        // and scrolls it into view. Because we edited the storage directly,
        // we have to do both ourselves — otherwise the viewport stays at its
        // old top-of-text offset, the inserted text shifts the original
        // content down, and the user has to scroll up to find what they just
        // pasted. ensureLayout also forces the text view's frame to grow so
        // the bottom of the document isn't clipped until the next scroll.
        let caret = NSRange(location: range.location + linked.length, length: 0)
        setSelectedRange(caret)
        if let lm = layoutManager, let tc = textContainer {
            _ = lm.glyphRange(for: tc)
        }
        scrollRangeToVisible(caret)

        // Kick off background title fetches for every URL we just linkified.
        // When (if) a title comes back, we replace the link's visible text
        // while keeping the .link attribute pointed at the original URL.
        var seen = Set<URL>()
        let urls: [URL] = {
            var out: [URL] = []
            linked.enumerateAttribute(.link, in: NSRange(location: 0, length: linked.length), options: []) { value, _, _ in
                let url: URL?
                if let u = value as? URL { url = u }
                else if let s = value as? String { url = URL(string: s) }
                else { url = nil }
                if let u = url, seen.insert(u).inserted { out.append(u) }
            }
            return out
        }()
        for url in urls {
            Task { [weak self] in
                guard let title = await LinkTitleFetcher.title(for: url) else { return }
                await self?.replaceLinkText(url: url, with: title)
            }
        }
    }

    // Walks the shared text storage and, for any run whose .link attribute
    // matches `url` and whose visible text still looks like a URL (no
    // whitespace), swaps the visible text for the fetched title. Leaves
    // ranges the user has already manually edited untouched.
    @MainActor
    private func replaceLinkText(url: URL, with title: String) {
        guard let storage = textStorage else { return }
        let label = Self.shortLabel(from: title)
        let fullRange = NSRange(location: 0, length: storage.length)

        var replacements: [(NSRange, NSAttributedString)] = []
        storage.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            let matches: Bool
            if let u = value as? URL { matches = (u == url) }
            else if let s = value as? String { matches = (URL(string: s) == url) }
            else { matches = false }
            guard matches else { return }

            let currentText = (storage.string as NSString).substring(with: range)
            // Already upgraded — leave it.
            guard currentText != label else { return }
            // User has edited the visible text into something non-URL-like — leave it.
            guard currentText.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return }

            let attrs = storage.attributes(at: range.location, effectiveRange: nil)
            replacements.append((range, NSAttributedString(string: label, attributes: attrs)))
        }
        guard !replacements.isEmpty else { return }

        storage.beginEditing()
        // Replace from the end so earlier ranges don't shift.
        for (range, replacement) in replacements.reversed() {
            storage.replaceCharacters(in: range, with: replacement)
        }
        storage.endEditing()
        // Trigger the editor's textDidChange delegate so the change persists
        // to notes.json via NoteStore.updateNote.
        didChangeText()
    }

    // Trims a fetched page title down to its first ~3 meaningful tokens so
    // the inline link label stays short ("JAAN SE GUZARTE" rather than the
    // full YouTube title). Splits on whitespace and common title separators
    // (|, ·, em/en dash).
    static func shortLabel(from title: String, wordLimit: Int = 3) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators: Set<Character> = ["|", "·", "—", "–"]
        let words = cleaned.split { $0.isWhitespace || separators.contains($0) }
            .filter { !$0.isEmpty }
        let picked = words.prefix(wordLimit).joined(separator: " ")
        return picked.isEmpty ? cleaned : picked
    }

    // Detect URLs in the pasted text with NSDataDetector and apply a
    // .link attribute to each run that doesn't already have one. Handles
    // bare domains ("github.com/foo") as well as fully-qualified URLs.
    static func autoLink(_ source: NSAttributedString) -> NSAttributedString {
        let string = source.string
        guard !string.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return source }

        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let matches = detector.matches(in: string, options: [], range: fullRange)
        guard !matches.isEmpty else { return source }

        let result = NSMutableAttributedString(attributedString: source)
        for match in matches {
            guard let url = match.url else { continue }
            // Skip if an explicit link is already in this range.
            var alreadyLinked = false
            result.enumerateAttribute(.link, in: match.range, options: []) { value, _, stop in
                if value != nil { alreadyLinked = true; stop.pointee = true }
            }
            if !alreadyLinked {
                result.addAttribute(.link, value: url, range: match.range)
            }
        }
        return result
    }

    static func sanitize(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let full = NSRange(location: 0, length: result.length)
        let baseFont = EditorTypography.baseFont
        let fm = NSFontManager.shared

        // Strip attributes that bring foreign styling (highlights, shadows, etc).
        for key in [NSAttributedString.Key.backgroundColor,
                    .shadow, .expansion, .obliqueness,
                    .strokeColor, .strokeWidth] {
            result.removeAttribute(key, range: full)
        }

        // Strip any pasted foreground color so the text view's theme-driven
        // textColor controls the rendered color. Don't bake a static color
        // in — otherwise pasted text stays e.g. black after a dark-mode flip.
        result.removeAttribute(.foregroundColor, range: full)

        // Rewrite fonts: preserve bold/italic/mono, normalize family + size.
        result.enumerateAttribute(.font, in: full) { value, range, _ in
            let oldFont = value as? NSFont
            let traits = oldFont.map { fm.traits(of: $0) } ?? []
            let isBold = traits.contains(.boldFontMask)
            let isItalic = traits.contains(.italicFontMask)
            let isMono = oldFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false

            var newFont: NSFont
            if isMono {
                newFont = NSFont.monospacedSystemFont(
                    ofSize: EditorTypography.baseFontSize,
                    weight: isBold ? .bold : .regular
                )
                if isItalic { newFont = fm.convert(newFont, toHaveTrait: .italicFontMask) }
            } else {
                newFont = baseFont
                if isBold { newFont = fm.convert(newFont, toHaveTrait: .boldFontMask) }
                if isItalic { newFont = fm.convert(newFont, toHaveTrait: .italicFontMask) }
            }
            result.addAttribute(.font, value: newFont, range: range)
        }

        return result
    }
}

// NSTextView wrapper that supports rich text editing. Pulls its NSTextStorage
// from NoteStore so the main window and the floating panel share the same
// underlying storage when they edit the same note — typing in either editor
// instantly reflects in the other.
struct RichTextEditor: NSViewRepresentable {
    let noteId: UUID
    var onTextChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        // Build the text system bottom-up so we can plug in the shared storage.
        let storage = NoteStore.shared.sharedTextStorage(for: noteId)
        let layoutManager = NoteLayoutManager()
        storage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        ))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NoteTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.textContainerInset = NSSize(width: 28, height: 28)
        // IMPORTANT: don't set textView.font here — it would wipe per-run
        // fonts (bold/italic/mono) on the existing storage.
        //
        // Use NSColor.textColor (the system semantic) for both the text
        // view's default color and for typingAttributes. The dynamic
        // color resolves to black/white based on the text view's
        // appearance, so on theme switch — when only appearance changes
        // and we don't touch textColor again — default text re-renders
        // in the new theme color without overwriting user-applied
        // colors anywhere in the storage.
        textView.textColor = NSColor.textColor
        textView.typingAttributes = [
            .font: EditorTypography.baseFont,
            .foregroundColor: NSColor.textColor
        ]
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView

        // Apply current theme to the new text view + scroll view, then
        // subscribe to theme changes so a Settings toggle live-updates both
        // the main window's editor and the floating panel's editor.
        Self.applyPalette(ThemeStore.shared.palette, to: textView, scrollView: scrollView)
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.startObservingTheme()

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // Land the cursor in the note body when this editor is created (new
        // note, note switch, launch). Otherwise the window's initial first
        // responder is the first focusable control — now the tag field that
        // sits above the editor — so adding a note dropped the cursor into
        // "Add tag…". Deferred so the text view is in its window first; only
        // claims focus in the key window so it can't steal from the floating
        // panel when a note switch rebuilds the (background) main editor.
        DispatchQueue.main.async { [weak textView] in
            guard let textView = textView,
                  let window = textView.window, window.isKeyWindow else { return }
            window.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // No-op. Content sync is automatic because every editor for this
        // note is bound to the same NSTextStorage in NoteStore.
    }

    // Push the palette's editor colors onto an NSTextView + its scroll view.
    // Used at construction and on every themeChanged notification.
    //
    // IMPORTANT: this method must not write to textView.textColor — that
    // setter replaces the .foregroundColor of every character in the
    // storage and wipes out user-picked colors from the formatting
    // toolbar. textColor is set once in makeNSView using NSColor.textColor
    // (a semantic system color that auto-adapts to textView.appearance);
    // changing the appearance below is enough to re-render default-color
    // text in the new theme.
    static func applyPalette(_ palette: Palette, to textView: NSTextView, scrollView: NSScrollView) {
        textView.backgroundColor = palette.editorBackgroundNS
        textView.insertionPointColor = palette.textNS
        textView.appearance = NSAppearance(named: palette.appearance)
        textView.linkTextAttributes = [
            .foregroundColor: palette.linkNS,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        // Theme-tuned text selection. NSTextView's default
        // .selectedTextBackgroundColor is a system gray-blue that looks
        // muddy on pure-black dark mode; a brighter accent blue with
        // tuned alpha reads better in both themes.
        textView.selectedTextAttributes = [
            .backgroundColor: palette.selectionBackgroundNS,
            .foregroundColor: palette.selectedTextNS
        ]
        scrollView.backgroundColor = palette.editorBackgroundNS
        scrollView.appearance = NSAppearance(named: palette.appearance)
    }

    // Detach the layout manager when SwiftUI dismantles the view, so the
    // shared NSTextStorage doesn't hold a stale rendering pipeline alive
    // after the editor is gone.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let storage = layoutManager.textStorage else { return }
        storage.removeLayoutManager(layoutManager)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: () -> Void
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        private var themeObserver: NSObjectProtocol?

        init(onTextChange: @escaping () -> Void) {
            self.onTextChange = onTextChange
        }

        deinit {
            if let token = themeObserver {
                NotificationCenter.default.removeObserver(token)
            }
        }

        func startObservingTheme() {
            themeObserver = NotificationCenter.default.addObserver(
                forName: .themeChanged, object: nil, queue: .main
            ) { [weak self] _ in
                guard let tv = self?.textView, let sv = self?.scrollView else { return }
                RichTextEditor.applyPalette(ThemeStore.shared.palette, to: tv, scrollView: sv)
                tv.needsDisplay = true
            }
        }

        func textDidChange(_ notification: Notification) {
            // Cheap by design: just notify. NoteStore reads the shared text
            // storage and debounces the RTF-encode + disk write, so there's
            // no per-keystroke serialization on the main thread here.
            onTextChange()
        }
    }
}

// Thin wrapper that exposes the editor and the Copy button.
struct NoteEditorView: View {
    @EnvironmentObject var store: NoteStore
    @EnvironmentObject var theme: ThemeStore
    let note: Note

    var body: some View {
        VStack(spacing: 0) {
            TagBar(note: note)

            Rectangle()
                .fill(theme.palette.dividerColor)
                .frame(height: 1)

            ZStack(alignment: .bottomTrailing) {
                RichTextEditor(noteId: note.id) {
                    // The shared NSTextStorage is the live source of truth;
                    // NoteStore debounces the RTF-encode + disk write so typing
                    // never blocks on serialization (see noteBodyDidChange).
                    store.noteBodyDidChange(note.id)
                }

                // Copy button
                Button {
                    // Read the live storage — note.rtfData is only refreshed
                    // when the debounced save fires, so it can lag the screen.
                    let plain = store.plainText(for: note.id)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plain, forType: .string)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13))
                        Text("Copy")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(theme.palette.copyButtonText)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(theme.palette.copyButtonBackground, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(20)
            }
        }
    }
}
