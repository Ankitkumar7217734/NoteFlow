import SwiftUI
import Carbon

struct SettingsView: View {
    @EnvironmentObject var theme: ThemeStore

    var body: some View {
        Form {
            Section("Appearance") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dark Mode")
                        Text("Switch the app to a black background theme.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { theme.isDark },
                        set: { theme.isDark = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(.vertical, 4)
            }

            Section("Floating Panel") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show / Hide Shortcut")
                        Text("Press the shortcut from any app to toggle the floating panel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorderButton()
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 240)
    }
}

// MARK: – Recorder button

struct ShortcutRecorderButton: View {
    @ObservedObject private var hotkeyStore = HotkeyStore.shared
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button { isRecording ? stopRecording() : startRecording() } label: {
            Text(isRecording ? "Press shortcut…" : hotkeyStore.displayString)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isRecording
                              ? Color.accentColor.opacity(0.12)
                              : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isRecording)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            let ns = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard !ns.isEmpty else { return nil }

            var mods: UInt32 = 0
            if ns.contains(.control) { mods |= UInt32(controlKey) }
            if ns.contains(.option)  { mods |= UInt32(optionKey) }
            if ns.contains(.shift)   { mods |= UInt32(shiftKey) }
            if ns.contains(.command) { mods |= UInt32(cmdKey) }

            hotkeyStore.keyCode = UInt32(event.keyCode)
            hotkeyStore.carbonModifiers = mods
            stopRecording()
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
