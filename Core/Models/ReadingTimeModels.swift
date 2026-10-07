import Foundation

/// Configurable reading-speed + visual-weight preferences for remaining-time estimates.
/// Time is derived from words, never pages (continuous reader has no pagination).
struct ReadingTimePreferences: Codable, Equatable, Hashable, Sendable {
    /// Words per minute for prose (paragraph/heading/quote/callout text).
    var wordsPerMinute: Int
    /// Fixed seconds attributed to each visual (`imagePlaceholder`) block.
    var secondsPerVisual: Int
    /// Allowed remaining-time drift on adapt/regen (± fraction of baseline minutes).
    var toleranceFraction: Double

    static let `default` = ReadingTimePreferences(
        wordsPerMinute: 230,
        secondsPerVisual: 12,
        toleranceFraction: 0.20
    )

    /// Defensive bounds for persisted or caller-provided values.
    var normalized: ReadingTimePreferences {
        let safeTolerance = toleranceFraction.isFinite
            ? min(0.95, max(0.01, toleranceFraction))
            : Self.default.toleranceFraction
        return ReadingTimePreferences(
            wordsPerMinute: min(1_000, max(1, wordsPerMinute)),
            secondsPerVisual: min(3_600, max(0, secondsPerVisual)),
            toleranceFraction: safeTolerance
        )
    }

    /// Clamped accessors used by Books UX chrome.
    var safeWordsPerMinute: Int { normalized.wordsPerMinute }
    var safeSecondsPerVisual: Int { normalized.secondsPerVisual }
    var safeToleranceFraction: Double { normalized.toleranceFraction }
}

/// Remaining reading-time estimate. Time is word-based; visuals weighted separately.
struct ReadingTimeEstimate: Equatable, Hashable, Sendable {
    var proseWordCount: Int
    var visualBlockCount: Int
    var wordsPerMinute: Int
    var secondsPerVisual: Int

    static let zero = ReadingTimeEstimate(
        proseWordCount: 0,
        visualBlockCount: 0,
        wordsPerMinute: ReadingTimePreferences.default.wordsPerMinute,
        secondsPerVisual: ReadingTimePreferences.default.secondsPerVisual
    )

    var proseMinutes: Double {
        Double(max(0, proseWordCount)) / Double(min(1_000, max(1, wordsPerMinute)))
    }

    var visualMinutes: Double {
        Double(max(0, visualBlockCount)) * Double(min(3_600, max(0, secondsPerVisual))) / 60.0
    }

    /// Total expected remaining minutes (prose + visuals).
    var remainingMinutes: Double {
        proseMinutes + visualMinutes
    }

    /// Re-stamps the same content counts with a different reading pace.
    func applying(_ preferences: ReadingTimePreferences) -> ReadingTimeEstimate {
        let prefs = preferences.normalized
        return ReadingTimeEstimate(
            proseWordCount: proseWordCount,
            visualBlockCount: visualBlockCount,
            wordsPerMinute: prefs.wordsPerMinute,
            secondsPerVisual: prefs.secondsPerVisual
        )
    }

    /// Proportional slice of this estimate (e.g. fraction of chapter still ahead).
    func scaled(by fraction: Double) -> ReadingTimeEstimate {
        let clamped = min(1, max(0, fraction))
        return ReadingTimeEstimate(
            proseWordCount: Int((Double(proseWordCount) * clamped).rounded()),
            visualBlockCount: Int((Double(visualBlockCount) * clamped).rounded()),
            wordsPerMinute: wordsPerMinute,
            secondsPerVisual: secondsPerVisual
        )
    }

    var displayLabel: String {
        let mins = remainingMinutes
        if mins < 1 {
            let secs = max(1, Int((mins * 60).rounded()))
            return "~\(secs)s"
        }
        let rounded = Int(mins.rounded())
        if rounded < 60 {
            return "~\(rounded) min"
        }
        let hours = rounded / 60
        let rem = rounded % 60
        return rem == 0 ? "~\(hours)h" : "~\(hours)h \(rem)m"
    }

    /// Chrome-sized label without leading tilde.
    var compactLabel: String {
        let minutes = remainingMinutes
        if minutes < 1 { return "Under a minute" }
        let rounded = Int(minutes.rounded())
        if rounded < 60 { return "\(rounded) min" }
        let hours = rounded / 60
        let remainder = rounded % 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }

    var approximateLabel: String {
        remainingMinutes < 1 ? "under a minute" : "~\(compactLabel)"
    }

    var accessibilityLabel: String {
        let minutes = remainingMinutes
        if minutes < 1 { return "Under a minute left in this chapter" }
        let rounded = Int(minutes.rounded())
        if rounded < 60 {
            return "About \(rounded) minute\(rounded == 1 ? "" : "s") left in this chapter"
        }
        let hours = rounded / 60
        let remainder = rounded % 60
        let hourPart = "\(hours) hour\(hours == 1 ? "" : "s")"
        if remainder == 0 { return "About \(hourPart) left in this chapter" }
        return "About \(hourPart) \(remainder) minutes left in this chapter"
    }
}

/// Cut boundary for regenerate-from-here (chapter onward; optional block hint for UI).
struct RegenerationCut: Equatable, Hashable, Sendable {
    var chapterId: UUID
    var chapterTitle: String
    var chapterOrderIndex: Int
    /// Optional block id within the chapter (UI hint; regen still chapter-granular in MVP).
    var blockId: UUID?
}

struct RegenChapterSummary: Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var title: String
    var orderIndex: Int
    var wordCount: Int
}

/// Preview shown before Apply on regenerate-from-here.
struct RegenerationPreview: Equatable, Sendable {
    var cut: RegenerationCut
    var regeneratingChapters: [RegenChapterSummary]
    var lockedSkippedCount: Int
    var baselineRemaining: ReadingTimeEstimate
    var plannedRemaining: ReadingTimeEstimate
    var plan: AdaptationPlan
}

struct ChapterVersionEntry: Identifiable, Equatable, Hashable, Sendable {
    var id: UUID { revisionId }
    var chapterId: UUID
    var chapterTitle: String
    var chapterOrderIndex: Int = 0
    var revisionId: UUID
    var revisionIndex: Int
    var createdAt: Date
    var isActive: Bool
    var isConsumedLocked: Bool
    var proseWordCount: Int
    var visualBlockCount: Int
    var previewSnippet: String
    /// Provenance line ("Regenerated from “gauchos” · More images"), when recorded.
    var origin: RevisionOrigin? = nil

    var originLabel: String? {
        guard let origin else { return nil }
        let trimmed = origin.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
