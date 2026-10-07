import Foundation

/// Explicit, inspectable preference updates — the only sanctioned mutator for `ReaderPreferenceProfile`.
enum ReaderPreferenceEngine {
    /// Applies chapter feedback and returns an updated profile plus a human-readable change record.
    static func apply(
        feedback: ChapterFeedback,
        to profile: ReaderPreferenceProfile,
        at date: Date = Date()
    ) -> ReaderPreferenceProfile {
        var next = profile
        var details: [String] = []

        switch feedback.overall {
        case .excellent:
            next.overallTone = "encourage_current_style"
            details.append("Overall excellent → tone set to encourage_current_style")
        case .fine:
            next.overallTone = "gentle_refine"
            details.append("Overall fine → tone set to gentle_refine")
        case .needsImprovement:
            next.overallTone = "substantive_rewrite_unread"
            details.append("Overall needs improvement → tone set to substantive_rewrite_unread")
        }

        for topic in feedback.moreOf {
            let key = topic.rawValue
            let before = next.moreWeights[key] ?? 0.5
            let after = min(1.0, before + 0.2)
            next.moreWeights[key] = after
            details.append("More of \(topic.displayName): \(String(format: "%.2f", before)) → \(String(format: "%.2f", after))")
        }
        for topic in feedback.lessOf {
            let key = topic.rawValue
            let before = next.lessWeights[key] ?? 0.5
            let after = min(1.0, before + 0.2)
            next.lessWeights[key] = after
            // Mildly damp conflicting "more" weight when user asks for less of related density.
            if topic == .names || topic == .dates || topic == .politicalDetail {
                let dampKey = FeedbackMoreTopic.explanation.rawValue
                let mBefore = next.moreWeights[dampKey] ?? 0.5
                // no-op damp; keep inspectable note only if explanation was maxed
                if mBefore > 0.9 {
                    details.append("Note: high explanation weight retained despite less \(topic.displayName)")
                }
            }
            details.append("Less of \(topic.displayName): \(String(format: "%.2f", before)) → \(String(format: "%.2f", after))")
        }

        let trimmed = feedback.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            next.freeTextNotes.append(trimmed)
            if next.freeTextNotes.count > 20 {
                next.freeTextNotes = Array(next.freeTextNotes.suffix(20))
            }
            details.append("Free-text note recorded (\(trimmed.count) chars)")
        }

        let summary: String
        if details.isEmpty {
            summary = "Feedback recorded with no weight changes"
        } else {
            summary = "Applied feedback for chapter \(feedback.chapterId.uuidString.prefix(8))…"
        }

        let record = PreferenceChangeRecord(
            id: UUID(),
            at: date,
            feedbackId: feedback.id,
            summary: summary,
            details: details
        )
        next.changeLog.append(record)
        if next.changeLog.count > 50 {
            next.changeLog = Array(next.changeLog.suffix(50))
        }
        next.updatedAt = date
        return next
    }

    static func summaryLine(for profile: ReaderPreferenceProfile) -> String {
        let more = profile.moreWeights
            .filter { $0.value >= 0.65 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }
        let less = profile.lessWeights
            .filter { $0.value >= 0.65 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }
        let moreBit = more.isEmpty ? "none" : more.joined(separator: ",")
        let lessBit = less.isEmpty ? "none" : less.joined(separator: ",")
        return "tone=\(profile.overallTone); more=[\(moreBit)]; less=[\(lessBit)]"
    }
}
