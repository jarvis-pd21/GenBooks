import Foundation

// MARK: - Finish / Feedback

enum FeedbackOverallRating: String, Codable, CaseIterable, Identifiable, Sendable {
    case excellent
    case fine
    case needsImprovement

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .excellent: return "Excellent"
        case .fine: return "Fine"
        case .needsImprovement: return "Needs improvement"
        }
    }
}

enum FeedbackMoreTopic: String, Codable, CaseIterable, Identifiable, Sendable {
    case stories
    case globalContext
    case economics
    case placesIllVisit
    case explanation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stories: return "Stories"
        case .globalContext: return "Global context"
        case .economics: return "Economics"
        case .placesIllVisit: return "Places I’ll visit"
        case .explanation: return "Explanation"
        }
    }
}

enum FeedbackLessTopic: String, Codable, CaseIterable, Identifiable, Sendable {
    case names
    case dates
    case politicalDetail
    case repetition

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .names: return "Names"
        case .dates: return "Dates"
        case .politicalDetail: return "Political detail"
        case .repetition: return "Repetition"
        }
    }
}

/// Explicit post-Finish feedback for one consumed chapter revision.
struct ChapterFeedback: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var chapterId: UUID
    var revisionId: UUID
    var overall: FeedbackOverallRating
    var moreOf: [FeedbackMoreTopic]
    var lessOf: [FeedbackLessTopic]
    var freeText: String
    var createdAt: Date
}

// MARK: - Preference profile (inspectable updates only)

/// Reader taste profile. Mutate only via `ReaderPreferenceEngine.apply(feedback:)`.
struct ReaderPreferenceProfile: Codable, Equatable, Hashable, Sendable {
    var bookId: UUID
    var moreWeights: [String: Double]
    var lessWeights: [String: Double]
    var overallTone: String
    var freeTextNotes: [String]
    var updatedAt: Date
    /// Inspectable changelog of preference mutations (newest last).
    var changeLog: [PreferenceChangeRecord]

    static func empty(bookId: UUID, at date: Date = Date()) -> ReaderPreferenceProfile {
        ReaderPreferenceProfile(
            bookId: bookId,
            moreWeights: Dictionary(uniqueKeysWithValues: FeedbackMoreTopic.allCases.map { ($0.rawValue, 0.5) }),
            lessWeights: Dictionary(uniqueKeysWithValues: FeedbackLessTopic.allCases.map { ($0.rawValue, 0.5) }),
            overallTone: "neutral",
            freeTextNotes: [],
            updatedAt: date,
            changeLog: []
        )
    }
}

struct PreferenceChangeRecord: Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var at: Date
    var feedbackId: UUID
    var summary: String
    var details: [String]
}

// MARK: - Apply length (GenAB #65 + #67)

/// Living Apply / Make Living length. **Half-length is the product default;** Full is opt-in.
enum AdaptationLengthPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case half
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .half: return "Half-length"
        case .full: return "Full"
        }
    }

    static let applyDefault: AdaptationLengthPreset = .half

    var wordCountFraction: Double {
        switch self {
        case .half: return 0.5
        case .full: return 1.0
        }
    }

    func scaledWordCount(_ fullCount: Int) -> Int {
        max(20, Int((Double(max(0, fullCount)) * wordCountFraction).rounded()))
    }

    func impliedFullWordCount(fromScaled scaled: Int) -> Int {
        switch self {
        case .full: return max(20, scaled)
        case .half: return max(20, scaled * 2)
        }
    }
}

// MARK: - Adaptation plan (Stage 1)

struct AdaptationChapterTarget: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID { chapterId }
    var chapterId: UUID
    var chapterTitle: String
    var currentWordCount: Int
    var targetWordCount: Int
    var desiredChanges: [String]
    var mustRemainConcepts: [String]
}

struct AdaptationPlan: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var bookId: UUID
    var createdAt: Date
    var sourceFeedbackId: UUID
    var preferenceUpdatesSummary: [String]
    var affectedChapterIds: [UUID]
    var chapterTargets: [AdaptationChapterTarget]
    var continuityNotes: [String]
    var reasonsFromFeedback: [String]
    /// Chapters that must NOT be rewritten (consumed / locked).
    var lockedChapterIds: [UUID]
    var isValidated: Bool
    /// When set, Apply enforces remaining reading-time within tolerance of this baseline (minutes).
    var readingTimeBaselineMinutes: Double? = nil
    /// Preferences captured with a reading-time-sensitive plan so Apply uses the preview's WPM.
    var readingTimePreferences: ReadingTimePreferences? = nil
    /// Fact-gate readiness for the planned chapters, surfaced in the Plan → Apply review.
    var factGateNotes: [String]? = nil
    /// Apply length used to compute `chapterTargets`. Nil on older in-memory plans means Full.
    var lengthPreset: AdaptationLengthPreset? = nil

    var resolvedLengthPreset: AdaptationLengthPreset { lengthPreset ?? .full }

    /// Recompute word targets when the reader flips Half ↔ Full on the Apply sheet.
    func retargeted(from old: AdaptationLengthPreset, to new: AdaptationLengthPreset) -> AdaptationPlan {
        guard old != new else {
            var copy = self
            copy.lengthPreset = new
            return copy
        }
        var copy = self
        copy.lengthPreset = new
        copy.chapterTargets = chapterTargets.map { target in
            var next = target
            next.targetWordCount = new.scaledWordCount(old.impliedFullWordCount(fromScaled: target.targetWordCount))
            return next
        }
        if let baseline = readingTimeBaselineMinutes {
            let fullMinutes = old == .full ? baseline : baseline / max(old.wordCountFraction, 0.01)
            copy.readingTimeBaselineMinutes = new == .full ? fullMinutes : fullMinutes * new.wordCountFraction
        }
        return copy
    }
}

struct AdaptationPlanRequest: Sendable {
    var book: Book
    var feedback: ChapterFeedback
    var profile: ReaderPreferenceProfile
    var lockedChapterIds: [UUID]
    var unreadChapters: [UnreadChapterSnapshot]
    /// Prefer adapting the next 1–2 unread chapters only.
    var maxChaptersToAdapt: Int
    /// Reader brief + continuity + fact checklist handed to the Astra prompt.
    var packet: PEContinuityPacket? = nil
    /// UI default is Half; callers that omit this keep Full so existing time-preserving tests stay intact.
    var lengthPreset: AdaptationLengthPreset = .full
}

struct UnreadChapterSnapshot: Equatable, Sendable {
    var id: UUID
    var title: String
    var orderIndex: Int
    var currentWordCount: Int
    var plainText: String
}

struct AdaptationGenerateRequest: Sendable {
    var book: Book
    var plan: AdaptationPlan
    var chapterId: UUID
    var chapterTitle: String
    var currentPlainText: String
    var target: AdaptationChapterTarget
    var profile: ReaderPreferenceProfile
    var continuityNotes: [String]
    /// Reader brief + continuity + fact checklist handed to the Astra prompt.
    var packet: PEContinuityPacket? = nil
    /// Present when only the stretch after a word anchor is being rewritten. The model
    /// continues from the frozen tail and must never restate or revise it.
    var anchorContext: WordAnchorPromptContext? = nil
}

enum AdaptationPhaseState: String, Codable, Equatable, Sendable {
    case idle
    case awaitingFeedback
    case planning
    case planReady
    case applying
    case applied
    case failed
    case cancelled
}

enum AdaptationError: Error, Equatable, LocalizedError, Sendable {
    case invalidPlan(String)
    case lockedChapter(UUID)
    case illegalChapterId(UUID)
    case wordCountOutOfRange(expected: Int, actual: Int)
    case continuityMissing([String])
    case malformedGeneration(String)
    case cancelled
    case nothingToAdapt
    case readingTimeGuardrailFailed(baselineMinutes: Double, plannedMinutes: Double, toleranceFraction: Double)
    case anchorMoved
    case frozenPrefixMutated
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .invalidPlan(let reason): return "Invalid adaptation plan: \(reason)"
        case .lockedChapter(let id): return "Chapter \(id) is locked/consumed and cannot be adapted"
        case .illegalChapterId(let id): return "Illegal chapter id in generation: \(id)"
        case .wordCountOutOfRange(let expected, let actual):
            return "Word count \(actual) outside sanity band for target \(expected)"
        case .continuityMissing(let concepts):
            return "Generated text missing required continuity concepts: \(concepts.joined(separator: ", "))"
        case .malformedGeneration(let reason): return "Malformed generation: \(reason)"
        case .cancelled: return "Adaptation cancelled"
        case .nothingToAdapt: return "No unread future chapters to adapt"
        case .readingTimeGuardrailFailed(let baseline, let planned, let tol):
            let pct = Int((tol * 100).rounded())
            return String(
                format: "Reading-time guardrail failed: planned %.1f min vs baseline %.1f min (±%d%%)",
                planned, baseline, pct
            )
        case .anchorMoved:
            return "This chapter changed after you picked that word — nothing was rewritten. Pick the word again."
        case .frozenPrefixMutated:
            return "Generation tried to rewrite text you already read — nothing was saved."
        case .underlying(let message): return message
        }
    }
}
