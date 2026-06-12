# Typing Latency — Design

**Date:** 2026-06-12
**Goal:** Typing in NoteFlow should feel as immediate as Apple Notes / Obsidian: no
per-keystroke lag that grows with note length, and no stutter when the debounced
save fires. Latency only — no visual/typography changes.

## Problem

1. **Per-keystroke full-document layout.** `NoteTextView.didChangeText` calls
   `NSLayoutManager.ensureLayout(for: textContainer)`, which lays text out from the
   edit point to the end of the note on every keystroke — O(note length). It was
   added to fix two real glitches (text clipped below a mid-note paste; a "ghost"
   caret gap after backspace), but it is a sledgehammer: those glitches only concern
   what is on screen.
2. **Synchronous save hitch.** 0.6 s after typing pauses, `NoteStore.flushPendingSaves()`
   RTF-encodes the whole note and rewrites `notes.json`, all on the main thread.
   On long notes this stutters exactly when the user resumes typing.

## Decisions

- **Bounded layout, staying on TextKit 1.** Per keystroke, lay out only (a) the
  caret's line (preserves the backspace fix) and (b) the visible viewport
  (preserves the clipping fix), then redraw. Text below the viewport is laid out
  lazily by AppKit idle-time background layout, as in any large NSTextView document.
  `paste()` keeps its existing full-layout pass (rare event, self-contained).
  - *Rejected:* `allowsNonContiguousLayout` (known AppKit glitches with
    NSTextTable — NoteFlow ships tables — and custom layout managers).
  - *Rejected:* TextKit 2 migration (no NSTextTable support; full editor rewrite).
- **Background RTF encode for the debounce path.** The debounce timer calls a new
  `flushPendingSavesInBackground()`: snapshot dirty storages on main (cheap
  `NSAttributedString` copy) → encode RTF on a utility queue → apply + `save()`
  back on main. The JSON write stays synchronous on main (cheap relative to encode;
  preserves quit-ordering guarantees).

### Data-safety invariants (save path)

1. Dirty note ids are **not** cleared until their encoded data is applied on main,
   so the synchronous flush (app switch / quit) can never miss in-flight edits.
2. A per-note **edit generation counter** (bumped each keystroke) detects edits that
   land during encoding: the note stays dirty and the re-armed timer re-encodes.
   The stale snapshot is still applied — newer than disk, older than live; harmless.
3. `flushPendingSaves()` (sync) keeps its exact current semantics and remains the
   path for `applicationWillResignActive` / `applicationWillTerminate`.
4. If a sync flush races ahead of an in-flight encode, the late apply is skipped
   (dirty mark already cleared), so older data never clobbers newer.

## Testing

- `typingDoesNotForceFullDocumentLayout` (red first): `NoteTextView` in a 500×600
  scroll view over a 5,000-line document; one `insertText` at the top; assert
  `firstUnlaidCharacterIndex() < length`. Fails under the current forced full layout.
- `backgroundFlushPersistsEdits` (red first): edit a note's shared storage, run the
  background flush, await its completion, decode the persisted RTF, compare strings.
- The existing 9 tests must stay green, unmodified.
- Manual: type in a very long note (smooth), tables render, paste still scrolls
  the caret into view.

## Out of scope

Typography/line-spacing changes; moving the JSON write off-main; TextKit 2.
