import Testing
import Foundation
import AppKit
@testable import NoteFlow

// Pins the color-preservation invariant: text colors written by the user
// (Text Formatting picker) or by the MCP server (\cfN runs in the RTF) must
// survive opening the note in an editor. The historical bug: makeNSView set
// textView.textColor *after* attaching the shared storage, and that NSText
// setter recolors every character — so every note open flattened all colored
// runs to the theme ink.

private func srgb(_ color: NSColor?) -> (CGFloat, CGFloat, CGFloat)? {
    guard let c = color?.usingColorSpace(.sRGB) else { return nil }
    return (c.redComponent, c.greenComponent, c.blueComponent)
}

// Tolerance 0.05: Cocoa's RTF reader decodes \redN\greenN\blueN through a
// calibrated colorspace, so 204/255 comes back as ~0.829 in sRGB, not 0.800.
private func approx(_ a: (CGFloat, CGFloat, CGFloat)?, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
    guard let a else { return false }
    return abs(a.0 - r) < 0.05 && abs(a.1 - g) < 0.05 && abs(a.2 - b) < 0.05
}

/// The exact RTF shape the NoteFlow MCP server writes for
/// "{color:yellow}Important{/color} rest of the line".
private let mcpColoredRTF = Data(
    (
        "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2870\\cocoatextscaling0\\cocoaplatform0"
        + "{\\fonttbl\\f0\\fnil\\fcharset0 HelveticaNeue;"
        + "\\f1\\fnil\\fcharset0 HelveticaNeue-Bold;"
        + "\\f2\\fnil\\fcharset0 .AppleSystemUIFontMonospaced-Regular;}\n"
        + "{\\colortbl;\\red255\\green255\\blue255;\\red10\\green96\\blue255;"
        + "\\red0\\green0\\blue0;\\red253\\green130\\blue8;\\red255\\green59\\blue48;"
        + "\\red255\\green204\\blue0;}\n"
        + "\\pard\\tx560\\tx1120\\tx1680\\tx2240\\tx2800\\tx3360\\tx3920\\tx4480"
        + "\\tx5040\\tx5600\\tx6160\\tx6720\\pardirnatural\\partightenfactor0\n"
        + "\\f0\\fs28 \\cf3 {\\cf6 Important} rest of the line}"
    ).utf8
)

@Test @MainActor func buildingAnEditorPreservesStorageColors() {
    let storage = NSTextStorage(string: "Alert rest")
    let yellow = NSColor(srgbRed: 1.0, green: 0.8, blue: 0.0, alpha: 1)
    storage.addAttribute(.foregroundColor, value: yellow,
                         range: NSRange(location: 0, length: 5))
    storage.addAttribute(.foregroundColor, value: Palette.dynamicInkNS,
                         range: NSRange(location: 5, length: 5))

    let (_, textView) = RichTextEditor.buildEditor(storage: storage, compact: false)

    let after = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(approx(srgb(after), 1.0, 0.8, 0.0),
            "editor construction must not recolor existing runs")
    _ = textView
}

@Test @MainActor func mcpColoredRTFSurvivesNoteOpen() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("NoteFlowColorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = NoteStore(saveURL: dir.appendingPathComponent("notes.json"))

    var note = Note(title: "MCP colored")
    note.rtfData = mcpColoredRTF
    store.notes.insert(note, at: 0)

    // Note open: shared storage build (normalization pipeline) + editor build.
    let storage = store.sharedTextStorage(for: note.id)
    let (_, _) = RichTextEditor.buildEditor(storage: storage, compact: false)

    let text = storage.string as NSString
    let coloredAt = text.range(of: "Important").location
    let defaultAt = text.range(of: "rest").location
    #expect(coloredAt != NSNotFound && defaultAt != NSNotFound)

    let colored = storage.attribute(.foregroundColor, at: coloredAt, effectiveRange: nil) as? NSColor
    #expect(approx(srgb(colored), 1.0, 0.8, 0.0),
            "MCP yellow (\\cf6 255,204,0) must survive note open")

    // The MCP's default ink (\cf3 black) is a theme default: it must have
    // been swapped for the dynamic ink, not left black and not yellow.
    let fallback = storage.attribute(.foregroundColor, at: defaultAt, effectiveRange: nil) as? NSColor
    #expect(fallback != nil)
    #expect(!approx(srgb(fallback), 0, 0, 0), "default ink must follow the theme, not stay black")
}

@Test func attributeLessRunsGetExplicitInk() {
    // Every run in a live storage must end up with an explicit foreground
    // color (the editor no longer sets a view-level textColor, and AppKit
    // renders attribute-less text black in both themes).
    let storage = NSMutableAttributedString(string: "no color at all")
    NoteStore.replaceThemeDefaultForegroundColors(in: storage)
    let color = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(color != nil)
}
