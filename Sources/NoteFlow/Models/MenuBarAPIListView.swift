import AppKit

/// One row of the menu-bar API list — shared between the native flat menu
/// items and the scrollable fallback so both layouts group pages → providers
/// identically.
enum APIMenuRow: Equatable {
    case pageHeader(String)
    case providerHeader(String)
    case copyURL(MenuBarProviderEntry)
    case copyKey(MenuBarAPIEntry)
    case pageSeparator

    var isContentRow: Bool {
        if case .pageSeparator = self { return false }
        return true
    }
}

/// The API submenu's content when the key list is long: the *same* flat rows
/// the native layout shows, hosted in a fixed-height NSScrollView inside a
/// single custom-view menu item. NSMenu has no API to cap its own height — a
/// long item list stretches the menu toward full screen before scroll arrows
/// appear — so the cap lives here instead: a small menu window that scrolls.
final class MenuBarAPIListView: NSView {
    static let rowHeight: CGFloat = 24
    static let separatorHeight: CGFloat = 9
    /// At most this many rows are visible at once; the rest scroll.
    static let maxVisibleRows = 12
    static let minListWidth: CGFloat = 280
    static let maxListWidth: CGFloat = 440
    private static let verticalPadding: CGFloat = 5

    let scrollView = NSScrollView()
    /// Content rows in display order (headers + copy rows; separators excluded).
    private(set) var rowViews: [MenuBarAPIListRowView] = []

    init(rows: [APIMenuRow], onCopy: @escaping (String) -> Void) {
        // Build the content rows first so the list width can hug the longest title.
        var contentViews: [MenuBarAPIListRowView] = []
        var layout: [(view: NSView, height: CGFloat)] = []
        var maxTitleWidth: CGFloat = 0
        for row in rows {
            if row.isContentRow {
                let view = MenuBarAPIListRowView(row: row, onCopy: onCopy)
                maxTitleWidth = max(maxTitleWidth, view.preferredWidth)
                contentViews.append(view)
                layout.append((view, Self.rowHeight))
            } else {
                let line = NSBox()
                line.boxType = .separator
                layout.append((line, Self.separatorHeight))
            }
        }
        let width = min(max(maxTitleWidth, Self.minListWidth), Self.maxListWidth)

        // Manual top-down layout in a flipped document view — rows have two
        // fixed heights, so Auto Layout would be overkill.
        let document = FlippedDocumentView()
        var y = Self.verticalPadding
        for (view, height) in layout {
            if view is MenuBarAPIListRowView {
                view.frame = NSRect(x: 0, y: y, width: width, height: height)
            } else {
                view.frame = NSRect(x: 14, y: y + height / 2, width: width - 28, height: 1)
            }
            view.autoresizingMask = [.width]
            document.addSubview(view)
            y += height
        }
        let contentHeight = y + Self.verticalPadding
        document.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)

        let visibleHeight = min(contentHeight, CGFloat(Self.maxVisibleRows) * Self.rowHeight)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: visibleHeight))
        rowViews = contentViews

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .allowed
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Menus read top-down; NSView coordinates are bottom-up. Flip the document
/// so row 0 sits at the top and the scroll view starts scrolled to the top.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A single row: a page/provider header (non-interactive) or a copy action —
/// hover-highlighted like a native menu item, click copies and dismisses.
final class MenuBarAPIListRowView: NSView {
    /// The string a click copies; nil for header rows.
    let copyValue: String?
    let title: String
    private let indent: CGFloat
    private let normalColor: NSColor
    private let onCopy: (String) -> Void
    private let label = NSTextField(labelWithString: "")
    private var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            label.textColor = hovered ? .selectedMenuItemTextColor : normalColor
            needsDisplay = true
        }
    }

    init(row: APIMenuRow, onCopy: @escaping (String) -> Void) {
        let font: NSFont
        switch row {
        case .pageHeader(let pageTitle):
            title = pageTitle
            copyValue = nil
            indent = 12
            font = .systemFont(ofSize: 11, weight: .semibold)
            normalColor = .secondaryLabelColor
        case .providerHeader(let name):
            title = name
            copyValue = nil
            indent = 12
            font = .systemFont(ofSize: 12, weight: .semibold)
            normalColor = .labelColor
        case .copyURL(let entry):
            title = "Copy URL  ·  \(entry.menuTitle)"
            copyValue = entry.baseURL
            indent = 22
            font = .menuFont(ofSize: 13)
            normalColor = .labelColor
        case .copyKey(let entry):
            title = "Copy key  ·  \(entry.menuTitle)"
            copyValue = entry.keyValue
            indent = 22
            font = .menuFont(ofSize: 13)
            normalColor = .labelColor
        case .pageSeparator:
            // The list view never builds a row view for separators.
            title = ""
            copyValue = nil
            indent = 0
            font = .menuFont(ofSize: 13)
            normalColor = .labelColor
        }
        self.onCopy = onCopy
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: MenuBarAPIListView.rowHeight))

        label.stringValue = title
        label.font = font
        label.textColor = normalColor
        label.lineBreakMode = .byTruncatingMiddle  // keep the recognizable key tail visible
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(
            x: indent,
            y: (MenuBarAPIListView.rowHeight - labelHeight) / 2,
            width: bounds.width - indent - 12,
            height: labelHeight
        )
        label.autoresizingMask = [.width]
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Width the row wants, so the list can hug its longest title.
    var preferredWidth: CGFloat {
        indent + label.intrinsicContentSize.width + 20
    }

    // MARK: – Hover + click (action rows only)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard copyValue != nil else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}  // swallow; act on mouseUp like menus do

    override func mouseUp(with event: NSEvent) {
        guard copyValue != nil else { return }
        triggerCopy()
        hovered = false
        enclosingMenuItem?.menu?.cancelTracking()
    }

    /// Split out so tests can drive the copy without synthesizing mouse events.
    func triggerCopy() {
        guard let copyValue else { return }
        onCopy(copyValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered, copyValue != nil else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 5, dy: 2),
            xRadius: 4, yRadius: 4
        ).fill()
    }
}
