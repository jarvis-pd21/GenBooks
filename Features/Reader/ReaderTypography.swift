import UIKit

/// Reading typeface choice. `original` is the manuscript default (system text);
/// `serif` prefers New York, Apple's book face, before falling back.
enum ReaderFontFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case original
    case serif
    case sans
    case georgia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .serif: return "Serif"
        case .sans: return "Sans"
        case .georgia: return "Georgia"
        }
    }

    func uiFont(size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        switch self {
        case .original, .sans:
            return Self.applying(italic: italic, to: base, size: size)
        case .georgia:
            // Use the installed book face and its actual bold/italic variants;
            // Georgia has no separate medium face for callouts.
            let name: String
            if weight >= .semibold {
                name = italic ? "Georgia-BoldItalic" : "Georgia-Bold"
            } else {
                name = italic ? "Georgia-Italic" : "Georgia"
            }
            return UIFont(name: name, size: size)
                ?? Self.applying(italic: italic, to: base, size: size)
        case .serif:
            // New York is only reachable through the system design descriptor —
            // UIFont(name: "New York") does not resolve it.
            if let descriptor = base.fontDescriptor.withDesign(.serif) {
                return Self.applying(italic: italic, to: UIFont(descriptor: descriptor, size: size), size: size)
            }
            if let georgia = UIFont(name: "Georgia", size: size) {
                return Self.applying(italic: italic, to: georgia, size: size)
            }
            return Self.applying(italic: italic, to: base, size: size)
        }
    }

    private static func applying(italic: Bool, to font: UIFont, size: CGFloat) -> UIFont {
        guard italic else { return font }
        var traits = font.fontDescriptor.symbolicTraits
        traits.insert(.traitItalic)
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return UIFont.italicSystemFont(ofSize: size)
    }
}

struct ReaderTypography: Equatable {
    var bodyPointSize: CGFloat
    var textColor: UIColor
    var secondaryColor: UIColor
    var backgroundColor: UIColor
    var horizontalInset: CGFloat
    var lineHeightMultiple: CGFloat
    var fontFamily: ReaderFontFamily
    var justified: Bool = false

    static let defaultBodySize: CGFloat = 19
    static let minBodySize: CGFloat = 15
    static let maxBodySize: CGFloat = 32
    static let defaultLineHeight: CGFloat = 1.28
    static let minLineHeight: CGFloat = 1.15
    static let maxLineHeight: CGFloat = 1.55
    static let defaultInset: CGFloat = 22
    static let minInset: CGFloat = 14
    static let maxInset: CGFloat = 36

    static func make(
        bodyPointSize: CGFloat,
        colorScheme: ReaderColorScheme,
        fontFamily: ReaderFontFamily = .original,
        lineHeightMultiple: CGFloat = defaultLineHeight,
        horizontalInset: CGFloat = defaultInset,
        justified: Bool = false
    ) -> ReaderTypography {
        let size = min(maxBodySize, max(minBodySize, bodyPointSize))
        let line = min(maxLineHeight, max(minLineHeight, lineHeightMultiple))
        let inset = min(maxInset, max(minInset, horizontalInset))
        let palette = ReaderPagePalette.forScheme(colorScheme)
        return ReaderTypography(
            bodyPointSize: size,
            textColor: palette.text,
            secondaryColor: palette.secondary,
            backgroundColor: palette.background,
            horizontalInset: inset,
            lineHeightMultiple: line,
            fontFamily: fontFamily,
            justified: justified
        )
    }

    var bodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple
        paragraph.paragraphSpacing = 0
        paragraph.alignment = .natural
        return [
            .font: fontFamily.uiFont(size: bodyPointSize, weight: .regular),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
            .kern: 0.1
        ]
    }

    func attributes(for kind: ContentBlockKind) -> [NSAttributedString.Key: Any] {
        var attrs = bodyAttributes
        let paragraph = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        switch kind {
        case .heading:
            attrs[.font] = fontFamily.uiFont(size: bodyPointSize + 8, weight: .bold)
            paragraph.paragraphSpacingBefore = 8
            paragraph.lineHeightMultiple = max(1.1, lineHeightMultiple - 0.13)
        case .quote:
            attrs[.font] = fontFamily.uiFont(size: bodyPointSize, weight: .regular, italic: true)
            attrs[.foregroundColor] = secondaryColor
            paragraph.firstLineHeadIndent = 12
            paragraph.headIndent = 12
        case .imagePlaceholder:
            attrs[.font] = fontFamily.uiFont(size: bodyPointSize - 1, weight: .medium)
            attrs[.foregroundColor] = secondaryColor
        case .callout:
            attrs[.font] = fontFamily.uiFont(size: bodyPointSize - 0.5, weight: .medium)
            attrs[.foregroundColor] = secondaryColor
            paragraph.firstLineHeadIndent = 8
            paragraph.headIndent = 8
            paragraph.paragraphSpacingBefore = 6
            paragraph.paragraphSpacing = 6
        case .paragraph:
            paragraph.alignment = justified ? .justified : .natural
        }
        attrs[.paragraphStyle] = paragraph
        return attrs
    }
}

/// Resolved page colours for one theme. Kept separate from `ReaderColorScheme`
/// so the swatches in settings and the rendered page can never disagree.
struct ReaderPagePalette: Equatable {
    var text: UIColor
    var secondary: UIColor
    var background: UIColor

    static let light = ReaderPagePalette(
        text: UIColor(white: 0.12, alpha: 1),
        secondary: UIColor(white: 0.35, alpha: 1),
        background: UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
    )

    /// Apple Books–style warm paper.
    static let sepia = ReaderPagePalette(
        text: UIColor(red: 0.29, green: 0.20, blue: 0.10, alpha: 1),
        secondary: UIColor(red: 0.45, green: 0.34, blue: 0.22, alpha: 1),
        background: UIColor(red: 0.96, green: 0.92, blue: 0.82, alpha: 1)
    )

    static let dark = ReaderPagePalette(
        text: UIColor(white: 0.92, alpha: 1),
        secondary: UIColor(white: 0.65, alpha: 1),
        background: UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    )

    static func forScheme(_ scheme: ReaderColorScheme) -> ReaderPagePalette {
        switch scheme.palette {
        case .light: return .light
        case .sepia: return .sepia
        case .dark: return .dark
        }
    }
}

enum ReaderColorScheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case sepia
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .dark: return "Dark"
        }
    }

    enum Palette: String, Equatable, Sendable { case light, sepia, dark }

    /// Which page palette this scheme resolves to right now.
    /// `system` follows the device appearance; the rest are explicit.
    var palette: Palette {
        switch self {
        case .light: return .light
        case .sepia: return .sepia
        case .dark: return .dark
        case .system:
            return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        }
    }

    func resolvedUIUserInterfaceStyle(trait: UITraitCollection = .current) -> UIUserInterfaceStyle {
        switch self {
        case .system: return trait.userInterfaceStyle == .dark ? .dark : .light
        case .light, .sepia: return .light
        case .dark: return .dark
        }
    }
}
