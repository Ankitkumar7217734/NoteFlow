# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**NoteFlow** is a native macOS note-taking app (macOS 14+) built with SwiftUI/AppKit, distributed as a SwiftPM executable (`Package.swift`). The repo also contains an inactive Electron + React scaffold (`package.json`, `vite.config.js`, `src/`) that is not part of the live app.

## Build & Run

```bash
# Build (debug)
swift build

# Run
swift run NoteFlow

# Build a release .app bundle + styled .dmg in the repo root
bash scripts/make-dmg.sh
```

After changing `AppDelegate.swift`, kill the running process and relaunch — `swift run` does not hot-reload.

`scripts/make-dmg.sh` does `swift build -c release`, assembles a `.app` bundle (Info.plist + AppIcon.icns generated from `Sources/NoteFlow/Resources/logo.png` via `sips`/`iconutil`), renders the DMG background via `scripts/make-background.swift`, and styles the volume window with AppleScript. There are no tests and no lint tooling configured.

## Architecture

### Two-window design

`AppDelegate` owns two separate windows that both render `ContentView` backed by the shared `NoteStore.shared`:

| Window | Type | Size | Purpose |
|--------|------|------|---------|
| `window` | `NSWindow` | 1280×800 | Main app — regular window, user can manually full-screen |
| `floatingPanel` | `FloatingPanel: NSPanel` | 520×535 | Overlay panel shown over any app via global hotkey |

**Critical constraint**: The main window must **not** be in full-screen when the floating panel is triggered. Full-screen windows live on a dedicated macOS Space; activating NoteFlow while full-screen would force a Space switch. The app therefore does not call `toggleFullScreen` at launch.

### Floating panel behaviour

Two hotkeys trigger `toggleFloating()`:
- **Primary** (user-configurable, default **⌥D**) — registered from `HotkeyStore`.
- **Fixed ⌃⇧D fallback** — always registered unless the primary already matches it. Both are wired through the same Carbon handler.

On show (`toggleFloating()`):
1. `previousApp` is saved (`NSWorkspace.shared.frontmostApplication`).
2. The panel is recentred on the current screen's `visibleFrame`.
3. `floatingPanel.orderFrontRegardless()` + `makeKeyAndOrderFront(nil)` — **do not** call `NSApp.activate(...)` here. The panel must show without activating NoteFlow, otherwise macOS yanks the user off whatever Space (e.g. another app's full-screen) they were on, back to the main window's Space.
4. An async pass walks the panel's view tree to find the first `NSTextView` and `makeFirstResponder`s it, so the user can type immediately.

On dismiss: `floatingPanel.orderOut(nil)`, then `previousApp?.activate()` restores the user's previous app.

The panel is configured with:
- Style mask: `[.nonactivatingPanel, .resizable, .fullSizeContentView]`. `.nonactivatingPanel` is what lets the panel become key without activating the app (preventing the Space switch above).
- `level = .screenSaver` and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` so it overlays full-screen apps on every Space.
- `backgroundColor = .clear`, `isOpaque = false`, and the hosting view's `CALayer` has `cornerRadius = 14` / `masksToBounds = true` to produce rounded corners without a title bar.

**`FloatingPanel` exists specifically to override `canBecomeKey`/`canBecomeMain` to return `true`.** A title-bar-less `.nonactivatingPanel` would otherwise refuse to become key, and `NSTextView` inside it would silently drop keystrokes. Both flags are required — don't remove either.

`expandToFull()` is the inverse path: hides the panel, brings the main window forward, and explicitly calls `NSApp.activate(ignoringOtherApps: true)` (Space switch is desired here).

### Global hotkey

Registered via Carbon `RegisterEventHotKey` (not `NSEvent.addGlobalMonitorForEvents`, which requires Accessibility permission). The user-configurable config lives in `HotkeyStore` (persisted to `UserDefaults` as `hotkeyKeyCode` / `hotkeyModifiers`). When the user changes the shortcut in Settings, a `Notification.Name.hotkeyChanged` notification triggers `AppDelegate.reRegisterHotkey()`, which unregisters both hotkeys and re-registers the primary plus the fixed ⌃⇧D fallback.

### State & Persistence

`NoteStore` (singleton `ObservableObject`) is the single source of truth for *data*. It owns:
- `notes: [Note]` and tab state (`openTabIds`, `activeTabId`).
- `isFloating` — global so each window's `TabBarView` can adapt its close/expand buttons.
- Persistence to `~/Library/Application Support/NoteFlow/notes.json`.

`WindowState` is a separate per-`ContentView` `ObservableObject` for *UI* state (sidebar open, search text, formatting toolbar visibility, search-focus request, `viewingTrash`, and the `selectedTag` tag filter). Each `ContentView` instantiates its own with `@StateObject`, so toggling the sidebar in the main window doesn't toggle it in the floating panel.

`Note` is a `Codable` struct. Rich text is stored as RTF `Data`; titles are stored separately on the struct (not auto-extracted at load). It also carries `deletedAt` (non-nil ⇒ trashed), `isPinned`, and `tags: [String]`. A hand-written `init(from:)` decodes missing keys to safe defaults, so `notes.json` written by older versions (which lacked these fields) still loads.

**Trash, pinning, tags.** `deleteNote` is a *soft* delete — it sets `deletedAt` and closes the tab but keeps the note's shared `NSTextStorage` + plain-text cache, so `restoreNote` brings it back intact (including edits not yet re-encoded to RTF). `permanentlyDeleteNote` / `emptyTrash` are the hard deletes that also drop the storage and cache. `togglePin` and `addTag`/`removeTag` round out mutation — tags are normalized to trimmed-lowercase, so `Work` and ` work ` collapse to one. `filteredNotes(matching:tag:)` is the sidebar's list source: it drops trashed notes, applies the optional tag filter + search query (matches title, tags, then cached plain text), and sorts **pinned-first, then `updatedAt` descending**. Trashed notes are reached separately via `trashedNotes` and the sidebar's Trash view.

**Cross-window live editing:** `NoteStore.sharedTextStorage(for: noteId)` returns a single `NSTextStorage` per note ID, reused by every `NSTextView` editing that note. Because an `NSTextStorage` notifies all attached `NSLayoutManager`s on every edit, a keystroke in the main window's editor instantly re-renders in the floating panel's editor (and vice versa) without going through `@Published` or re-encoding RTF. `RichTextEditor` must attach to this shared storage rather than creating its own.

**Plain-text cache for search:** `NoteStore.plainText(for:)` prefers the live `sharedStorages[id].string` (always up-to-date with current keystrokes); otherwise it decodes the persisted RTF once and caches the result in `plainTextCache`. `updateNote` / `deleteNote` invalidate the entry. Avoids re-decoding RTF on every keystroke when the sidebar's search query changes.

### Link title fetching

`LinkTitleFetcher` (in `Models/`) is an `async` helper that downloads a URL and extracts a human-readable title (prefers `<meta property="og:title">`, falls back to `<title>`). It sends a Safari-like `User-Agent` (YouTube/Twitter/etc. return very different HTML otherwise), supports basic HTML-entity decoding, and caches results in-process. Used when the user pastes a URL into the editor.

### Export

`NoteExporter` (in `Models/`) writes a note to **PDF, Word (.docx), Markdown, or plain text**, preserving the editor's formatting. It's reached from the **Export ▸** submenu in the sidebar note-row and tab-chip context menus, which call `NoteStore.exportNote(_:as:)`. The store hands the exporter the note's *live* content via `attributedContent(for:)` — it prefers the shared `NSTextStorage` over the persisted RTF so the export matches on-screen edits even before they're debounce-saved.

- **Plain text** — `attributedString.string`.
- **Word** — `NSAttributedString.data(from:documentAttributes:)` with `.officeOpenXML`, which produces a real `.docx`.
- **Markdown** — a hand-written serializer (`markdown(from:)`) that walks the string line by line: it maps the editor's list prefixes (`• ` → `- `, `1. ` kept verbatim, `☐ ` → `- [ ] `) and wraps each styled run in Markdown emphasis (bold `**`, italic `*`, both `***`, inline-code for fixed-pitch fonts, links `[text](url)`, underline via `<u>`). Surrounding whitespace is moved outside the markers so emphasis renders.
- **PDF** — lays the text out across US-Letter pages with an `NSLayoutManager` (one `NSTextContainer` per page, added until every glyph is placed) and draws each page into a `CGContext` PDF. The page context is created `flipped: true` *and* the CTM is flipped to a top-left origin — both are required or glyphs render upside-down. Theme-default foreground colors are stripped first (via `NoteStore.stripThemeDefaultForegroundColors`) so dark-theme notes don't draw light text on the white page; user-picked colors survive.

`ExportFormat` (same file) is the shared enum of formats, carrying each one's menu label, SF Symbol, file extension, and `UTType` for the save panel. The save panel is shown by `NoteExporter.export(...)`, which calls `NSApp.activate(...)` first so the sheet is front-most even when triggered from the non-activating floating panel.

### Settings

`HotkeyStore.shared` stores `keyCode: UInt32` and `carbonModifiers: UInt32` (Carbon modifier flags — `controlKey`, `optionKey`, `shiftKey`, `cmdKey` — **not** `NSEvent.ModifierFlags`; they differ). `SettingsView` contains `ShortcutRecorderButton`, which installs a temporary local event monitor to capture the next key combo and posts `Notification.Name.hotkeyChanged`.

### View hierarchy

```
NoteFlowApp (@main)
└── AppDelegate
    ├── window (NSWindow)
    │   └── ContentView(inTitledWindow: true)
    │       ├── TabBarView                # Tabs + expand/close + window drag
    │       └── HStack
    │           ├── SidebarIconBar        # Unified rail + labels + notes list + search
    │           └── NoteEditorView        # in RichTextEditor.swift
    │               ├── RichTextEditor    # NSTextView via NSViewRepresentable
    │               ├── TagBar            # removable tag chips + "Add tag…" field
    │               └── FormattingToolbarView  # shown when WindowState.formattingVisible
    └── floatingPanel (FloatingPanel/NSPanel)
        └── ContentView(isFloatingPanel: true)   # Same component, separate WindowState, same NoteStore.shared
```

The close button in `TabBarView` checks `store.isFloating`: if `true` it calls `AppDelegate.toggleFloating()` (dismiss panel); otherwise it closes the main window. `NoteListPanel.swift` only defines `NoteRow` now — the panel itself is folded into `SidebarIconBar`.

### Appearance & theming

`ThemeStore.shared` (singleton `ObservableObject`, in `Models/Theme.swift`) holds `mode: .light | .dark`, persisted to `UserDefaults` under `themeMode`. Its `palette` returns a `Palette` value that bundles every named color **twice** — a SwiftUI `Color` for SwiftUI views and the matching `NSColor` for AppKit chrome — plus the `NSAppearance.Name` (`.aqua` / `.darkAqua`) and `ColorScheme` for that mode. Light is the cream/white scheme (`#F0F0EA` chrome); dark is near-pure black with a single hairline divider. There is **no longer** a hard-coded `.aqua` pin.

Two propagation paths, because SwiftUI and AppKit observe differently:
- **SwiftUI views** read `theme.palette.*` via `@EnvironmentObject var theme: ThemeStore` and re-render automatically when `mode` changes.
- **AppKit objects** (`NSWindow`/`NSPanel` chrome, the `NSTextView`) can't observe `@Published`, so they subscribe to `Notification.Name.themeChanged`, which `mode`'s `didSet` posts. `AppDelegate.applyTheme()` repaints both windows' background + appearance; `RichTextEditor` re-applies the palette to its text view via `applyPalette(...)`.

The Settings toggle (`SettingsView`, hosted by the `Settings { }` scene in `NoteFlowApp`) just flips `theme.isDark`.

**Gotcha — theme-default foreground stripping.** Light body text is black; dark body text is ~0.91 white. Either gets baked into the RTF / typing attributes as an explicit `.foregroundColor`, so after a theme flip that color would render invisible against the new background. `NoteStore.stripThemeDefaultForegroundColors` removes only foreground colors that match a theme default (within a small tolerance), leaving user-picked colors from the Text Formatting picker intact. It runs when a shared storage is first built (`sharedTextStorage`) and across every live storage on each `themeChanged`. If you add a new default text color, add it to `NoteStore.themeDefaultColors` or it will get stranded on theme switches.

The Dock icon is set in-process via `NSApp.applicationIconImage = AppLogo.processed` (in `Models/AppLogo.swift`). This is necessary because `swift run` launches a bare executable — there's no `.icns` in an `.app` bundle to pick up — so the icon is regenerated on every launch. The packaged `.app` from `make-dmg.sh` still uses a real `AppIcon.icns`.
