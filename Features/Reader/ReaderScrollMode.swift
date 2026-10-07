import Foundation
import CoreGraphics

/// Reading layout: Pages (turns) or Scroll (continuous).
enum ReaderScrollMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case pages
    case scroll

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pages: return "Pages"
        case .scroll: return "Scroll"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .pages: return "Page turns"
        case .scroll: return "Continuous scroll"
        }
    }

    /// Use continuous scrolling while VoiceOver is running.
    static func effective(_ preferred: ReaderScrollMode, voiceOverRunning: Bool) -> ReaderScrollMode {
        voiceOverRunning ? .scroll : preferred
    }
}

/// Viewport-based page geometry and edge-tap helpers.
enum ReaderPageGeometry {
    /// The outer 20% horizontal regions select the previous or next page.
    static let edgeTapFraction: CGFloat = 0.20

    static func pageHeight(viewportHeight: CGFloat) -> CGFloat {
        max(1, floor(viewportHeight))
    }

    static func maxOffsetY(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    static func pageIndex(offsetY: CGFloat, pageHeight: CGFloat) -> Int {
        let ph = max(1, pageHeight)
        return max(0, Int((max(0, offsetY) / ph).rounded()))
    }

    static func pageIndexContaining(contentY: CGFloat, pageHeight: CGFloat) -> Int {
        let ph = max(1, pageHeight)
        return max(0, Int(floor(max(0, contentY) / ph)))
    }

    static func offsetY(
        forPage page: Int,
        pageHeight: CGFloat,
        maxOffsetY: CGFloat
    ) -> CGFloat {
        let ph = max(1, pageHeight)
        let raw = CGFloat(max(0, page)) * ph
        return min(max(0, maxOffsetY), raw)
    }

    static func pageCount(contentHeight: CGFloat, viewportHeight: CGFloat) -> Int {
        let viewport = max(1, viewportHeight)
        guard contentHeight > 0 else { return 1 }
        return max(1, Int(ceil(contentHeight / viewport)))
    }

    /// 1-based display index clamped into `1...count`.
    static func displayPage(indexZeroBased: Int, count: Int) -> Int {
        let c = max(1, count)
        return min(c, max(1, indexZeroBased + 1))
    }

    static func edgeTapDirection(x: CGFloat, width: CGFloat) -> Int? {
        guard width > 1 else { return nil }
        let left = width * edgeTapFraction
        let right = width * (1 - edgeTapFraction)
        if x < left { return -1 }
        if x > right { return 1 }
        return nil
    }
}

/// Lightweight page chrome published to SwiftUI (N of M / go-to-page).
struct ReaderPageChromeState: Equatable, Sendable {
    var index: Int
    var count: Int

    var displayLabel: String {
        "\(ReaderPageGeometry.displayPage(indexZeroBased: index, count: count)) of \(max(1, count))"
    }
}
