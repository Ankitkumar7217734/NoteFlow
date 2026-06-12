import Testing
import AppKit
import Carbon
@testable import NoteFlow

// A global hotkey must include at least one "real" modifier (⌃ ⌥ ⌘).
// Shift-only combos are rejected: registering e.g. ⇧S with Carbon would
// swallow every capital S typed in any app, system-wide.

@Test func shiftOnlyComboIsRejected() {
    #expect(HotkeyStore.carbonModifiers(from: [.shift]) == nil)
}

@Test func emptyModifiersAreRejected() {
    #expect(HotkeyStore.carbonModifiers(from: []) == nil)
}

@Test func optionComboIsAccepted() {
    #expect(HotkeyStore.carbonModifiers(from: [.option]) == UInt32(optionKey))
}

@Test func controlShiftComboIsAccepted() {
    #expect(HotkeyStore.carbonModifiers(from: [.control, .shift])
            == UInt32(controlKey | shiftKey))
}

@Test func commandComboIsAccepted() {
    #expect(HotkeyStore.carbonModifiers(from: [.command]) == UInt32(cmdKey))
}

@Test func allModifiersMapToAllCarbonBits() {
    #expect(HotkeyStore.carbonModifiers(from: [.control, .option, .shift, .command])
            == UInt32(controlKey | optionKey | shiftKey | cmdKey))
}
