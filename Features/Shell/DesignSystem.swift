import SwiftUI
import UIKit

/// Semantic chrome colors. Reading pages retain the reader's own theme settings.
enum LRColor {
    static let background = adaptive(light: 0xF7F7F2, dark: 0x090E0D)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x15201D)
    static let secondarySurface = adaptive(light: 0xECEFE9, dark: 0x20302A)
    static let text = adaptive(light: 0x172C27, dark: 0xF1F2E9)
    static let secondaryText = adaptive(light: 0x566860, dark: 0xA6B6AD)
    static let accent = adaptive(light: 0x18675D, dark: 0x78D9CB)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x082C26)
    static let separator = Color(uiColor: .separator)
    static let warning = adaptive(light: 0x8B5A12, dark: 0xE8B765)
    // Existing feature views use these aliases while sharing the semantic palette.
    static let cream = background
    static let navy = text
    static let mustard = accent
    static let navyCard = surface
    static let progressTrack = secondarySurface
    static let progressFill = accent
    static let pillInactive = secondarySurface
    static let pillActiveFill = surface
    static let emptyIcon = Color.secondary.opacity(0.55)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

enum LRFont {
    /// Small-caps brand lockup.
    static func brand(_ size: CGFloat = 12) -> Font {
        .caption.weight(.semibold)
    }

    /// Serif screen title (Library).
    static func screenTitle(_ size: CGFloat = 34) -> Font {
        .system(.largeTitle, design: .serif)
    }

    static func cardTitle(_ size: CGFloat = 20) -> Font {
        .system(.headline, design: .serif)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let style: Font.TextStyle = size <= 12 ? .caption : size <= 14 ? .subheadline : .body
        return .system(style, design: .default).weight(weight)
    }
}

private struct GenBooksNavigationBar: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .toolbarBackground(LRColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
    }
}

extension View {
    func genBooksNavigationBar() -> some View { modifier(GenBooksNavigationBar()) }
}

enum ShellTab: String, CaseIterable, Identifiable {
    case library
    case notebook
    case learning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "Library"
        case .notebook: return "Notebook"
        case .learning: return "Learning"
        }
    }

    var systemImage: String {
        switch self {
        case .library: return "books.vertical"
        case .notebook: return "bookmark"
        case .learning: return "lightbulb"
        }
    }

}
