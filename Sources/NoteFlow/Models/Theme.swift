import SwiftUI
import AppKit

enum ThemeMode: String {
    case light, dark
}

extension Notification.Name {
    static let themeChanged = Notification.Name("themeChanged")
    /// Posted just BEFORE the mode flips, so AppDelegate can snapshot the
    /// windows for the cross-fade while they still show the old theme.
    /// (Observer order on themeChanged isn't guaranteed, so the snapshot
    /// needs its own, earlier signal.)
    static let themeWillChange = Notification.Name("themeWillChange")
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

    // MARK: – Paper & Ink default text colors

    // The editor's default "ink" per theme. Concrete values are needed in
    // NoteStore.themeDefaultColors (strip-on-load matching), the dynamic
    // color below resolves between them per appearance.
    static let lightInkNS = NSColor(red: 0.173, green: 0.165, blue: 0.149, alpha: 1)  // #2C2A26
    static let darkInkNS  = NSColor.white                                              // #FFFFFF
    /// Previous dark inks — kept in `NoteStore.themeDefaultColors` so saved notes
    /// with an older default still strip correctly on theme flip.
    static let midBrightDarkInkNS = NSColor(red: 0.941, green: 0.933, blue: 0.918, alpha: 1)  // #F0EEEA
    static let legacyDarkInkNS = NSColor(red: 0.855, green: 0.843, blue: 0.820, alpha: 1)  // #DAD7D1

    /// The editor's default text color. Resolves per the view's effective
    /// appearance — warm near-black in light mode, pure white in dark mode.
    static let dynamicInkNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkInkNS : lightInkNS
    }

    // Light — "paper": cream chrome (the app's identity), paper-tinted
    // editor (not stark white), warm near-black ink. Body contrast ≈ 13.8:1.
    static let light = Palette(
        chromeBackground: Color(red: 0.941, green: 0.937, blue: 0.918),
        editorBackground: Color(red: 0.988, green: 0.984, blue: 0.973),
        text: Color(red: 0.173, green: 0.165, blue: 0.149),
        secondaryText: Color(red: 0.435, green: 0.424, blue: 0.396),
        iconColor: Color(red: 0.231, green: 0.224, blue: 0.204),
        iconColorDim: Color(red: 0.541, green: 0.529, blue: 0.502),
        activeTabBackground: Color.white.opacity(0.85),
        activeRowBackground: Color.black.opacity(0.07),
        searchFieldBackground: Color.black.opacity(0.045),
        searchHighlight: Color(red: 1.0, green: 0.78, blue: 0.30).opacity(0.45),
        dividerColor: Color.black.opacity(0.09),
        copyButtonBackground: Color(red: 0.173, green: 0.165, blue: 0.149),
        copyButtonText: Color(red: 0.988, green: 0.984, blue: 0.973),
        editorBackgroundNS: NSColor(red: 0.988, green: 0.984, blue: 0.973, alpha: 1),
        textNS: lightInkNS,
        chromeBackgroundNS: NSColor(red: 0.941, green: 0.937, blue: 0.918, alpha: 1),
        linkNS: NSColor(red: 0.149, green: 0.404, blue: 0.788, alpha: 1),        // #2667C9
        tableBorderNS: NSColor(red: 0.812, green: 0.800, blue: 0.769, alpha: 1), // #CFCCC4
        tableHeaderBgNS: NSColor(red: 0.945, green: 0.937, blue: 0.914, alpha: 1), // #F1EFE9
        selectionBackgroundNS: NSColor(red: 0.243, green: 0.463, blue: 0.839, alpha: 0.20),
        selectedTextNS: lightInkNS,
        appearance: .aqua,
        colorScheme: .light
    )

    // Dark — "warm graphite": layered surfaces (chrome #151412, editor
    // lifted to #1D1C19 so content sits forward), pure-white body ink for
    // maximum separation from the warm gray surfaces.
    static let dark = Palette(
        chromeBackground: Color(red: 0.082, green: 0.078, blue: 0.071),
        editorBackground: Color(red: 0.114, green: 0.110, blue: 0.098),
        text: .white,
        secondaryText: Color(red: 0.557, green: 0.545, blue: 0.522),
        iconColor: .white,
        iconColorDim: Color(red: 0.702, green: 0.690, blue: 0.667),
        activeTabBackground: Color.white.opacity(0.09),
        activeRowBackground: Color.white.opacity(0.07),
        searchFieldBackground: Color.white.opacity(0.06),
        searchHighlight: Color(red: 1.0, green: 0.72, blue: 0.30).opacity(0.30),
        dividerColor: Color(red: 0.165, green: 0.161, blue: 0.145),
        copyButtonBackground: Color.white.opacity(0.16),
        copyButtonText: .white,
        editorBackgroundNS: NSColor(red: 0.114, green: 0.110, blue: 0.098, alpha: 1),
        textNS: darkInkNS,
        chromeBackgroundNS: NSColor(red: 0.082, green: 0.078, blue: 0.071, alpha: 1),
        linkNS: NSColor(red: 0.435, green: 0.659, blue: 0.910, alpha: 1),        // #6FA8E8
        tableBorderNS: NSColor(red: 0.227, green: 0.220, blue: 0.200, alpha: 1), // #3A3833
        tableHeaderBgNS: NSColor(red: 0.149, green: 0.145, blue: 0.122, alpha: 1), // #26251F
        selectionBackgroundNS: NSColor(red: 0.290, green: 0.471, blue: 0.761, alpha: 0.35),
        selectedTextNS: darkInkNS,
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
        willSet {
            // Fire before anything repaints so the cross-fade can snapshot
            // the windows while they still show the outgoing theme.
            if newValue != mode {
                NotificationCenter.default.post(name: .themeWillChange, object: nil)
            }
        }
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
