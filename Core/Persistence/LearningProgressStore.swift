import Foundation

final class LearningProgressStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.jarvis.livingreader.learning-progress")

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("learning.json")
    }

    func load() throws -> LearningProgress {
        try queue.sync { try loadUnlocked() }
    }

    func update(_ mutation: (inout LearningProgress) throws -> Void) throws -> LearningProgress {
        try queue.sync {
            // A bad existing file must fail before invoking the mutation or writing defaults.
            var candidate = try loadUnlocked()
            try mutation(&candidate)
            try validate(candidate)
            let data = try JSONCoding.encoder.encode(candidate)
            // Return exactly the representation persisted by the shared ISO-second codec.
            let persisted = try JSONCoding.decoder.decode(LearningProgress.self, from: data)
            try AtomicFileWriter.writeAtomically(data, to: fileURL)
            return persisted
        }
    }

    private func loadUnlocked() throws -> LearningProgress {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LearningProgress() }
        let data = try Data(contentsOf: fileURL)
        let progress = try JSONCoding.decoder.decode(LearningProgress.self, from: data)
        try validate(progress)
        return progress
    }

    private func validate(_ progress: LearningProgress) throws {
        guard progress.schemaVersion == 1 else { throw StoreError.unsupportedSchema }
        guard [5, 10, 20].contains(progress.preferences.sessionMinutes) else {
            throw StoreError.invalidProgress
        }
        func validID(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func validDate(_ value: Date) -> Bool { value.timeIntervalSinceReferenceDate.isFinite }
        guard progress.lastLessonID.map(validID) ?? true,
              progress.completedLessonIDs.allSatisfy(validID),
              progress.selfReportedLearned.allSatisfy({ validID($0.key) && validDate($0.value) }),
              Set(progress.attempts.map(\.id)).count == progress.attempts.count,
              Set(progress.feedback.map(\.id)).count == progress.feedback.count,
              progress.attempts.allSatisfy({
                  validID($0.conceptID) && validID($0.questionID) && validID($0.selectedChoiceID) && validDate($0.date)
              }),
              progress.feedback.allSatisfy({ validID($0.lessonID) && validDate($0.date) }) else {
            throw StoreError.invalidProgress
        }
        let presentations = Dictionary(progress.questionPresentations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let attemptPresentationIDs = progress.attempts.compactMap(\.presentationID)
        guard progress.scoreTrackingStartedAt.map(validDate) ?? true,
              progress.legacyScoreBaselineAt.map(validDate) ?? true,
              Set(progress.learningExposures.map(\.id)).count == progress.learningExposures.count,
              presentations.count == progress.questionPresentations.count,
              Set(progress.scoreReceipts.map(\.presentationID)).count == progress.scoreReceipts.count,
              Set(attemptPresentationIDs).count == attemptPresentationIDs.count,
              progress.questionPresentations.allSatisfy({ presentation in
                  guard validID(presentation.conceptID), validID(presentation.questionID),
                        validID(presentation.contentVersion), validDate(presentation.date),
                        presentation.exposureCountAtPresentation >= 0,
                        presentation.exposureCountAtPresentation < progress.learningExposures.count,
                        presentation.eligibility.nextEligibleDate.map(validDate) ?? true else { return false }
                  let event = progress.learningExposures[presentation.exposureCountAtPresentation]
                  return event.kind == .question && event.presentationID == presentation.id && event.date == presentation.date
              }),
              progress.learningExposures.allSatisfy({ exposure in
                  guard validID(exposure.conceptID), validID(exposure.contentVersion), validDate(exposure.date),
                        exposure.questionID.map(validID) ?? true else { return false }
                  if exposure.kind == .lesson { return exposure.questionID == nil && exposure.presentationID == nil }
                  guard let id = exposure.presentationID, let presentation = presentations[id] else { return false }
                  return exposure.conceptID == presentation.conceptID && exposure.questionID == presentation.questionID &&
                      exposure.contentVersion == presentation.contentVersion && exposure.date >= presentation.date
              }),
              progress.scoreReceipts.allSatisfy({ receipt in
                  guard let presentation = presentations[receipt.presentationID], validDate(receipt.date),
                        receipt.date >= presentation.date,
                        receipt.conceptID == presentation.conceptID, receipt.questionID == presentation.questionID,
                        receipt.contentVersion == presentation.contentVersion,
                        progress.attempts.contains(where: { $0.presentationID == receipt.presentationID &&
                            $0.conceptID == receipt.conceptID && $0.questionID == receipt.questionID &&
                            $0.correct == receipt.correct && $0.usedHelp == receipt.usedHelp && $0.date == receipt.date }) else { return false }
                  if receipt.counted {
                      return presentation.eligibility.canCount && !receipt.usedHelp &&
                          receipt.newStatus == (receipt.correct ? .correct : .incorrect) &&
                          receipt.delta == (receipt.newStatus == .correct ? 10 : 0) - (receipt.previousStatus == .correct ? 10 : 0)
                  }
                  return receipt.delta == 0 && receipt.previousStatus == receipt.newStatus
              }),
              attemptPresentationIDs.allSatisfy({ id in progress.scoreReceipts.contains { $0.presentationID == id } }),
              (progress.scoreTrackingStartedAt != nil ||
                  (progress.legacyScoreBaselineAt == nil && progress.learningExposures.isEmpty &&
                   progress.questionPresentations.isEmpty && progress.scoreReceipts.isEmpty)) else {
            throw StoreError.invalidProgress
        }
    }

    private enum StoreError: LocalizedError {
        case unsupportedSchema
        case invalidProgress

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema: return "This learning progress file uses an unsupported version."
            case .invalidProgress: return "The learning progress file contains invalid entries."
            }
        }
    }
}
