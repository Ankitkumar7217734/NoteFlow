# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

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

# Run the tests (Swift Testing, in Tests/NoteFlowTests)
bash scripts/test.sh

# Run a single test / suite — args pass through to `swift test`
bash scripts/test.sh --filter PanelTests
bash scripts/test.sh --filter allFourDefaultInksAreStripped
```

After changing `AppDelegate.swift`, kill the running process and relaunch — `swift run` does not hot-reload.

`scripts/make-dmg.sh` does `swift build -c release`, assembles a `.app` bundle (Info.plist + AppIcon.icns generated from `Sources/NoteFlow/Resources/logo.png` via `sips`/`iconutil`), renders the DMG background via `scripts/make-background.swift`, and styles the volume window with AppleScript. No lint tooling is configured.

Tests use **Swift Testing** (`import Testing`, `@Test`/`#expect`) in `Tests/NoteFlowTests`. Run them with `bash scripts/test.sh`, **not** plain `swift test` — on a Command Line Tools-only machine (no full Xcode) the Testing framework lives outside the default search paths and `swift test` fails with "no such module 'Testing'"; the script adds the required `-F`/`-rpath` flags and falls back to plain `swift test` when they're not needed. Tests inject a temp-dir save URL via `NoteStore(saveURL:)` so they never touch the real `notes.json`.

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

The panel's full configuration lives in **`FloatingPanel.init(contentSize:)`** (not in AppDelegate) so it's pinned by `PanelTests.floatingPanelKeepsItsLoadBearingConfiguration`:
- Style mask: `[.nonactivatingPanel, .resizable, .fullSizeContentView]`. `.nonactivatingPanel` is what lets the panel become key without activating the app (preventing the Space switch above).
- `level = .screenSaver` and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` so it overlays full-screen apps on every Space. **Ordering gotcha:** `isFloatingPanel = true` must be set *before* `level` — setting it resets the level to `.floating`(3), which silently undid `.screenSaver` for the app's entire prior history until the pin test caught it.
- `backgroundColor = .clear`, `isOpaque = false`, and the hosting view's `CALayer` has `cornerRadius = 14` / `masksToBounds = true` to produce rounded corners without a title bar.

**Panel fluidity (`PanelSettings`, in `Models/`):** singleton ObservableObject persisting `opacity` (0.5–1.0 floor — an invisible panel would still swallow keystrokes; Settings slider, applied live via `.panelOpacityChanged`, entrance animation fades to it) and `panelSize` (saved on live-resize end, reused re-centered on every summon). **Gotcha:** `opacity` is a clamping *computed* setter over `@Published private var storedOpacity` — do not refactor the clamp into a `didSet` on the `@Published` var; re-reading/re-assigning a `@Published` property inside its own observer re-enters Combine's enclosing-instance subscript and crashes the Swift runtime.

**Compact panel layout:** in the floating panel, `ContentView` hides the sidebar rail entirely and `NoteEditorView`/`RichTextEditor` take `compact: true` (text insets 14pt instead of 28pt, tighter editor margins), so ~440pt of the 520pt default width is text. The tab bar shows an **AA** formatting toggle only in the panel (the rail that normally hosts it is hidden); new-note stays via the tab bar's +.

**`FloatingPanel` exists specifically to override `canBecomeKey`/`canBecomeMain` to return `true`.** A title-bar-less `.nonactivatingPanel` would otherwise refuse to become key, and `NSTextView` inside it would silently drop keystrokes. Both flags are required — don't remove either.

`expandToFull()` is the inverse path: hides the panel, brings the main window forward, and explicitly calls `NSApp.activate(ignoringOtherApps: true)` (Space switch is desired here).

### Global hotkey

Registered via Carbon `RegisterEventHotKey` (not `NSEvent.addGlobalMonitorForEvents`, which requires Accessibility permission). The user-configurable config lives in `HotkeyStore` (persisted to `UserDefaults` as `hotkeyKeyCode` / `hotkeyModifiers`). When the user changes the shortcut in Settings, a `Notification.Name.hotkeyChanged` notification triggers `AppDelegate.reRegisterHotkey()`, which unregisters both hotkeys and re-registers the primary plus the fixed ⌃⇧D fallback.

### State & Persistence

`NoteStore` (singleton `ObservableObject`) is the single source of truth for *data*. It owns:
- `notes: [Note]` and tab state (`openTabIds`, `activeTabId`).
- `isFloating` — global so each window's `TabBarView` can adapt its close/expand buttons.
- Persistence to `~/Library/Application Support/NoteFlow/notes.json`. If that file exists but fails to decode at launch, it is moved aside as `notes.json.corrupt-<timestamp>` (never overwritten) before a fresh store is created.

`WindowState` is a separate per-`ContentView` `ObservableObject` for *UI* state (sidebar open, search text, formatting toolbar visibility, search-focus request, `viewingTrash`, and the `selectedTag` tag filter). Each `ContentView` instantiates its own with `@StateObject`, so toggling the sidebar in the main window doesn't toggle it in the floating panel.

`Note` is a `Codable` struct. Rich text is stored as RTF `Data`; titles are stored separately on the struct (not auto-extracted at load). It also carries `deletedAt` (non-nil ⇒ trashed), `isPinned`, and `tags: [String]`. A hand-written `init(from:)` decodes missing keys to safe defaults, so `notes.json` written by older versions (which lacked these fields) still loads.

**External-writer live sync (MCP).** A local MCP server (and anything else) may rewrite `notes.json` while the app is running. `NoteStore` watches the store *directory* (a `DispatchSourceFileSystemObject` on `.write` — the file itself can't be watched because external writers replace it via temp-file + rename, which would orphan an inode-bound watch), debounces events 0.25 s, and calls `reloadFromDiskIfExternallyChanged()`. That method hashes the file bytes (SHA-256, `lastAccountedDiskHash`) and no-ops when disk holds what we last wrote/merged — so the app's own saves never trigger a reload loop. On a real external change it runs a **three-way merge** (`applyExternalNotes`, base = `lastSyncedNotes` snapshot recorded on every load/save/merge): notes with unflushed keystrokes (`pendingDirtyNoteIds`) always keep the local version; disk-only changes win and are pushed into the note's live shared `NSTextStorage` (`refreshLiveContent`, running the same normalization pipeline as `sharedTextStorage` and restoring each attached editor's selection clamped), so open editors re-render instantly; changed-in-both resolves by newer `updatedAt`; local-only notes are never dropped. **`save()` calls `reloadFromDiskIfExternallyChanged()` first** — a local write can race ahead of the debounced watcher, and skipping the merge would clobber the external change with stale memory; the one subtlety is permanent deletes, which the merge detects (on disk + in base + gone from memory ⇒ deliberate local delete) and does *not* resurrect. `applicationDidBecomeActive` re-checks as a belt-and-braces. Covered by `Tests/NoteFlowTests/ExternalSyncTests.swift`, including a pin of the Python MCP server's exact JSON shape (float Apple-epoch dates, base64 RTF, uppercase UUIDs — all of which Swift's default `Codable` handles). `Note` is `Equatable` specifically for this merge.

**Debounced persistence.** Typing never writes to disk synchronously. `RichTextEditor`'s delegate calls `NoteStore.noteBodyDidChange(_:)` on every keystroke, which marks the note id dirty and (re)arms a 0.6 s timer (`saveDebounceInterval`) instead of encoding RTF + writing `notes.json` each time — the shared `NSTextStorage` holds the live text in the meantime, so nothing is lost. When the timer fires, `flushPendingSavesInBackground()` snapshots each dirty note's storage on the main thread, RTF-encodes on a background queue (the expensive part — encoding on main caused a typing hitch), and applies + persists back on main. Dirty ids stay marked until the encoded data is applied, and a per-note edit-generation counter keeps a note dirty if the user typed during the encode, so nothing is ever skipped or clobbered. The fully synchronous `flushPendingSaves()` remains; `AppDelegate` calls it on `applicationWillResignActive` / `applicationWillTerminate` so the last keystrokes survive an app switch or quit. `updateNote` is the separate immediate-write path used for title / metadata edits.

**Trash, pinning, tags.** `deleteNote` is a *soft* delete — it sets `deletedAt` and closes the tab but keeps the note's shared `NSTextStorage` + plain-text cache, so `restoreNote` brings it back intact (including edits not yet re-encoded to RTF). `permanentlyDeleteNote` / `emptyTrash` are the hard deletes that also drop the storage and cache. `togglePin` and `addTag`/`removeTag` round out mutation — tags are normalized to trimmed-lowercase, so `Work` and ` work ` collapse to one. `filteredNotes(matching:tag:)` is the sidebar's list source: it drops trashed notes, applies the optional tag filter + search query (matches title, tags, then cached plain text), and sorts **pinned-first, then `updatedAt` descending**. Trashed notes are reached separately via `trashedNotes` and the sidebar's Trash view.

**Cross-window live editing:** `NoteStore.sharedTextStorage(for: noteId)` returns a single `NSTextStorage` per note ID, reused by every `NSTextView` editing that note. Because an `NSTextStorage` notifies all attached `NSLayoutManager`s on every edit, a keystroke in the main window's editor instantly re-renders in the floating panel's editor (and vice versa) without going through `@Published` or re-encoding RTF. `RichTextEditor` must attach to this shared storage rather than creating its own.

**Plain-text cache for search:** `NoteStore.plainText(for:)` prefers the live `sharedStorages[id].string` (always up-to-date with current keystrokes); otherwise it decodes the persisted RTF once and caches the result in `plainTextCache`. `updateNote` / `deleteNote` invalidate the entry. Avoids re-decoding RTF on every keystroke when the sidebar's search query changes.

**Paragraph-style + whitespace normalization.** Pasted content (and old notes built from such pastes) carries foreign `NSParagraphStyle` data — first-line / head indents, custom tab stops, non-natural alignment — that makes consecutive lines start at different left positions. `NoteStore.normalizeParagraphStyles` resets every paragraph to a clean left-aligned (`.natural`) default, flattening all **horizontal** layout (first-line/head/tail indents, tab stops) — the misalignment bug it exists for is purely horizontal — while **preserving `textBlocks`** so tables keep their layout (the app's own lists are plain-text prefixes, so nothing else depends on paragraph indentation). It takes a `preserveVerticalSpacing` flag: the paste path (`RichTextEditor.sanitize`) keeps the default `false` (full flatten, unchanged), but `sharedTextStorage` passes `true`, which carries over **vertical** metrics (`paragraphSpacing`, `paragraphSpacingBefore`, `lineSpacing`) clamped to sane maxima (12/12/8) so imported Markdown notes keep their heading/body/list rhythm across reopens without legacy foreign pastes producing huge gaps. `NoteStore.normalizeWhitespace` runs alongside it: it collapses runs of 2+ *interior* spaces to one and folds non-breaking / exotic spaces into a regular space, so doubled spaces (common in PDF/Word pastes) don't leave a stray leading space when a paragraph soft-wraps — leading-line indentation is preserved. Both run on paste (`RichTextEditor.sanitize`) and when a note's shared storage is first built (`sharedTextStorage`), so existing notes render straight on next open.

### Editor, typography & formatting

`RichTextEditor` is an `NSViewRepresentable` wrapping `NoteTextView` (an `NSTextView` subclass). It attaches to the note's shared `NSTextStorage` (see *Cross-window live editing*) rather than owning its own text.

- **Default body size.** `EditorTypography.baseFontSize` (currently **14 pt**) is the canonical size, used by the text view's typing attributes, paste sanitization, inline-code, and table cells. New notes type at this size; existing notes keep whatever size is baked into their RTF.
- **Paste sanitization.** `RichTextEditor.sanitize` strips foreign styling (background colors, shadows, stroke/expansion/obliqueness), replaces baked foreground colors with `Palette.dynamicInkNS` (so pasted text renders in the theme ink and auto-adapts — see the theming gotchas), and rewrites every run's font to the base family **preserving bold / italic / mono traits**, then runs the paragraph-style + whitespace normalizers. `autoLink` linkifies URLs in the pasted text afterward.
- **Keyboard + lists.** There's no SwiftUI Format menu, so `NoteTextView.performKeyEquivalent` intercepts `⌘B` / `⌘I` / `⌘U` (and shifted variants) directly; `insertNewline` auto-continues list prefixes (`• `, incrementing `1. `, `☐ `).
- **Typing performance / layout mode.** `NoteLayoutManager` defaults to `allowsNonContiguousLayout = true` so un-laid text height is *estimated* — without it, NSTextView's fit-to-content sizing forces a full-document layout on **every keystroke** (typing slows as a note grows). `didChangeText` forces layout for only the caret's line + visible viewport. **Exception:** notes containing an `NSTextTable` run in contiguous mode (NSTextTable glitches under non-contiguous layout); this is enforced at note open (`makeNSView`), on paste of table content, and on toolbar table insert via `NoteTextView.containsTables` / `disableNonContiguousLayout`. Don't re-add a full `ensureLayout(for:)` to `didChangeText`, and route any new table-insertion path through the same disable call.
- **Font-size control.** `FormattingToolbarView` has a font-size popover (−/+ stepper + presets) that resizes the selection — or the typing attributes when nothing is selected — via `NSFontManager.convert(_:toSize:)`, preserving traits. The toolbar's link / table / color / font-size popovers all **capture the text view + selection before presenting** (`savedTextView` / `savedRange`), because presenting a popover takes first responder and clears the live selection.

### Link title fetching

`LinkTitleFetcher` (in `Models/`) is an `async` helper that downloads a URL and extracts a human-readable title (prefers `<meta property="og:title">`, falls back to `<title>`). It sends a Safari-like `User-Agent` (YouTube/Twitter/etc. return very different HTML otherwise), supports basic HTML-entity decoding, and caches results in-process. Used when the user pastes a URL into the editor.

### Export

`NoteExporter` (in `Models/`) writes a note to **PDF, Word (.docx), Markdown, or plain text**, preserving the editor's formatting. It's reached from the **Export ▸** submenu in the sidebar note-row and tab-chip context menus, which call `NoteStore.exportNote(_:as:)`. The store hands the exporter the note's *live* content via `attributedContent(for:)` — it prefers the shared `NSTextStorage` over the persisted RTF so the export matches on-screen edits even before they're debounce-saved.

- **Plain text** — `attributedString.string`.
- **Word** — `NSAttributedString.data(from:documentAttributes:)` with `.officeOpenXML`, which produces a real `.docx`.
- **Markdown** — a hand-written serializer (`markdown(from:)`) that walks the string line by line: it maps the editor's list prefixes (`• ` → `- `, `1. ` kept verbatim, `☐ ` → `- [ ] `) and wraps each styled run in Markdown emphasis (bold `**`, italic `*`, both `***`, inline-code for fixed-pitch fonts, links `[text](url)`, underline via `<u>`). Surrounding whitespace is moved outside the markers so emphasis renders.
- **PDF** — lays the text out across US-Letter pages with an `NSLayoutManager` (one `NSTextContainer` per page, added until every glyph is placed) and draws each page into a `CGContext` PDF. The page context is created `flipped: true` *and* the CTM is flipped to a top-left origin — both are required or glyphs render upside-down. Theme-default foreground colors are stripped first (via `NoteStore.stripThemeDefaultForegroundColors`) so dark-theme notes don't draw light text on the white page; user-picked colors survive.

PDF and Word exports re-base default body text to **10 pt** via `normalizingFontSizes`: it maps runs at a *default* body size (the current 14 pt editor default or the legacy 15 pt old notes were written at) to 10 pt while preserving family / traits, and leaves any size the user explicitly picked from the Font Size control untouched. (Markdown and plain text carry no font size.)

`ExportFormat` (same file) is the shared enum of formats, carrying each one's menu label, SF Symbol, file extension, and `UTType` for the save panel. The save panel is shown by `NoteExporter.export(...)`, which calls `NSApp.activate(...)` first so the sheet is front-most even when triggered from the non-activating floating panel.

### Import

`NoteImporter` (in `Models/NoteImporter.swift`) is the inverse of the exporter: it turns a **Markdown or plain-text** file back into rich text using NoteFlow's own editor conventions, so an imported file looks identical to one typed in the app. Reached from the sidebar's import action (`NoteStore.importFiles()`), which shows a multi-select `NSOpenPanel` (constrained to `ImportFormat.allowedContentTypes`) and creates one new note per file via `addNote`; unreadable files are collected and surfaced afterward without aborting the rest. Like the exporter it calls `NSApp.activate(...)` first so the panel is front-most from the floating panel.

- `ImportFormat` maps file extensions (`md`/`markdown`/… → `.markdown`, `txt`/`text` → `.plainText`, anything else falls back to plain text).
- **`MarkdownParser`** (same file) is the hand-written Markdown→`NSAttributedString` renderer: ATX headings (`#`–`######`) become bold at descending sizes (`headingSizes` = `[24,20,17,15.5,14,13]`), list markers map to the editor's prefixes (`- `/`* ` → `• `, `N.` kept, `- [ ]` → `☐ `), blockquotes render as a `▎ ` bar marker + italic body (the exporter maps `▎ ` back to `> `), fenced code blocks render literal + monospaced, and inline `**bold**` / `*italic*` / `` `code` `` / `[text](url)` are applied per-run. All text uses `EditorTypography.baseFont` + `Palette.dynamicInkNS`, so imported notes obey theming like any other. The entry point walks lines as `Block` values (`.line` joined by newlines, `.table` appended verbatim).
- **GFM tables** (`buildTable` / `tableDelimiterAlignments` / `splitTableRow`) parse a header + delimiter (`| :- | -: |`) + body rows into a real **`NSTextTable`**, mirroring the editor's own `FormattingToolbarView.insertTable` (per-cell `NSTextTableBlock` paragraphs, header background + bold, 1pt border, 8pt padding, a trailing default paragraph that closes the table). So an imported table is the *same* object the editor draws — `NoteTextView.containsTables` then flips the note to contiguous layout on open. Detection needs a pipe in both the row and the delimiter (so a lone `---` stays a rule), and `\|` is a literal in-cell pipe. Column alignment is preserved through note-open because `normalizeParagraphStyles` keeps `alignment` for `textBlocks` paragraphs.
- **Formatting that survives the pipeline.** To look good, the parser styles only with attributes that survive `addNote`'s RTF round-trip *and* `sharedTextStorage`'s normalization. **Paragraph styles** (per-block `lineSpacing` / `paragraphSpacing` / heading `paragraphSpacingBefore`, plus a *zeroed* style on blank lines so gaps don't double) give vertical rhythm — they survive because `normalizeParagraphStyles` is called with `preserveVerticalSpacing: true` on note-open (see *Paragraph-style normalization*). Each block's terminating newline carries that block's paragraph style so the paragraph isn't mixed. **Code** (inline + fenced) gets a translucent `.backgroundColor` (`NSColor(white:0.5, alpha:0.22)`) — a character attribute nothing strips, composited over the live editor background so it adapts to theme, drawn rounded by `NoteLayoutManager`. Horizontal indents are deliberately *not* used (the normalizer zeroes them); list/quote structure rides on glyph prefixes instead. Covered by `Tests/NoteFlowTests/MarkdownImportTests.swift`.

### Settings

`HotkeyStore.shared` stores `keyCode: UInt32` and `carbonModifiers: UInt32` (Carbon modifier flags — `controlKey`, `optionKey`, `shiftKey`, `cmdKey` — **not** `NSEvent.ModifierFlags`; they differ). `SettingsView` contains `ShortcutRecorderButton`, which installs a temporary local event monitor to capture the next key combo and posts `Notification.Name.hotkeyChanged`. Combos are converted/validated by `HotkeyStore.carbonModifiers(from:)`, which returns `nil` for shift-only or modifier-less combos — registering those globally would swallow normal typing system-wide, so the recorder keeps listening until a combo with ⌃/⌥/⌘ arrives.

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

`TabBarView`'s `isFloatingPanel` flag routes the close button: in the panel it calls `AppDelegate.toggleFloating()` (dismiss + restore previous app); in the main window it closes the window. The expand-to-full button renders **only in the floating panel** — it dismisses the panel and activates the main window; in the main window it would be a no-op. `NoteListPanel.swift` only defines `NoteRow` now — the panel itself is folded into `SidebarIconBar`.

### Appearance & theming

`ThemeStore.shared` (singleton `ObservableObject`, in `Models/Theme.swift`) holds `mode: .light | .dark`, persisted to `UserDefaults` under `themeMode`. Its `palette` returns a `Palette` value that bundles every named color **twice** — a SwiftUI `Color` for SwiftUI views and the matching `NSColor` for AppKit chrome — plus the `NSAppearance.Name` (`.aqua` / `.darkAqua`) and `ColorScheme` for that mode. Both palettes follow the **"Paper & Ink"** scheme, tuned for long writing sessions (body-text contrast in the ~9–16:1 comfort band, enforced by tests in `ThemeTests.swift`): light keeps the cream chrome identity with a paper-tinted editor (`#FCFBF8`) and warm near-black ink (`#2C2A26`); dark is layered warm graphite — chrome `#151412`, editor lifted to `#1D1C19` — with soft warm-white ink (`#DAD7D1`). There is **no longer** a hard-coded `.aqua` pin.

**Theme switch cross-fade.** `ThemeStore.mode` posts `themeWillChange` from `willSet` *before* the mode mutates; `AppDelegate.prepareThemeCrossFade` snapshots every visible window's content view into an identifier-tagged `NSImageView` overlay while it still shows the old theme. `applyTheme` (on `themeChanged`) repaints underneath and fades the overlays out over 0.28 s. The early signal exists because observer order on `themeChanged` is not guaranteed — snapshotting there would race the repaints.

Two propagation paths, because SwiftUI and AppKit observe differently:
- **SwiftUI views** read `theme.palette.*` via `@EnvironmentObject var theme: ThemeStore` and re-render automatically when `mode` changes.
- **AppKit objects** (`NSWindow`/`NSPanel` chrome, the `NSTextView`) can't observe `@Published`, so they subscribe to `Notification.Name.themeChanged`, which `mode`'s `didSet` posts. `AppDelegate.applyTheme()` repaints both windows' background + appearance; `RichTextEditor` re-applies the palette to its text view via `applyPalette(...)`.

The Settings toggle (`SettingsView`, hosted by the `Settings { }` scene in `NoteFlowApp`) just flips `theme.isDark`.

**Gotcha — theme-default foreground stripping.** The editor's default text color is `Palette.dynamicInkNS` (a named dynamic `NSColor` resolving to `Palette.lightInkNS` `#2C2A26` / `Palette.darkInkNS` `#DAD7D1` per appearance — same mechanism as `NSColor.textColor`). Whichever ink is current gets baked into the RTF / typing attributes as an explicit `.foregroundColor`, so after a theme flip that color would render invisible against the new background. `NoteStore.stripThemeDefaultForegroundColors` removes only foreground colors that match a theme default (within a small tolerance), leaving user-picked colors from the Text Formatting picker intact. It runs when a shared storage is first built (`sharedTextStorage`) and across every live storage on each `themeChanged`. `NoteStore.themeDefaultColors` has **four** entries — legacy black, legacy `0.91` white (pre-Paper & Ink notes), and both current inks. If you change a default ink, add the new value to that list *and keep the old ones* or existing notes' text gets stranded on theme switches (guarded by `allFourDefaultInksAreStripped` in `ThemeTests.swift`).
**Gotcha — never set `textView.textColor` / `textView.font` on an editor whose shared storage is attached.** NSText's setters apply to *every character in the storage*: a single `textView.textColor = …` in editor construction silently flattened all user-picked and MCP-written colors to the theme ink on every note open (colored notes rendered mono-white in dark mode). Editor construction lives in `RichTextEditor.buildEditor(storage:compact:)` — static and coordinator-free so `ColorPreservationTests` can pin the invariant that building an editor never rewrites storage colors. Rendering doesn't need a view-level color: every run carries an explicit `.foregroundColor` (`NoteStore.replaceThemeDefaultForegroundColors` also fills runs that have *none* — AppKit renders attribute-less text black in both themes, not in `textColor`), and `typingAttributes` supplies the dynamic ink for new typing.

The Dock icon is set in-process via `NSApp.applicationIconImage = AppLogo.processed` (in `Models/AppLogo.swift`). This is necessary because `swift run` launches a bare executable — there's no `.icns` in an `.app` bundle to pick up — so the icon is regenerated on every launch. The packaged `.app` from `make-dmg.sh` still uses a real `AppIcon.icns`.
