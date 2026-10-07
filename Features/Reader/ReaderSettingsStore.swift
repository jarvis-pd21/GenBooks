import Foundation
import SwiftUI

/// Search coverage is deliberately spoiler-safe by default.
enum BookSearchScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case readSoFar
    case wholeBook

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .readSoFar: return "Read so far"
        case .wholeBook: return "Whole book (Spoilers)"
        }
    }
}

/// Persisted reader comfort preferences (typeface, size, theme, spacing, margins,
/// page dim, reading pace, scroll vs page mode, search scope). Offline, local, no AI.
@MainActor
final class ReaderSettingsStore: ObservableObject {
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    @Published var colorScheme: ReaderColorScheme {
        didSet { defaults.set(colorScheme.rawValue, forKey: Keys.colorScheme) }
    }

    @Published var fontFamily: ReaderFontFamily {
        didSet { defaults.set(fontFamily.rawValue, forKey: Keys.fontFamily) }
    }

    /// Line height multiple applied to body text.
    @Published var lineSpacing: Double {
        didSet { defaults.set(lineSpacing, forKey: Keys.lineSpacing) }
    }

    /// Align body paragraphs to both margins; other block kinds retain natural alignment.
    @Published var justified: Bool {
        didSet { defaults.set(justified, forKey: Keys.justified) }
    }

    /// Horizontal page margin inset in points.
    @Published var marginInset: Double {
        didSet { defaults.set(marginInset, forKey: Keys.marginInset) }
    }

    /// Page dim for night reading (0 = off, 1 = maximum). Rendered as an overlay
    /// rather than a theme change, so text colours stay predictable.
    @Published var pageDim: Double {
        didSet { defaults.set(pageDim, forKey: Keys.pageDim) }
    }

    /// Personal reading pace driving "N min left in chapter".
    @Published var wordsPerMinute: Int {
        didSet { defaults.set(wordsPerMinute, forKey: Keys.wordsPerMinute) }
    }

    /// Persisted Pages or Scroll preference; defaults to continuous scrolling.
    @Published var scrollMode: ReaderScrollMode {
        didSet { defaults.set(scrollMode.rawValue, forKey: Keys.scrollMode) }
    }

    /// Persisted because choosing spoiler-inclusive search should remain explicit
    /// while still respecting the reader's last deliberate preference.
    @Published var searchScope: BookSearchScope {
        didSet { defaults.set(searchScope.rawValue, forKey: Keys.searchScope) }
    }

    static let minWordsPerMinute = 120
    static let maxWordsPerMinute = 420

    /// Strength of the dim overlay at `pageDim == 1`. Capped so text stays legible.
    static let maxDimOpacity = 0.55

    private let defaults: UserDefaults

    private enum Keys {
        static let fontSize = "livingreader.reader.fontSize"
        static let colorScheme = "livingreader.reader.colorScheme"
        static let fontFamily = "livingreader.reader.fontFamily"
        static let lineSpacing = "livingreader.reader.lineSpacing"
        static let justified = "livingreader.reader.justified"
        static let marginInset = "livingreader.reader.marginInset"
        static let pageDim = "livingreader.reader.pageDim"
        static let wordsPerMinute = "livingreader.reader.wordsPerMinute"
        static let scrollMode = "livingreader.reader.scrollMode"
        static let searchScope = "livingreader.reader.searchScope"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fontSize = Self.readDouble(defaults, Keys.fontSize) ?? Double(ReaderTypography.defaultBodySize)
        if let raw = defaults.string(forKey: Keys.colorScheme),
           let scheme = ReaderColorScheme(rawValue: raw) {
            self.colorScheme = scheme
        } else {
            self.colorScheme = .system
        }
        if let raw = defaults.string(forKey: Keys.fontFamily),
           let family = ReaderFontFamily(rawValue: raw) {
            self.fontFamily = family
        } else {
            self.fontFamily = .original
        }
        self.lineSpacing = Self.clamp(
            Self.readDouble(defaults, Keys.lineSpacing) ?? Double(ReaderTypography.defaultLineHeight),
            Double(ReaderTypography.minLineHeight),
            Double(ReaderTypography.maxLineHeight)
        )
        self.justified = defaults.bool(forKey: Keys.justified)
        self.marginInset = Self.clamp(
            Self.readDouble(defaults, Keys.marginInset) ?? Double(ReaderTypography.defaultInset),
            Double(ReaderTypography.minInset),
            Double(ReaderTypography.maxInset)
        )
        self.pageDim = Self.clamp(Self.readDouble(defaults, Keys.pageDim) ?? 0, 0, 1)
        let pace = Self.readDouble(defaults, Keys.wordsPerMinute)
            ?? Double(ReadingTimePreferences.default.wordsPerMinute)
        self.wordsPerMinute = Int(Self.clamp(pace, Double(Self.minWordsPerMinute), Double(Self.maxWordsPerMinute)))
        if let raw = defaults.string(forKey: Keys.scrollMode),
           let mode = ReaderScrollMode(rawValue: raw) {
            self.scrollMode = mode
        } else {
            self.scrollMode = .scroll
        }
        if let raw = defaults.string(forKey: Keys.searchScope),
           let scope = BookSearchScope(rawValue: raw) {
            self.searchScope = scope
        } else {
            self.searchScope = .readSoFar
        }
    }

    /// Launch-arg overrides arrive as strings; persisted values may be Double or Int.
    private static func readDouble(_ defaults: UserDefaults, _ key: String) -> Double? {
        if let value = defaults.object(forKey: key) as? Double { return value }
        if let value = defaults.object(forKey: key) as? Int { return Double(value) }
        if let raw = defaults.string(forKey: key), let value = Double(raw) { return value }
        return nil
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }

    var typography: ReaderTypography {
        ReaderTypography.make(
            bodyPointSize: CGFloat(fontSize),
            colorScheme: colorScheme,
            fontFamily: fontFamily,
            lineHeightMultiple: CGFloat(lineSpacing),
            horizontalInset: CGFloat(marginInset),
            justified: justified
        )
    }

    var readingTimePreferences: ReadingTimePreferences {
        var prefs = ReadingTimePreferences.default
        prefs.wordsPerMinute = wordsPerMinute
        return prefs
    }

    var dimOpacity: Double { pageDim * Self.maxDimOpacity }

    var swiftUIColorScheme: ColorScheme? {
        switch colorScheme {
        case .system: return nil
        case .light, .sepia: return .light
        case .dark: return .dark
        }
    }

    func bumpFont(by delta: Double) {
        fontSize = Self.clamp(
            fontSize + delta,
            Double(ReaderTypography.minBodySize),
            Double(ReaderTypography.maxBodySize)
        )
    }

    func bumpLineSpacing(by delta: Double) {
        let next = Self.clamp(
            lineSpacing + delta,
            Double(ReaderTypography.minLineHeight),
            Double(ReaderTypography.maxLineHeight)
        )
        lineSpacing = (next * 100).rounded() / 100
    }

    func bumpMargin(by delta: Double) {
        marginInset = Self.clamp(
            marginInset + delta,
            Double(ReaderTypography.minInset),
            Double(ReaderTypography.maxInset)
        )
    }
}
