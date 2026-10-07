import Foundation

enum LearningScoreStatus: String, Codable, Sendable {
    case unknown, correct, incorrect
}

struct LearningExposure: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case lesson, question, answer, help }
    var id: UUID = UUID()
    let conceptID: String
    let questionID: String?
    let presentationID: UUID?
    let contentVersion: String
    let kind: Kind
    let date: Date
    var isTeaching: Bool { kind != .question }
}

struct LearningScoreEligibility: Codable, Equatable, Sendable {
    let canCount: Bool
    let reason: String
    let nextEligibleDate: Date?
}

struct LearningQuestionPresentation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let conceptID: String
    let questionID: String
    let contentVersion: String
    let isReview: Bool
    let date: Date
    let eligibility: LearningScoreEligibility
    // An append-only event position also distinguishes events saved in the same ISO second.
    let exposureCountAtPresentation: Int
}

struct LearningScoreReceipt: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { presentationID }
    let presentationID: UUID
    let conceptID: String
    let questionID: String
    let contentVersion: String
    let date: Date
    let correct: Bool
    let usedHelp: Bool
    let counted: Bool
    let delta: Int
    let reason: String
    let previousStatus: LearningScoreStatus
    let newStatus: LearningScoreStatus
}

struct LearningScoreSlot: Identifiable, Equatable, Sendable {
    var id: String { questionID }
    let questionID: String
    let conceptID: String
    let title: String
    let status: LearningScoreStatus
    let date: Date?
    let older: Bool
}

struct LearningScoreSummary: Equatable, Sendable {
    let score: Int
    let completedSlotCount: Int
    let correctCount: Int
    let slots: [LearningScoreSlot]
}

/// An evidence index for ten designated multiple-choice checks, not a knowledge percentage.
enum LearningScore {
    static let contentVersion = "physics-foundations-v1"
    static let day: TimeInterval = 86_400
    static let definitions: [(conceptID: String, title: String, questionID: String)] = [
        ("models", "Models and evidence", "model-later-1"),
        ("models", "Models and evidence", "model-now-2"),
        ("force", "Force and motion", "force-later-1"),
        ("force", "Force and motion", "force-now-2"),
        ("momentum", "Momentum", "momentum-later-1"),
        ("momentum", "Momentum", "momentum-now-2"),
        ("energy", "Energy", "energy-later-1"),
        ("energy", "Energy", "energy-now-2"),
        ("entropy", "Entropy", "entropy-later-1"),
        ("entropy", "Entropy", "entropy-now-2")
    ]

    static func summary(progress: LearningProgress, now: Date = Date()) -> LearningScoreSummary {
        let slots = definitions.map { definition in
            let receipt = progress.scoreReceipts.enumerated().filter {
                $0.element.counted && $0.element.contentVersion == contentVersion &&
                $0.element.questionID == definition.questionID && $0.element.conceptID == definition.conceptID
            }.max {
                if $0.element.date == $1.element.date { return $0.offset < $1.offset }
                return $0.element.date < $1.element.date
            }?.element
            return LearningScoreSlot(questionID: definition.questionID, conceptID: definition.conceptID,
                title: definition.title, status: receipt.map { $0.correct ? .correct : .incorrect } ?? .unknown,
                date: receipt?.date, older: receipt.map { now.timeIntervalSince($0.date) > 14 * day } ?? false)
        }
        let correct = slots.filter { $0.status == .correct }.count
        return LearningScoreSummary(score: 10 * correct,
            completedSlotCount: slots.filter { $0.status != .unknown }.count, correctCount: correct, slots: slots)
    }

    static func recordTeaching(conceptIDs: [String], progress: inout LearningProgress, now: Date = Date()) {
        let date = timestamp(now)
        beginTracking(progress: &progress, now: date)
        for conceptID in Set(conceptIDs).sorted() {
            progress.learningExposures.append(LearningExposure(conceptID: conceptID, questionID: nil,
                presentationID: nil, contentVersion: contentVersion, kind: .lesson, date: date))
        }
    }

    /// Preview uses a copy so selecting a question never records that its text was seen.
    static func previewEligibility(conceptID: String, questionID: String, isReview: Bool,
        version: String = contentVersion, progress: LearningProgress, now: Date = Date()) -> LearningScoreEligibility {
        var preview = progress
        let date = timestamp(now)
        beginTracking(progress: &preview, now: date)
        return eligibility(conceptID: conceptID, questionID: questionID, isReview: isReview,
            version: version, progress: preview, now: date)
    }

    static func startQuestionPresentation(conceptID: String, questionID: String, isReview: Bool,
        version: String = contentVersion, progress: inout LearningProgress, now: Date = Date()) -> LearningQuestionPresentation {
        let date = timestamp(now)
        beginTracking(progress: &progress, now: date)
        let eligibility = eligibility(conceptID: conceptID, questionID: questionID, isReview: isReview,
            version: version, progress: progress, now: date)
        let presentation = LearningQuestionPresentation(id: UUID(), conceptID: conceptID, questionID: questionID,
            contentVersion: version, isReview: isReview, date: date, eligibility: eligibility,
            exposureCountAtPresentation: progress.learningExposures.count)
        progress.questionPresentations.append(presentation)
        progress.learningExposures.append(LearningExposure(conceptID: conceptID, questionID: questionID,
            presentationID: presentation.id, contentVersion: version, kind: .question, date: date))
        return presentation
    }

    static func recordHelp(presentationID: UUID, progress: inout LearningProgress, now: Date = Date()) throws {
        guard let presentation = progress.questionPresentations.first(where: { $0.id == presentationID }) else {
            throw ScoreError.missingPresentation
        }
        guard timestamp(now) >= presentation.date else { throw ScoreError.invalidClock }
        progress.learningExposures.append(LearningExposure(conceptID: presentation.conceptID,
            questionID: presentation.questionID, presentationID: presentationID,
            contentVersion: presentation.contentVersion, kind: .help, date: timestamp(now)))
    }

    static func submit(presentationID: UUID, selectedChoiceID: String, correct: Bool, usedHelp: Bool,
        progress: inout LearningProgress, now: Date = Date()) throws -> LearningScoreReceipt {
        // Idempotence preserves the original first submitted choice, even across relaunches.
        if let receipt = progress.scoreReceipts.first(where: { $0.presentationID == presentationID }) { return receipt }
        guard let presentation = progress.questionPresentations.first(where: { $0.id == presentationID }) else {
            throw ScoreError.missingPresentation
        }
        let date = timestamp(now)
        guard date >= presentation.date else { throw ScoreError.invalidClock }
        let eventsSincePresentation = progress.learningExposures.dropFirst(presentation.exposureCountAtPresentation)
        guard !eventsSincePresentation.contains(where: { $0.date > date }) else { throw ScoreError.invalidClock }
        let explicitHelpWasUsed = usedHelp || eventsSincePresentation.contains {
            $0.presentationID == presentationID && $0.kind == .help
        }
        let studiedSincePresentation = eventsSincePresentation.contains {
            $0.conceptID == presentation.conceptID && $0.isTeaching
        }
        let helpWasUsed = explicitHelpWasUsed || studiedSincePresentation
        let anotherQuestionWasShown = eventsSincePresentation.contains {
            $0.conceptID == presentation.conceptID && $0.kind == .question && $0.presentationID != presentationID
        }
        let lastCounted = progress.scoreReceipts.filter {
            $0.counted && $0.conceptID == presentation.conceptID && $0.contentVersion == presentation.contentVersion
        }.map(\.date).max()
        let anotherCheckCounted = lastCounted.map { date.timeIntervalSince($0) < day } ?? false
        let counted = presentation.eligibility.canCount && !helpWasUsed && !studiedSincePresentation &&
            !anotherQuestionWasShown && !anotherCheckCounted
        let prior = summary(progress: progress, now: date).slots.first { $0.id == presentation.questionID }?.status ?? .unknown
        let newStatus: LearningScoreStatus = counted ? (correct ? .correct : .incorrect) : prior
        let delta = (newStatus == .correct ? 10 : 0) - (prior == .correct ? 10 : 0)
        let reason: String
        if explicitHelpWasUsed {
            reason = "No score change: help was used before submitting. This practice still counts for review planning."
        } else if studiedSincePresentation {
            reason = "No score change: relevant teaching or feedback was opened during this check."
        } else if anotherQuestionWasShown {
            reason = "No score change: another question for this concept was shown while this check was open."
        } else if anotherCheckCounted {
            reason = "No score change: a check for this concept already counted within 24 hours."
        } else if !presentation.eligibility.canCount {
            reason = presentation.eligibility.reason
        } else if delta > 0 {
            reason = "+10: this designated check was answered correctly without help after the required delay."
        } else if delta < 0 {
            reason = "−10: the latest answer to this check was incorrect. The earlier result remains in your history."
        } else if correct {
            reason = "No score change: this check is still correct; its evidence date was refreshed."
        } else {
            reason = "No score change: this check is recorded as incorrect and had no points to remove."
        }
        let receipt = LearningScoreReceipt(presentationID: presentationID, conceptID: presentation.conceptID,
            questionID: presentation.questionID, contentVersion: presentation.contentVersion, date: date,
            correct: correct, usedHelp: helpWasUsed, counted: counted, delta: delta, reason: reason,
            previousStatus: prior, newStatus: newStatus)
        progress.attempts.append(LearningAttempt(conceptID: presentation.conceptID, questionID: presentation.questionID,
            selectedChoiceID: selectedChoiceID, correct: correct, usedHelp: helpWasUsed,
            isReview: presentation.isReview, date: date, presentationID: presentationID))
        progress.scoreReceipts.append(receipt)
        // The result screen reveals teaching feedback; it starts both exposure clocks again.
        progress.learningExposures.append(LearningExposure(conceptID: presentation.conceptID,
            questionID: presentation.questionID, presentationID: presentationID,
            contentVersion: presentation.contentVersion, kind: .answer, date: date))
        return receipt
    }

    private static func eligibility(conceptID: String, questionID: String, isReview: Bool, version: String,
        progress: LearningProgress, now: Date) -> LearningScoreEligibility {
        func no(_ reason: String, until: Date? = nil) -> LearningScoreEligibility {
            LearningScoreEligibility(canCount: false, reason: "No score change: " + reason, nextEligibleDate: until)
        }
        guard version == contentVersion, definitions.contains(where: { $0.conceptID == conceptID && $0.questionID == questionID }) else {
            return no("this is practice, outside the ten designated checks.")
        }
        guard isReview else { return no("lesson practice does not change the Physics check score.") }
        var boundaries: [Date] = []
        if let baseline = progress.legacyScoreBaselineAt { boundaries.append(baseline.addingTimeInterval(7 * day)) }
        let teaching = progress.learningExposures.filter {
            $0.conceptID == conceptID && $0.contentVersion == version && $0.isTeaching
        }.map(\.date).max()
        // The migration baseline anchors unknown history without inventing a historical learning date.
        guard let anchor = teaching ?? progress.legacyScoreBaselineAt else {
            return no("there is no recorded teaching or feedback exposure to establish a delayed check yet.")
        }
        boundaries.append(anchor.addingTimeInterval(day))
        if let lastSeen = progress.learningExposures.filter({ $0.questionID == questionID && $0.contentVersion == version }).map(\.date).max() {
            boundaries.append(lastSeen.addingTimeInterval(7 * day))
        }
        if let lastCounted = progress.scoreReceipts.filter({ $0.counted && $0.conceptID == conceptID && $0.contentVersion == version }).map(\.date).max() {
            boundaries.append(lastCounted.addingTimeInterval(day))
        }
        let next = boundaries.max()!
        guard now >= next else {
            return no("this check needs more spacing: 24 hours after teaching or a counted check, and seven days after this question was shown (or legacy tracking began).", until: next)
        }
        return LearningScoreEligibility(canCount: true,
            reason: "This designated review can affect the Physics check score if submitted without help.", nextEligibleDate: nil)
    }

    private static func beginTracking(progress: inout LearningProgress, now: Date) {
        guard progress.scoreTrackingStartedAt == nil else { return }
        if !progress.attempts.isEmpty || !progress.completedLessonIDs.isEmpty ||
            !progress.selfReportedLearned.isEmpty || progress.lastLessonID != nil {
            progress.legacyScoreBaselineAt = now
        }
        progress.scoreTrackingStartedAt = now
    }

    private static func timestamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    enum ScoreError: LocalizedError {
        case missingPresentation, invalidClock, mismatchedQuestion
        var errorDescription: String? {
            switch self {
            case .missingPresentation: return "The saved question presentation could not be found. Open the check again."
            case .invalidClock: return "The device time moved backwards during this check. Open the check again."
            case .mismatchedQuestion: return "This answer does not match the saved question presentation."
            }
        }
    }
}
