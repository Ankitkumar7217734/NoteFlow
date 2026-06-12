import SwiftUI
import Carbon

struct SettingsView: View {
    @EnvironmentObject var theme: ThemeStore
    @ObservedObject private var panelSettings = PanelSettings.shared

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

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Opacity")
                        Text("Transparency of the floating panel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { panelSettings.opacity },
                            set: { panelSettings.opacity = $0 }
                        ),
                        in: PanelSettings.minOpacity...1.0
                    )
                    .frame(width: 140)
                    Text("\(Int((panelSettings.opacity * 100).rounded()))%")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
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
            // Reject combos without a real modifier (⌃ ⌥ ⌘) — registering
            // e.g. shift-only ⇧S globally would swallow every capital S
            // typed in any app. Keep recording until a valid combo arrives.
            guard let mods = HotkeyStore.carbonModifiers(from: ns) else { return nil }

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
