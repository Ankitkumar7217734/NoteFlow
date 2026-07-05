import AppKit
import SwiftUI
import Carbon

// NSPanel without a title bar normally refuses to become the key window,
// which means NSTextView inside it can't receive keystrokes. Subclass and
// force canBecomeKey/Main to return true so the floating editor is typeable.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Every load-bearing flag in one testable place (pinned by
    /// PanelTests.floatingPanelKeepsItsLoadBearingConfiguration):
    /// .nonactivatingPanel + the overrides above keep the panel typeable
    /// without activating NoteFlow (no Space switch); .screenSaver level +
    /// the collection behavior let it overlay full-screen apps on any Space.
    convenience init(contentSize: NSSize) {
        self.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // isFloatingPanel must be set BEFORE level: setting it resets the
        // window level to .floating(3), which silently undid .screenSaver
        // in the original code (caught by the pin test).
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        worksWhenModal = true
        // Managed entirely by AppDelegate.toggleFloating — never autosaved by
        // macOS session restoration (see AppDelegate shouldRestoreApplicationState).
        isRestorable = false
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var floatingPanel: FloatingPanel!
    private var hotKeyRef: EventHotKeyRef?       // user-configurable, default ⌥D
    private var globalHotKeyRef: EventHotKeyRef? // fixed ⌃⇧D
    // Track the app that was active before the floating panel opened so we can restore it.
    private var previousApp: NSRunningApplication?

    /// NoteFlow creates and owns its windows in code (main window + floating
    /// panel). Letting macOS save/restore window state — which happens when
    /// the app is still running across a system restart — fights that setup
    /// and can crash during relaunch ("unexpectedly quit while reopening
    /// windows"). We persist note data ourselves; window frames live in
    /// PanelSettings / manual layout instead.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        discardStaleSavedApplicationState()
    }

    /// Remove macOS session-restoration snapshots. We opt out of restoration
    /// entirely, and a leftover `.savedState` folder from an older build can
    /// keep triggering the "Reopen windows?" dialog after a system restart.
    private func discardStaleSavedApplicationState() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")
        try? FileManager.default.removeItem(at: url)
    }

    func application(_ application: NSApplication,
                     shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication,
                     shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

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
        window.delegate = self
        window.isRestorable = false
        window.center()
        window.makeKeyAndOrderFront(nil)

        setupFloatingPanel()
        registerGlobalHotkey()
        MenuBarController.shared.install()

        NotificationCenter.default.addObserver(
            self, selector: #selector(prepareThemeCrossFade),
            name: .themeWillChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTheme),
            name: .themeChanged, object: nil
        )
    }

    // MARK: – Theme cross-fade

    private static let themeFadeOverlayID = NSUserInterfaceItemIdentifier("themeFadeOverlay")

    /// themeWillChange fires before the mode mutates: snapshot every visible
    /// window's content while it still shows the outgoing theme and pin the
    /// snapshot on top. applyTheme() then repaints underneath and fades the
    /// snapshot out, so SwiftUI views, the NSTextView and the window chrome
    /// all transition as one image instead of hard-cutting in random order.
    @objc private func prepareThemeCrossFade() {
        for win in NSApp.windows where win.isVisible {
            guard let content = win.contentView, content.bounds.width > 0 else { continue }
            // A rapid double-toggle can race a fade still in flight.
            content.subviews
                .filter { $0.identifier == Self.themeFadeOverlayID }
                .forEach { $0.removeFromSuperview() }

            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.cacheDisplay(in: content.bounds, to: rep)
            let image = NSImage(size: content.bounds.size)
            image.addRepresentation(rep)

            let overlay = NSImageView(frame: content.bounds)
            overlay.image = image
            overlay.imageScaling = .scaleAxesIndependently
            overlay.autoresizingMask = [.width, .height]
            overlay.identifier = Self.themeFadeOverlayID
            content.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
    }

    @objc private func applyTheme() {
        let palette = ThemeStore.shared.palette
        let appearance = NSAppearance(named: palette.appearance)
        window.backgroundColor = palette.chromeBackgroundNS
        window.appearance = appearance
        window.contentView?.appearance = appearance
        floatingPanel?.contentView?.appearance = appearance

        // Fade out the pre-flip snapshots installed by prepareThemeCrossFade.
        for win in NSApp.windows {
            guard let content = win.contentView else { continue }
            for overlay in content.subviews where overlay.identifier == Self.themeFadeOverlayID {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.28
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    overlay.animator().alphaValue = 0
                }, completionHandler: { [weak overlay] in
                    overlay?.removeFromSuperview()
                })
            }
        }
    }

    /// Keep NoteFlow in the Dock when the main window is closed — standard
    /// macOS productivity-app behaviour (close hides, Dock click reopens).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// Red traffic-light close: hide the window, don't quit the app.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            hideMainWindow()
            return false
        }
        return true
    }

    func showMainWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideMainWindow() {
        NoteStore.shared.flushPendingSaves()
        window.orderOut(nil)
    }

    // Persist any debounced, not-yet-written edits when the app loses focus
    // or quits, so the last keystrokes before switching away / quitting are
    // never lost. flushPendingSaves() no-ops when nothing is dirty.
    func applicationWillResignActive(_ notification: Notification) {
        NoteStore.shared.flushPendingSaves()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NoteStore.shared.flushPendingSaves()
        NoteStore.shared.purgeUnusedSessionNotesOnQuit()
    }

    // Install the pre-processed logo (cropped + rounded) as the Dock icon.
    // Done in-process since this is a `swift run` executable with no .icns
    // in an .app bundle — the icon is set fresh on every launch.
    private func setDockIcon() {
        NSApp.applicationIconImage = AppLogo.processed
    }

    // MARK: – Floating panel

    private func setupFloatingPanel() {
        // All panel configuration lives in FloatingPanel(contentSize:) so
        // the load-bearing flags are covered by tests. Size is the user's
        // last (persisted) panel size.
        floatingPanel = FloatingPanel(contentSize: PanelSettings.shared.panelSize)
        let palette = ThemeStore.shared.palette
        floatingPanel.appearance = NSAppearance(named: palette.appearance)

        // Remember the size the user drags the panel to.
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidEndResize),
            name: NSWindow.didEndLiveResizeNotification, object: floatingPanel
        )
        // Apply opacity changes live while the Settings slider is dragged.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPanelOpacity),
            name: .panelOpacityChanged, object: nil
        )

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

            // Last user-chosen size, re-centered on the current screen.
            let panelSize = PanelSettings.shared.panelSize
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let origin = NSPoint(
                x: screen.midX - panelSize.width / 2,
                y: screen.midY - panelSize.height / 2
            )
            // Entrance animation: start a touch lower and fully transparent,
            // then rise + fade into place. Driven by the panel's animator via
            // NSAnimationContext so we never call NSApp.activate (which would
            // yank the user off their current Space — see the note below).
            let finalFrame = NSRect(origin: origin, size: panelSize)
            floatingPanel.alphaValue = 0
            floatingPanel.setFrame(finalFrame.offsetBy(dx: 0, dy: -12), display: false)
            // DO NOT call NSApp.activate(...) here — that would pull the user
            // off the current Space (e.g. another app's full-screen Space) and
            // back to NoteFlow's main window's Space. The .nonactivatingPanel
            // style + canBecomeKey override let the panel show + accept input
            // without activating NoteFlow, so it overlays on the current Space.
            floatingPanel.orderFrontRegardless()
            floatingPanel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                // Land on the user's chosen opacity, not hard-coded 1.
                floatingPanel.animator().alphaValue = PanelSettings.shared.opacity
                floatingPanel.animator().setFrame(finalFrame, display: true)
            }

            // Focus the editor inside the panel so the user can type immediately.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let tv = self.firstTextView(in: self.floatingPanel.contentView) {
                    self.floatingPanel.makeFirstResponder(tv)
                }
            }
        }
    }

    @objc private func panelDidEndResize() {
        PanelSettings.shared.panelSize = floatingPanel.frame.size
    }

    @objc private func applyPanelOpacity() {
        guard floatingPanel.isVisible else { return }
        floatingPanel.alphaValue = PanelSettings.shared.opacity
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
