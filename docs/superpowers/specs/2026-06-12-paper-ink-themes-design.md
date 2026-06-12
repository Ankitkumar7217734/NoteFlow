# Paper & Ink Themes + Theme Cross-Fade — Design

**Date:** 2026-06-12
**Goal:** Make both themes comfortable for long writing sessions and make the
light/dark switch a smooth cross-fade instead of a hard cut. User-reported
problem: pure-white-on-`#000000` dark mode and pure-black-on-`#FFFFFF` light
mode are harsh enough that writing doesn't feel inviting.

## Direction (user-approved): Paper & Ink

Body-text contrast moves from the extremes (17.7:1 dark, 21:1 light) into the
long-form comfort band (~9:1–16:1), with layered surfaces instead of flat
single-color backgrounds.

### Dark — warm graphite

| Slot | Value |
|---|---|
| chrome / sidebar | `#151412` |
| editor surface (lifted) | `#1D1C19` |
| body ink | `#DAD7D1` (~11.9:1 on editor) |
| secondary text | `#8E8B85` (~5:1) |
| divider | `#2A2925` |
| link | `#6FA8E8` |
| selection | `#4A78C2` @ 35% |
| search highlight | amber @ 30% |
| table border / header | `#3A3833` / `#26251F` |

### Light — paper

| Slot | Value |
|---|---|
| chrome / sidebar | cream `#F0EFEA` (identity kept) |
| editor surface | paper `#FCFBF8` (not stark white) |
| body ink | `#2C2A26` (~13.8:1 on editor) |
| secondary text | `#6F6C65` (~5:1) |
| divider | black @ 9% |
| link | `#2667C9` |
| selection | `#3E76D6` @ 20% |
| search highlight | amber @ 45% |
| table border / header | `#CFCCC4` / `#F1EFE9` |

Icons, active row/tab backgrounds, search field, and the Copy button move to
the same warm-neutral family in both modes.

## Default-ink migration (data safety)

The editor's default text color changes from semantic `NSColor.textColor` to a
custom dynamic color (`NSColor(name:dynamicProvider:)`) resolving to the two
inks per appearance — same auto-adapting mechanism, NoteFlow's colors.

**Critical:** `NoteStore.themeDefaultColors` grows from 2 to 4 entries — legacy
black, legacy `white: 0.91`, light ink `#2C2A26`, dark ink `#DAD7D1` — so RTF
baked under either old or new defaults keeps adapting across theme flips
(strip-on-load + strip-on-themeChanged), and PDF export keeps stripping
correctly. User-picked colors are untouched. This is the documented CLAUDE.md
gotcha; missing it strands text invisible after a flip.

## Transition: snapshot cross-fade

`ThemeStore.mode` gains a `themeWillChange` notification posted from `willSet`
(before any observer repaints — observer order on `themeChanged` is not
guaranteed, so the snapshot must be taken on a separate, earlier signal).
`AppDelegate` on `themeWillChange`: for every visible window, snapshot the
content view into an `NSImageView` overlay (identifier-tagged; any in-flight
overlay from a rapid double-toggle is removed first). On `themeChanged`: apply
the theme as today, then fade each overlay out over 0.28 s (ease-out) and
remove it. One image fading means SwiftUI views, the NSTextView, and window
chrome all transition in sync.

## Tests (red first)

- **Contrast band:** WCAG contrast computed from `Palette.light` / `Palette.dark`:
  body ink vs editor surface within 9:1–16:1; secondary text vs its surface
  ≥ 4.5:1. Current palettes fail (encodes the complaint); new ones pass.
- **Ink migration:** `stripThemeDefaultForegroundColors` strips all four
  default inks; preserves a user-picked red.
- Transition is verified manually in the running app (visual).

## Out of scope

Follow-system (auto) theme mode; accent-color setting; typography changes.
