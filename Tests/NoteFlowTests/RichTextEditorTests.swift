import Testing
import AppKit
@testable import NoteFlow

// Typing must stay O(visible screen), not O(note length): a keystroke in a
// long document must not force layout of the entire document. (Layout below
// the viewport happens lazily, the way NSTextView is designed to work.)
@Test @MainActor func typingDoesNotForceFullDocumentLayout() {
    let text = String(repeating: "The quick brown fox jumps over the lazy dog.\n",
                      count: 5_000)
    let storage = NSTextStorage(string: text)
    let layoutManager = NoteLayoutManager()
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer(size: NSSize(width: 500,
                                                 height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layoutManager.addTextContainer(container)

    let textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 600),
                                textContainer: container)
    textView.minSize = NSSize.zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
    scrollView.documentView = textView

    // One keystroke at the top of the document.
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.insertText("a", replacementRange: NSRange(location: 0, length: 0))

    let length = (textView.string as NSString).length
    #expect(layoutManager.firstUnlaidCharacterIndex() < length,
            "a keystroke must not force layout of the entire document")
}

// Notes containing tables must be detected so their layout managers can
// stay in contiguous mode (NSTextTable misbehaves under non-contiguous
// layout). Plain text — including styled text — must not trip the check.
@Test func tableDetectionFindsTextBlocks() {
    let table = NSTextTable()
    table.numberOfColumns = 1
    let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                 startingColumn: 0, columnSpan: 1)
    let para = NSMutableParagraphStyle()
    para.textBlocks = [block]
    let withTable = NSAttributedString(string: "cell\n",
                                       attributes: [.paragraphStyle: para])
    #expect(NoteTextView.containsTables(withTable))
}

@Test func tableDetectionIgnoresPlainText() {
    let para = NSMutableParagraphStyle()
    para.alignment = .natural
    let plain = NSAttributedString(string: "just some text\n",
                                   attributes: [.paragraphStyle: para])
    #expect(!NoteTextView.containsTables(plain))
    #expect(!NoteTextView.containsTables(NSAttributedString()))
}
