import Foundation

struct LearningSuggestion: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case read(lessonID: String)
        case review(conceptID: String)
        case revisit(lessonID: String)
    }

    var kind: Kind
    var reason: String
}

enum LearningRecommendation {
    // Product policy, not a claim that these are scientifically optimal intervals.
    private static let day: TimeInterval = 86_400
    private static let intervalDays = [1, 3, 7, 14, 30]

    static func dueDate(conceptID: String, progress: LearningProgress) -> Date? {
        let attempts = orderedAttempts(conceptID: conceptID, progress: progress)
        let report = progress.selfReportedLearned[conceptID]
        guard let latest = attempts.last else { return report?.addingTimeInterval(day) }
        if let report, report >= latest.date { return report.addingTimeInterval(day) }

        var chain = 0
        var previous: LearningAttempt?
        var hasEarlierUnassistedSuccess = false
        for attempt in attempts {
            if !attempt.correct || attempt.usedHelp {
                chain = 0
            } else {
                if hasEarlierUnassistedSuccess, let previous, qualifies(attempt, after: previous) {
                    chain = min(chain + 1, intervalDays.count - 1)
                }
                hasEarlierUnassistedSuccess = true
            }
            previous = attempt
        }
        return latest.date.addingTimeInterval(Double(intervalDays[chain]) * day)
    }

    static func recalledLater(conceptID: String, progress: LearningProgress) -> Bool {
        let attempts = orderedAttempts(conceptID: conceptID, progress: progress)
        var previous: LearningAttempt?
        for attempt in attempts {
            if let previous {
                if qualifies(attempt, after: previous) { return true }
            } else if attempt.correct, !attempt.usedHelp, attempt.isReview,
                      let report = progress.selfReportedLearned[conceptID],
                      attempt.date.timeIntervalSince(report) >= day {
                return true
            }
            previous = attempt
        }
        return false
    }

    static func suggest(
        lessonIDs: [String],
        conceptIDs: [String],
        progress: LearningProgress,
        now: Date = Date()
    ) -> LearningSuggestion? {
        let unfinished = lessonIDs.first { !progress.completedLessonIDs.contains($0) }
        let lastValidLesson = progress.lastLessonID.flatMap { lessonIDs.contains($0) ? $0 : nil }
        let lastFeedback = progress.feedback.enumerated().max {
            if $0.element.date == $1.element.date { return $0.offset < $1.offset }
            return $0.element.date < $1.element.date
        }?.element

        if let lastFeedback, lastFeedback.experience == .tooDemanding,
           now.timeIntervalSince(lastFeedback.date) >= 0,
           now.timeIntervalSince(lastFeedback.date) < day, let unfinished {
            return LearningSuggestion(
                kind: .read(lessonID: lastValidLesson ?? unfinished),
                reason: "Keep this session short; you said the last one felt demanding."
            )
        }

        var oldestDue: (conceptID: String, date: Date)?
        for conceptID in conceptIDs {
            guard let date = dueDate(conceptID: conceptID, progress: progress), date <= now else { continue }
            if oldestDue == nil || date < oldestDue!.date { oldestDue = (conceptID, date) }
        }
        if let oldestDue {
            return LearningSuggestion(
                kind: .review(conceptID: oldestDue.conceptID),
                reason: "A later check is due. You can read instead."
            )
        }
        if let unfinished {
            return LearningSuggestion(
                kind: .read(lessonID: unfinished),
                reason: "Your reading budget is \(progress.preferences.sessionMinutes) minutes. Read at your own pace."
            )
        }
        if let lessonID = lastValidLesson ?? lessonIDs.first {
            return LearningSuggestion(kind: .revisit(lessonID: lessonID), reason: "You have finished these readings. Revisit any idea you want to explore.")
        }
        return nil
    }

    private static func orderedAttempts(conceptID: String, progress: LearningProgress) -> [LearningAttempt] {
        progress.attempts.enumerated()
            .filter { $0.element.conceptID == conceptID }
            .sorted {
                if $0.element.date == $1.element.date { return $0.offset < $1.offset }
                return $0.element.date < $1.element.date
            }
            .map(\.element)
    }

    private static func qualifies(_ attempt: LearningAttempt, after previous: LearningAttempt) -> Bool {
        attempt.correct && !attempt.usedHelp && attempt.isReview
            && attempt.questionID != previous.questionID
            && attempt.date.timeIntervalSince(previous.date) >= day
    }
}
