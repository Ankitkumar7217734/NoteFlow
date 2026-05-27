import SwiftUI
import AppKit

enum ThemeMode: String {
    case light, dark
}

extension Notification.Name {
    static let themeChanged = Notification.Name("themeChanged")
}

// Palette of named colors for one theme mode. Exposes both SwiftUI Color
// (for SwiftUI views) and NSColor (for AppKit text view / window chrome).
struct Palette {
    let chromeBackground: Color
    let editorBackground: Color
    let text: Color
    let secondaryText: Color
    let iconColor: Color
    let iconColorDim: Color
    let activeTabBackground: Color
    let activeRowBackground: Color
    let searchFieldBackground: Color
    let searchHighlight: Color
    let dividerColor: Color
    let copyButtonBackground: Color
    let copyButtonText: Color

    let editorBackgroundNS: NSColor
    let textNS: NSColor
    let chromeBackgroundNS: NSColor
    let linkNS: NSColor
    let tableBorderNS: NSColor
    let tableHeaderBgNS: NSColor
    let selectionBackgroundNS: NSColor
    let selectedTextNS: NSColor

    let appearance: NSAppearance.Name
    let colorScheme: ColorScheme

    static let light = Palette(
        chromeBackground: Color(red: 0.941, green: 0.937, blue: 0.918),
        editorBackground: .white,
        text: .black,
        secondaryText: Color(red: 0.45, green: 0.45, blue: 0.45),
        iconColor: Color(red: 0.20, green: 0.20, blue: 0.20),
        iconColorDim: Color(red: 0.50, green: 0.50, blue: 0.50),
        activeTabBackground: Color.white.opacity(0.8),
        activeRowBackground: Color.black.opacity(0.08),
        searchFieldBackground: Color.black.opacity(0.05),
        searchHighlight: Color.yellow.opacity(0.55),
        dividerColor: Color.black.opacity(0.10),
        copyButtonBackground: .black,
        copyButtonText: .white,
        editorBackgroundNS: .white,
        textNS: .black,
        chromeBackgroundNS: NSColor(red: 0.941, green: 0.937, blue: 0.918, alpha: 1),
        linkNS: .systemBlue,
        tableBorderNS: NSColor(white: 0.75, alpha: 1),
        tableHeaderBgNS: NSColor(white: 0.94, alpha: 1),
        selectionBackgroundNS: NSColor(red: 0.20, green: 0.47, blue: 0.96, alpha: 0.22),
        selectedTextNS: .black,
        appearance: .aqua,
        colorScheme: .light
    )

    // Everything pure #000000. A single #2e2e2e hairline (dividerColor)
    // separates the sidebar from the editor — that's the only visual
    // distinction between the two surfaces.
    static let dark = Palette(
        chromeBackground: .black,
        editorBackground: .black,
        text: Color(red: 0.91, green: 0.91, blue: 0.91),
        secondaryText: Color(red: 0.62, green: 0.62, blue: 0.62),
        iconColor: Color(red: 0.84, green: 0.84, blue: 0.84),
        iconColorDim: Color(red: 0.55, green: 0.55, blue: 0.55),
        activeTabBackground: Color.white.opacity(0.14),
        activeRowBackground: Color.white.opacity(0.10),
        searchFieldBackground: Color.white.opacity(0.08),
        searchHighlight: Color.yellow.opacity(0.35),
        dividerColor: Color(red: 0.18, green: 0.18, blue: 0.18),
        copyButtonBackground: Color.white.opacity(0.20),
        copyButtonText: .white,
        editorBackgroundNS: .black,
        textNS: NSColor(white: 0.91, alpha: 1),
        chromeBackgroundNS: .black,
        linkNS: .systemBlue,
        tableBorderNS: NSColor(white: 0.30, alpha: 1),
        tableHeaderBgNS: NSColor(white: 0.18, alpha: 1),
        selectionBackgroundNS: NSColor(red: 0.32, green: 0.56, blue: 1.00, alpha: 0.38),
        selectedTextNS: .white,
        appearance: .darkAqua,
        colorScheme: .dark
    )
}

// Singleton observable theme state. SwiftUI views observe via
// @EnvironmentObject (or @ObservedObject); AppKit listeners subscribe to
// Notification.Name.themeChanged.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published var mode: ThemeMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "themeMode")
            NotificationCenter.default.post(name: .themeChanged, object: nil)
        }
    }

    var palette: Palette {
        switch mode {
        case .light: return .light
        case .dark:  return .dark
        }
    }

    var isDark: Bool {
        get { mode == .dark }
        set { mode = newValue ? .dark : .light }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "themeMode"),
           let m = ThemeMode(rawValue: raw) {
            mode = m
        } else {
            mode = .light
        }
    }
}
