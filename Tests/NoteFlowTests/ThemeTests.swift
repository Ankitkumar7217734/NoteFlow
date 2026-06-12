import Testing
import AppKit
@testable import NoteFlow

// WCAG relative-luminance contrast. The "Paper & Ink" themes target the
// long-form-writing comfort band: strong enough to read effortlessly,
// below the harsh pure-black-on-white extreme that fatigues over a long
// session (the user-reported problem these palettes exist to fix).
private func luminance(_ color: NSColor) -> CGFloat {
    let c = color.usingColorSpace(.sRGB)!
    func lin(_ v: CGFloat) -> CGFloat {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent)
         + 0.0722 * lin(c.blueComponent)
}

private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

@Test func darkBodyTextSitsInComfortBand() {
    let p = Palette.dark
    let ratio = contrast(p.textNS, p.editorBackgroundNS)
    #expect(ratio >= 9 && ratio <= 16,
            "dark body ink vs editor was \(ratio):1 — outside the 9–16:1 comfort band")
}

@Test func lightBodyTextSitsInComfortBand() {
    let p = Palette.light
    let ratio = contrast(p.textNS, p.editorBackgroundNS)
    #expect(ratio >= 9 && ratio <= 16,
            "light body ink vs editor was \(ratio):1 — outside the 9–16:1 comfort band")
}

@Test func darkSurfacesAreLayeredNotFlat() {
    let p = Palette.dark
    // The editor surface must be distinguishable from the chrome — the old
    // pure-black-everywhere theme had zero separation between them.
    #expect(luminance(p.editorBackgroundNS) > luminance(p.chromeBackgroundNS))
}

@Test func secondaryTextStaysLegible() {
    #expect(contrast(NSColor(Palette.dark.secondaryText), Palette.dark.editorBackgroundNS) >= 4.5)
    #expect(contrast(NSColor(Palette.light.secondaryText), Palette.light.editorBackgroundNS) >= 4.5)
}

// MARK: – Default-ink migration

// Both the legacy defaults (pure black / 0.91 white) and the new Paper & Ink
// defaults must be recognized as theme defaults, or text saved under one
// theme gets stranded (possibly invisible) after a flip.
@Test func allFourDefaultInksAreStripped() {
    let inks: [NSColor] = [
        .black,                                            // legacy light
        NSColor(white: 0.91, alpha: 1),                    // legacy dark
        Palette.light.textNS,                              // paper ink
        Palette.dark.textNS                                // graphite ink
    ]
    for ink in inks {
        let s = NSMutableAttributedString(string: "hello",
                                          attributes: [.foregroundColor: ink])
        NoteStore.stripThemeDefaultForegroundColors(in: s)
        let remaining = s.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        #expect(remaining == nil, "ink \(ink) should be stripped as a theme default")
    }
}

@Test func userPickedColorsSurviveStripping() {
    let s = NSMutableAttributedString(string: "hello",
                                      attributes: [.foregroundColor: NSColor.systemRed])
    NoteStore.stripThemeDefaultForegroundColors(in: s)
    #expect(s.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil,
            "a user-picked red must never be stripped")
}
