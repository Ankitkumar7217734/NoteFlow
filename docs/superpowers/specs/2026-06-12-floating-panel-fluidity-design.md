# Floating Panel Fluidity — Design

**Date:** 2026-06-12
**Goal:** Make the floating panel feel fluid: user-adjustable transparency,
maximum space for text (the panel currently spends ~125pt of its 520pt width
on chrome), remembered size, and regression tests pinning the panel's
load-bearing configuration.

## Decisions (user-approved)

1. **Opacity slider** in Settings ▸ Floating Panel: whole-panel opacity,
   50–100% (floor prevents an effectively-invisible panel that still swallows
   keystrokes), default 100%, applied live while the panel is open, persisted.
2. **Max-text panel layout**: in the floating panel only — the sidebar rail
   and its divider are hidden, text-container insets drop 28→14pt per side,
   outer editor margins tighten (12/16/16 → 6/8/8 + 8 leading). Because the
   rail held the Text Formatting toggle, the panel's tab bar gains an **AA**
   button (panel only). New note stays available via the tab bar's +.
   The main window layout is unchanged (`compact` is a threaded parameter).
3. **Size memory**: the panel's last size is persisted (across shows and
   launches; saved on live-resize end) and reused on summon; the panel still
   re-centers on the current screen. Fixes the every-show reset to 520×535.

## Components

- **`PanelSettings`** (new, HotkeyStore pattern): singleton `ObservableObject`
  with `opacity` (`@Published`, clamped 0.5–1.0, posts `.panelOpacityChanged`)
  and `panelSize` (computed, UserDefaults-backed, sanity floor 200×150 →
  default 520×535). Injectable `UserDefaults` for test isolation.
- **`FloatingPanel.init(contentSize:)`**: all panel configuration moves from
  the private `AppDelegate.setupFloatingPanel` into a testable initializer —
  style mask (`.nonactivatingPanel, .resizable, .fullSizeContentView`),
  `level = .screenSaver`, `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary]`, `hidesOnDeactivate = false`, non-opaque/clear,
  `worksWhenModal`. `canBecomeKey/Main` overrides stay.
- **AppDelegate**: show path uses `PanelSettings.panelSize` and fades the
  entrance animation to `PanelSettings.opacity` (was hard-coded 1.0);
  observes `didEndLiveResizeNotification` (panel) → save size; observes
  `.panelOpacityChanged` → apply live when visible.
- **ContentView / NoteEditorView / RichTextEditor**: `isFloatingPanel` hides
  the rail; `compact: Bool` parameter reduces insets. **TabBarView**: AA
  toggle bound to `WindowState.formattingVisible`, shown only in the panel.
- **SettingsView**: Opacity slider row (50–100%, live percentage label).

## Safety review findings (pre-existing, addressed here)

- Panel invariants (the "don't remove either" overrides, non-activating
  style, Space behavior flags) had zero test coverage and were untestable
  while buried in a private method — fixed by the testable initializer +
  pin tests.
- Panel size was reset to 520×535 on every show — fixed by size memory.
- Dismiss/restore paths and Space-preservation logic reviewed: sound.

## Tests (red first)

- `floatingPanelKeepsItsLoadBearingConfiguration`: asserts every flag above
  plus `canBecomeKey`/`canBecomeMain` on `FloatingPanel(contentSize:)`.
- `PanelSettings`: opacity clamping (0.3→0.5, 1.4→1.0), opacity persistence
  across instances, size persistence round-trip + garbage rejection — all in
  an isolated `UserDefaults` suite.
- Layout, slider feel, and live opacity are visual — manual verification.

## Out of scope

Frosted-glass (blur) transparency; panel position memory (still re-centers);
main-window layout changes.
