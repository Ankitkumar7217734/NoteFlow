import Testing
import AppKit
@testable import NoteFlow

// The floating panel's configuration is the most fragile contract in the
// app: lose .nonactivatingPanel or either canBecome override and the panel
// either yanks the user off their Space or silently stops accepting
// keystrokes (see CLAUDE.md). Pin every load-bearing flag.
@Test @MainActor func floatingPanelKeepsItsLoadBearingConfiguration() {
    let panel = FloatingPanel(contentSize: NSSize(width: 520, height: 535))

    #expect(panel.canBecomeKey, "text input dies without this override")
    #expect(panel.canBecomeMain, "text input dies without this override")
    #expect(panel.styleMask.contains(.nonactivatingPanel),
            "without this, summoning the panel switches macOS Spaces")
    #expect(panel.styleMask.contains(.resizable))
    #expect(panel.styleMask.contains(.fullSizeContentView))
    #expect(panel.level == .screenSaver, "must overlay full-screen apps")
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(panel.hidesOnDeactivate == false)
    #expect(panel.isOpaque == false, "needed for the rounded-corner mask")
    #expect(panel.isFloatingPanel)
    #expect(panel.worksWhenModal)
}

// MARK: – PanelSettings

private func isolatedDefaults() -> (UserDefaults, String) {
    let suite = "PanelSettingsTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

@Test @MainActor func opacityIsClampedToUsableRange() {
    // 0.5 floor: an almost-invisible panel would still be key and swallow
    // every keystroke — confusing in the worst way.
    #expect(PanelSettings.clampedOpacity(0.3) == 0.5)
    #expect(PanelSettings.clampedOpacity(1.4) == 1.0)
    #expect(PanelSettings.clampedOpacity(0.85) == 0.85)
}

@Test @MainActor func opacityPersistsAcrossInstances() {
    let (defaults, suite) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = PanelSettings(defaults: defaults)
    #expect(first.opacity == 1.0, "default is fully opaque")
    first.opacity = 0.7

    let second = PanelSettings(defaults: defaults)
    #expect(abs(second.opacity - 0.7) < 0.001)
}

@Test @MainActor func assigningOutOfRangeOpacityStoresClampedValue() {
    let (defaults, suite) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let settings = PanelSettings(defaults: defaults)
    settings.opacity = 0.1
    #expect(settings.opacity == 0.5)
    #expect(PanelSettings(defaults: defaults).opacity == 0.5)
}

@Test @MainActor func panelSizePersistsAndRejectsGarbage() {
    let (defaults, suite) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let settings = PanelSettings(defaults: defaults)
    #expect(settings.panelSize == PanelSettings.defaultSize, "no saved size yet")

    settings.panelSize = NSSize(width: 700, height: 620)
    #expect(PanelSettings(defaults: defaults).panelSize == NSSize(width: 700, height: 620))

    // Corrupted / absurd saved values fall back to the default.
    defaults.set(10.0, forKey: "panelWidth")
    defaults.set(5.0, forKey: "panelHeight")
    #expect(PanelSettings(defaults: defaults).panelSize == PanelSettings.defaultSize)
}
