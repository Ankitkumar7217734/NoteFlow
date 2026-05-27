import AppKit
import SwiftUI
import Carbon

// NSPanel without a title bar normally refuses to become the key window,
// which means NSTextView inside it can't receive keystrokes. Subclass and
// force canBecomeKey/Main to return true so the floating editor is typeable.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var floatingPanel: FloatingPanel!
    private var hotKeyRef: EventHotKeyRef?       // user-configurable, default ⌥D
    private var globalHotKeyRef: EventHotKeyRef? // fixed ⌃⇧D
    // Track the app that was active before the floating panel opened so we can restore it.
    private var previousApp: NSRunningApplication?

    private let floatingSize = NSSize(width: 520, height: 535)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setDockIcon()

        let palette = ThemeStore.shared.palette
        let content = ContentView(inTitledWindow: true)
            .environmentObject(NoteStore.shared)
            .environmentObject(ThemeStore.shared)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = palette.chromeBackgroundNS
        window.appearance = NSAppearance(named: palette.appearance)
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: palette.appearance)
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)

        setupFloatingPanel()
        registerGlobalHotkey()

        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTheme),
            name: .themeChanged, object: nil
        )
    }

    @objc private func applyTheme() {
        let palette = ThemeStore.shared.palette
        let appearance = NSAppearance(named: palette.appearance)
        window.backgroundColor = palette.chromeBackgroundNS
        window.appearance = appearance
        window.contentView?.appearance = appearance
        floatingPanel?.contentView?.appearance = appearance
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Install the pre-processed logo (cropped + rounded) as the Dock icon.
    // Done in-process since this is a `swift run` executable with no .icns
    // in an .app bundle — the icon is set fresh on every launch.
    private func setDockIcon() {
        NSApp.applicationIconImage = AppLogo.processed
    }

    // MARK: – Floating panel

    private func setupFloatingPanel() {
        // .nonactivatingPanel lets the panel become key WITHOUT activating
        // NoteFlow, so triggering the hotkey from another app's full-screen
        // Space doesn't cause a Space switch back to NoteFlow's main window.
        // Our FloatingPanel subclass overrides canBecomeKey so the text view
        // still receives keystrokes despite the non-activating style.
        floatingPanel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: floatingSize),
            styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        floatingPanel.isMovableByWindowBackground = true
        floatingPanel.backgroundColor = .clear
        floatingPanel.isOpaque = false
        floatingPanel.hasShadow = true
        let palette = ThemeStore.shared.palette
        floatingPanel.appearance = NSAppearance(named: palette.appearance)
        // screenSaver level keeps it above full-screen apps.
        floatingPanel.level = .screenSaver
        floatingPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel.isFloatingPanel = true
        floatingPanel.hidesOnDeactivate = false
        floatingPanel.worksWhenModal = true

        let panelContent = ContentView(isFloatingPanel: true)
            .environmentObject(NoteStore.shared)
            .environmentObject(ThemeStore.shared)
        let panelHost = NSHostingView(rootView: panelContent)
        panelHost.appearance = NSAppearance(named: palette.appearance)
        panelHost.wantsLayer = true
        panelHost.layer?.cornerRadius = 14
        panelHost.layer?.masksToBounds = true
        floatingPanel.contentView = panelHost
        floatingPanel.center()
    }

    func toggleFloating() {
        if NoteStore.shared.isFloating {
            NoteStore.shared.isFloating = false
            floatingPanel.orderOut(nil)
            // Restore whichever app was active before the panel opened.
            previousApp?.activate()
            previousApp = nil
        } else {
            NoteStore.shared.isFloating = true
            // Remember the current frontmost app before we take over.
            previousApp = NSWorkspace.shared.frontmostApplication

            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let origin = NSPoint(
                x: screen.midX - floatingSize.width / 2,
                y: screen.midY - floatingSize.height / 2
            )
            floatingPanel.setFrame(NSRect(origin: origin, size: floatingSize), display: true, animate: true)
            // DO NOT call NSApp.activate(...) here — that would pull the user
            // off the current Space (e.g. another app's full-screen Space) and
            // back to NoteFlow's main window's Space. The .nonactivatingPanel
            // style + canBecomeKey override let the panel show + accept input
            // without activating NoteFlow, so it overlays on the current Space.
            floatingPanel.orderFrontRegardless()
            floatingPanel.makeKeyAndOrderFront(nil)

            // Focus the editor inside the panel so the user can type immediately.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let tv = self.firstTextView(in: self.floatingPanel.contentView) {
                    self.floatingPanel.makeFirstResponder(tv)
                }
            }
        }
    }

    func expandToFull() {
        NoteStore.shared.isFloating = false
        floatingPanel.orderOut(nil)
        previousApp = nil
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view = view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let tv = firstTextView(in: sub) { return tv }
        }
        return nil
    }

    // MARK: – Global hotkeys (Carbon — works system-wide without Accessibility permission)

    private func registerGlobalHotkey() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let ptr = userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(ptr).takeUnretainedValue()
            // Both hotkeys do the same thing — open the floating editor.
            DispatchQueue.main.async { delegate.toggleFloating() }
            return noErr
        }, 1, &eventSpec, selfPtr, nil)

        reRegisterHotkey()

        NotificationCenter.default.addObserver(
            self, selector: #selector(reRegisterHotkey),
            name: .hotkeyChanged, object: nil
        )
    }

    @objc private func reRegisterHotkey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = globalHotKeyRef { UnregisterEventHotKey(ref); globalHotKeyRef = nil }

        let hs = HotkeyStore.shared
        let sig = FourCharCode(0x4E464C57)

        // Primary, user-configurable hotkey (default ⌥D).
        let primaryID = EventHotKeyID(signature: sig, id: 1)
        RegisterEventHotKey(hs.keyCode, hs.carbonModifiers, primaryID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)

        // Fixed system-wide ⌃⇧D, always available even when another app is in
        // full-screen. Only register if the user hasn't configured the primary
        // hotkey to the same combination.
        let globalCode = UInt32(kVK_ANSI_D)
        let globalMods = UInt32(controlKey | shiftKey)
        if !(hs.keyCode == globalCode && hs.carbonModifiers == globalMods) {
            let globalID = EventHotKeyID(signature: sig, id: 2)
            RegisterEventHotKey(globalCode, globalMods, globalID,
                                GetApplicationEventTarget(), 0, &globalHotKeyRef)
        }
    }
}
