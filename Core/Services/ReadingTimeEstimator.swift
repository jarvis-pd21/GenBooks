import Foundation

enum ReadingTimeEstimator {
    /// Prose words exclude visual placeholder blocks (those use fixed seconds).
    static func estimate(
        blocks: [ContentBlock],
        preferences: ReadingTimePreferences = .default
    ) -> ReadingTimeEstimate {
        let preferences = preferences.normalized
        let visuals = blocks.filter { $0.kind == .imagePlaceholder }
        let proseBlocks = blocks.filter { $0.kind != .imagePlaceholder }
        let words = AdaptationPlanValidator.wordCount(of: proseBlocks)
        return ReadingTimeEstimate(
            proseWordCount: words,
            visualBlockCount: visuals.count,
            wordsPerMinute: preferences.wordsPerMinute,
            secondsPerVisual: preferences.secondsPerVisual
        )
    }

    static func estimate(
        plainText: String,
        visualBlockCount: Int = 0,
        preferences: ReadingTimePreferences = .default
    ) -> ReadingTimeEstimate {
        let preferences = preferences.normalized
        return ReadingTimeEstimate(
            proseWordCount: AdaptationPlanValidator.wordCount(of: plainText),
            visualBlockCount: max(0, visualBlockCount),
            wordsPerMinute: preferences.wordsPerMinute,
            secondsPerVisual: preferences.secondsPerVisual
        )
    }

    /// Sum estimates for multiple chapter block lists (remaining from cut onward).
    static func estimateRemaining(
        chapterBlocks: [[ContentBlock]],
        preferences: ReadingTimePreferences = .default
    ) -> ReadingTimeEstimate {
        var words = 0
        var visuals = 0
        for blocks in chapterBlocks {
            let e = estimate(blocks: blocks, preferences: preferences)
            let nextWords = words.addingReportingOverflow(e.proseWordCount)
            words = nextWords.overflow ? .max : nextWords.partialValue
            let nextVisuals = visuals.addingReportingOverflow(e.visualBlockCount)
            visuals = nextVisuals.overflow ? .max : nextVisuals.partialValue
        }
        let preferences = preferences.normalized
        return ReadingTimeEstimate(
            proseWordCount: words,
            visualBlockCount: visuals,
            wordsPerMinute: preferences.wordsPerMinute,
            secondsPerVisual: preferences.secondsPerVisual
        )
    }

    /// Target prose word count that preserves `baseline` minutes given planned visual count.

    static func total(of estimates: [ReadingTimeEstimate], preferences: ReadingTimePreferences = .default) -> ReadingTimeEstimate {
        let prefs = preferences.normalized
        let prose = estimates.reduce(0) { $0 + max(0, $1.proseWordCount) }
        let visuals = estimates.reduce(0) { $0 + max(0, $1.visualBlockCount) }
        return ReadingTimeEstimate(
            proseWordCount: prose,
            visualBlockCount: visuals,
            wordsPerMinute: prefs.wordsPerMinute,
            secondsPerVisual: prefs.secondsPerVisual
        )
    }

    static func targetWordCount(
        preservingMinutes baseline: ReadingTimeEstimate,
        plannedVisualCount: Int,
        preferences: ReadingTimePreferences = .default
    ) -> Int {
        let preferences = preferences.normalized
        let visualMinutes = Double(max(0, plannedVisualCount)) * Double(preferences.secondsPerVisual) / 60.0
        let proseMinutes = max(0, baseline.remainingMinutes - visualMinutes)
        let target = proseMinutes * Double(preferences.wordsPerMinute)
        guard target.isFinite else { return .max }
        return max(20, target >= Double(Int.max) ? .max : Int(target.rounded()))
    }
}

enum ReadingTimeGuardrail {
    /// Ensures planned remaining minutes stay within tolerance of baseline.
    static func assertPreservesRemainingTime(
        baseline: ReadingTimeEstimate,
        planned: ReadingTimeEstimate,
        preferences: ReadingTimePreferences = .default
    ) throws {
        let base = max(0.05, baseline.remainingMinutes)
        let plannedMins = planned.remainingMinutes
        let fraction = preferences.normalized.toleranceFraction
        guard base.isFinite, plannedMins.isFinite else {
            throw AdaptationError.readingTimeGuardrailFailed(
                baselineMinutes: base,
                plannedMinutes: plannedMins,
                toleranceFraction: fraction
            )
        }
        let lower = base * (1.0 - fraction)
        let upper = base * (1.0 + fraction)
        if plannedMins < lower || plannedMins > upper {
            throw AdaptationError.readingTimeGuardrailFailed(
                baselineMinutes: base,
                plannedMinutes: plannedMins,
                toleranceFraction: fraction
            )
        }
    }
}
