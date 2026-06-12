import Foundation
import AppKit

extension Notification.Name {
    static let panelOpacityChanged = Notification.Name("com.noteflow.panelOpacityChanged")
}

/// User-tunable floating-panel behavior — opacity and remembered size —
/// persisted to UserDefaults. Follows the HotkeyStore pattern: SwiftUI
/// (the Settings slider) binds the @Published value directly; AppKit
/// (AppDelegate) listens for .panelOpacityChanged to apply it live.
final class PanelSettings: ObservableObject {
    static let shared = PanelSettings()

    static let defaultSize = NSSize(width: 520, height: 535)
    /// Floor for the opacity slider: an almost-invisible panel would still
    /// be the key window and swallow every keystroke.
    static let minOpacity: Double = 0.5

    static func clampedOpacity(_ value: Double) -> Double {
        min(1.0, max(minOpacity, value))
    }

    private let defaults: UserDefaults

    // Private @Published storage + a clamping computed setter. Do NOT fold
    // the clamping into a didSet on the @Published property itself —
    // re-reading/re-assigning a @Published var inside its own observer
    // re-enters Combine's enclosing-instance subscript and crashes the
    // Swift runtime (metadata-cache fault, found the hard way via tests).
    @Published private var storedOpacity: Double

    var opacity: Double {
        get { storedOpacity }
        set {
            let clamped = Self.clampedOpacity(newValue)
            storedOpacity = clamped
            defaults.set(clamped, forKey: "panelOpacity")
            NotificationCenter.default.post(name: .panelOpacityChanged, object: nil)
        }
    }

    /// The panel's last user-chosen size. Saved when a live resize ends;
    /// used (re-centered) on every summon. Implausibly small saved values
    /// (corrupt defaults) fall back to the default size.
    var panelSize: NSSize {
        get {
            let w = defaults.double(forKey: "panelWidth")
            let h = defaults.double(forKey: "panelHeight")
            guard w >= 200, h >= 150 else { return Self.defaultSize }
            return NSSize(width: w, height: h)
        }
        set {
            defaults.set(Double(newValue.width), forKey: "panelWidth")
            defaults.set(Double(newValue.height), forKey: "panelHeight")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.object(forKey: "panelOpacity") as? Double
        storedOpacity = Self.clampedOpacity(saved ?? 1.0)
    }
}
