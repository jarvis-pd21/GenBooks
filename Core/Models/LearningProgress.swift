import Foundation

struct LearningPreferences: Codable, Equatable, Sendable {
    var sessionMinutes: Int = 10
    var goal: String = "Understand everyday physics"
    var prefersExamples: Bool = true
}

struct LearningAttempt: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var conceptID: String
    var questionID: String
    var selectedChoiceID: String
    var correct: Bool
    var usedHelp: Bool
    var isReview: Bool
    var date: Date = Date()
    var presentationID: UUID? = nil
}

struct LearningFeedback: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var lessonID: String
    var experience: Experience
    var date: Date = Date()

    enum Experience: String, Codable, CaseIterable, Sendable {
        case enjoyable, neutral, tooDemanding
    }
}

struct LearningProgress: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var preferences = LearningPreferences()
    var lastLessonID: String? = nil
    var completedLessonIDs: [String] = []
    var selfReportedLearned: [String: Date] = [:]
    var attempts: [LearningAttempt] = []
    var feedback: [LearningFeedback] = []
    var scoreTrackingStartedAt: Date? = nil
    var legacyScoreBaselineAt: Date? = nil
    var learningExposures: [LearningExposure] = []
    var questionPresentations: [LearningQuestionPresentation] = []
    var scoreReceipts: [LearningScoreReceipt] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, preferences, lastLessonID, completedLessonIDs, selfReportedLearned, attempts, feedback
        case scoreTrackingStartedAt, legacyScoreBaselineAt, learningExposures, questionPresentations, scoreReceipts
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Existing fields stay required: a damaged file is not silently replaced with empty progress.
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        preferences = try values.decode(LearningPreferences.self, forKey: .preferences)
        lastLessonID = try values.decodeIfPresent(String.self, forKey: .lastLessonID)
        completedLessonIDs = try values.decode([String].self, forKey: .completedLessonIDs)
        selfReportedLearned = try values.decode([String: Date].self, forKey: .selfReportedLearned)
        attempts = try values.decode([LearningAttempt].self, forKey: .attempts)
        feedback = try values.decode([LearningFeedback].self, forKey: .feedback)
        scoreTrackingStartedAt = try values.decodeIfPresent(Date.self, forKey: .scoreTrackingStartedAt)
        legacyScoreBaselineAt = try values.decodeIfPresent(Date.self, forKey: .legacyScoreBaselineAt)
        learningExposures = try values.decodeIfPresent([LearningExposure].self, forKey: .learningExposures) ?? []
        questionPresentations = try values.decodeIfPresent([LearningQuestionPresentation].self, forKey: .questionPresentations) ?? []
        scoreReceipts = try values.decodeIfPresent([LearningScoreReceipt].self, forKey: .scoreReceipts) ?? []
    }
}
