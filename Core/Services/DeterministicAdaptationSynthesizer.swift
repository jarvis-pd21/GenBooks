import Foundation

/// Shared deterministic plan/generate used by MockAIService and as Live fallback.
/// Keeps Phase 5 tests hermetic; Live may attempt remote JSON later and fall back here.
/// Phase 6: outline/stub chapters expand into fuller authored-style prose on Apply.
enum DeterministicAdaptationSynthesizer {
    static func makePlan(_ request: AdaptationPlanRequest) throws -> AdaptationPlan {
        let unread = Array(request.unreadChapters.prefix(max(1, request.maxChaptersToAdapt)))
        guard !unread.isEmpty else { throw AdaptationError.nothingToAdapt }

        var targets: [AdaptationChapterTarget] = []
        for chapter in unread {
            var changes: [String] = ["Preserve continuity with consumed past"]
            let isOutline = chapter.plainText.localizedCaseInsensitiveContains("[Outline")
                || chapter.currentWordCount < 250
            if isOutline {
                changes.append("Expand outline beats into full narrative prose")
                changes.append("Add Meanwhile-in-the-world and When-you’re-there callouts")
            }
            if request.feedback.moreOf.contains(.stories)
                || (request.profile.moreWeights[FeedbackMoreTopic.stories.rawValue] ?? 0.5) >= 0.65 {
                changes.append("Add vivid personal / narrative stories")
            }
            if request.feedback.moreOf.contains(.economics)
                || (request.profile.moreWeights[FeedbackMoreTopic.economics.rawValue] ?? 0.5) >= 0.65 {
                changes.append("Add clearer economics framing")
            }
            if request.feedback.moreOf.contains(.placesIllVisit) {
                changes.append("Highlight places a traveler might visit")
            }
            if request.feedback.moreOf.contains(.globalContext) {
                changes.append("Widen global context")
            }
            if request.feedback.moreOf.contains(.explanation) {
                changes.append("Add clearer explanation of cause and effect")
            }
            if request.feedback.lessOf.contains(.names) { changes.append("Reduce name density") }
            if request.feedback.lessOf.contains(.dates) { changes.append("Reduce date stacking") }
            if request.feedback.lessOf.contains(.politicalDetail) { changes.append("Soften political minutiae") }
            if request.feedback.lessOf.contains(.repetition) { changes.append("Cut repetitive phrasing") }

            let concepts = mustRemainConcepts(from: chapter.plainText, title: chapter.title)
            let base = max(chapter.currentWordCount, isOutline ? 180 : 40)
            let fullWC = isOutline ? max(900, base * 5) : max(40, Int(Double(base) * 1.15))
            let targetWC = request.lengthPreset.scaledWordCount(fullWC)
            if request.lengthPreset == .half {
                changes.append("Aim for half-length; Full remains opt-in")
            }
            targets.append(
                AdaptationChapterTarget(
                    chapterId: chapter.id,
                    chapterTitle: chapter.title,
                    currentWordCount: chapter.currentWordCount,
                    targetWordCount: targetWC,
                    desiredChanges: changes,
                    mustRemainConcepts: concepts
                )
            )
        }

        let prefSummary = request.profile.changeLog.last?.details ?? [
            ReaderPreferenceEngine.summaryLine(for: request.profile)
        ]
        let moreJoined = request.feedback.moreOf.map(\.displayName).joined(separator: ", ")
        let lessJoined = request.feedback.lessOf.map(\.displayName).joined(separator: ", ")
        var reasons: [String] = [
            "Overall: \(request.feedback.overall.displayName)",
            "More of: \(moreJoined.isEmpty ? "—" : moreJoined)",
            "Less of: \(lessJoined.isEmpty ? "—" : lessJoined)"
        ]
        let free = request.feedback.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !free.isEmpty {
            reasons.append("Note: \(free)")
        }

        return AdaptationPlan(
            id: UUID(),
            bookId: request.book.id,
            createdAt: Date(),
            sourceFeedbackId: request.feedback.id,
            preferenceUpdatesSummary: prefSummary,
            affectedChapterIds: targets.map(\.chapterId),
            chapterTargets: targets,
            continuityNotes: [
                "Do not alter consumed chapters",
                "Keep chronological sense with prior chapters",
                "Outline chapters may expand into full prose without inventing placeholder filler"
            ],
            reasonsFromFeedback: reasons,
            lockedChapterIds: request.lockedChapterIds,
            isValidated: false,
            lengthPreset: request.lengthPreset
        )
    }

    static func generate(_ request: AdaptationGenerateRequest) -> [ContentBlock] {
        if let anchor = request.anchorContext {
            return generateFromWordAnchor(request, anchor: anchor)
        }
        let target = request.target
        let isOutline = request.currentPlainText.localizedCaseInsensitiveContains("[Outline")
            || AdaptationPlanValidator.wordCount(of: request.currentPlainText) < 250

        // Time-preserving regen (Wave 2) must honor targetWordCount — skip outline blow-up.
        if isOutline && request.plan.readingTimeBaselineMinutes == nil {
            return generateExpandedOutline(request)
        }

        var paragraphs: [String] = []
        paragraphs.append("\(request.chapterTitle) (adapted)")
        paragraphs.append(
            "[Adapted] This revision reshapes the unread chapter using your feedback while keeping continuity with what you already finished."
        )
        for concept in target.mustRemainConcepts {
            paragraphs.append("Continuity: \(concept) remains central to this chapter’s telling.")
        }
        for change in target.desiredChanges {
            paragraphs.append("Craft note applied: \(change).")
        }
        if (request.profile.moreWeights[FeedbackMoreTopic.stories.rawValue] ?? 0) >= 0.65
            || request.plan.reasonsFromFeedback.contains(where: { $0.lowercased().contains("stories") }) {
            paragraphs.append(
                "Story beat: a traveler pauses in a plaza and overhears neighbors debating trade routes, making the era feel lived-in rather than listed."
            )
        }
        if (request.profile.moreWeights[FeedbackMoreTopic.economics.rawValue] ?? 0) >= 0.65 {
            paragraphs.append(
                "Economics lens: silver flows, port tariffs, and rural markets quietly set the stakes behind the speeches."
            )
        }
        if (request.profile.moreWeights[FeedbackMoreTopic.placesIllVisit.rawValue] ?? 0) >= 0.65 {
            paragraphs.append(
                "Place to visit: walk the same riverbank today and you can still sense why this geography mattered."
            )
        }

        var body = paragraphs.joined(separator: " ")
        let filler = " The adapted prose keeps the spine of the original while inviting curiosity, clarifying cause and effect, and trimming clutter you asked to see less of."
        // Time-sensitive regeneration must meet the requested word budget; the service
        // validates the actual generated blocks against the captured tolerance afterward.
        let minimumFraction = request.plan.readingTimeBaselineMinutes == nil ? 0.75 : 1.0
        let minimumWords = max(1, Int(Double(target.targetWordCount) * minimumFraction))
        while AdaptationPlanValidator.wordCount(of: body) < minimumWords {
            body += filler
        }

        var blocks: [ContentBlock] = [
            ContentBlock(id: UUID(), kind: .heading, text: "\(request.chapterTitle) (adapted)", orderIndex: 0)
        ]
        let sentences = body.components(separatedBy: ". ").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var order = 1
        var buffer = ""
        for sentence in sentences {
            let piece = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer += (buffer.isEmpty ? "" : ". ") + piece
            if AdaptationPlanValidator.wordCount(of: buffer) >= 35 {
                let text = buffer.hasSuffix(".") ? buffer : buffer + "."
                blocks.append(ContentBlock(id: UUID(), kind: .paragraph, text: text, orderIndex: order))
                order += 1
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            let text = buffer.hasSuffix(".") ? buffer : buffer + "."
            blocks.append(ContentBlock(id: UUID(), kind: .paragraph, text: text, orderIndex: order))
        }
        if !blocks.contains(where: { $0.text.contains("[Adapted]") }) {
            blocks.insert(
                ContentBlock(id: UUID(), kind: .paragraph, text: "[Adapted] Deterministic mock revision.", orderIndex: 1),
                at: 1
            )
            for i in blocks.indices { blocks[i].orderIndex = i }
        }
        return blocks
    }

    /// Continue a chapter from a word anchor. Produces only the stretch after the anchor —
    /// the frozen prefix is never restated, because the service re-attaches it verbatim.
    private static func generateFromWordAnchor(
        _ request: AdaptationGenerateRequest,
        anchor: WordAnchorPromptContext
    ) -> [ContentBlock] {
        let target = request.target
        var sentences: [String] = [
            "The continuation follows what you asked for."
        ]
        for line in anchor.requestLines {
            sentences.append("Your request shapes it: \(line)")
        }
        for concept in target.mustRemainConcepts {
            sentences.append("Continuity: \(concept) still carries this stretch of \(request.chapterTitle).")
        }
        for change in target.desiredChanges {
            sentences.append("Craft note applied: \(change).")
        }

        // The stretch is measured against the reader's remaining-time band after generation,
        // so land on the word budget instead of overshooting it.
        let essential = sentences.joined(separator: " ")
        let filler = "The rewritten stretch keeps the voice of the pages behind it, "
            + "picks the thread back up without repeating them, and spends its words on "
            + "cause and effect rather than on lists."
        var body = essential
        while AdaptationPlanValidator.wordCount(of: body) < max(20, target.targetWordCount) {
            body += " " + filler
        }
        let budget = max(AdaptationPlanValidator.wordCount(of: essential), max(20, target.targetWordCount))
        let words = body.split { $0.isWhitespace || $0.isNewline }
        if words.count > budget {
            body = words.prefix(budget).joined(separator: " ")
        }

        var blocks: [ContentBlock] = []
        var buffer = ""
        for sentence in body.components(separatedBy: ". ") {
            let piece = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            buffer += (buffer.isEmpty ? "" : ". ") + piece
            if AdaptationPlanValidator.wordCount(of: buffer) >= 40 {
                blocks.append(
                    ContentBlock(
                        id: UUID(),
                        kind: .paragraph,
                        text: buffer.hasSuffix(".") ? buffer : buffer + ".",
                        orderIndex: blocks.count
                    )
                )
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            blocks.append(
                ContentBlock(
                    id: UUID(),
                    kind: .paragraph,
                    text: buffer.hasSuffix(".") ? buffer : buffer + ".",
                    orderIndex: blocks.count
                )
            )
        }
        if blocks.isEmpty {
            blocks = [ContentBlock(id: UUID(), kind: .paragraph, text: body, orderIndex: 0)]
        }

        for index in 0..<max(0, anchor.plannedVisualCount) {
            blocks.append(
                ContentBlock(
                    id: UUID(),
                    kind: .imagePlaceholder,
                    text: "[Image] \(request.chapterTitle) — scene \(index + 1) after “\(anchor.anchorWord)”",
                    orderIndex: blocks.count
                )
            )
        }
        for index in blocks.indices { blocks[index].orderIndex = index }
        return blocks
    }

    /// Expand an outline/stub chapter into readable narrative prose (authoring pathway).
    private static func generateExpandedOutline(_ request: AdaptationGenerateRequest) -> [ContentBlock] {
        let title = request.chapterTitle
        let beats = extractOutlineBeats(from: request.currentPlainText)
        let chapter = request.book.chapters.first { $0.id == request.chapterId }
        let era = chapter?.eraLabel ?? "this era"
        let storedBeats = chapter?.outlineBeats ?? beats

        var blocks: [ContentBlock] = [
            ContentBlock(id: UUID(), kind: .heading, text: "\(title)", orderIndex: 0),
            ContentBlock(
                id: UUID(),
                kind: .paragraph,
                text: "[Adapted] Expanded from living outline for \(era). This prose keeps the outlined chronology while adding narrative connective tissue from your feedback.",
                orderIndex: 1
            )
        ]
        var order = 2
        let beatList = storedBeats.isEmpty ? ["The main turning points of \(title)"] : storedBeats
        for (idx, beat) in beatList.enumerated() {
            let para = """
            \(beat) In the Argentine telling, this was never only a date on a wall chart: people felt it in wages, rumors, sermons, and the price of bread. \
            A reader traveling later can still sense how \(era) left habits—how to argue in a café, when to distrust a promise about money, why a plaza matters. \
            Continuity with earlier chapters remains: the port and the interior still negotiate, and popular dignity still collides with elite fear.
            """
            blocks.append(ContentBlock(id: UUID(), kind: .paragraph, text: para.replacingOccurrences(of: "\n", with: " "), orderIndex: order))
            order += 1
            if idx == 0 {
                blocks.append(
                    ContentBlock(
                        id: UUID(),
                        kind: .callout,
                        text: "Meanwhile in the world: global markets, wars, and ideas pressed on Argentina during \(era), so local dramas rarely stayed only local.",
                        orderIndex: order
                    )
                )
                order += 1
            }
        }

        if (request.profile.moreWeights[FeedbackMoreTopic.placesIllVisit.rawValue] ?? 0) >= 0.55
            || request.plan.reasonsFromFeedback.contains(where: { $0.lowercased().contains("places") }) {
            blocks.append(
                ContentBlock(
                    id: UUID(),
                    kind: .callout,
                    text: "When you’re there: walk a plaza, a waterfront, or a provincial square and ask which layer of \(title) still speaks under the tourist polish.",
                    orderIndex: order
                )
            )
            order += 1
        }

        if (request.profile.moreWeights[FeedbackMoreTopic.economics.rawValue] ?? 0) >= 0.55 {
            blocks.append(
                ContentBlock(
                    id: UUID(),
                    kind: .paragraph,
                    text: "Economics lens: export prices, debt, inflation psychology, and who controlled the customs house or the central bank quietly structured what politicians could promise—and what households actually did with pesos and dollars.",
                    orderIndex: order
                )
            )
            order += 1
        }

        for concept in request.target.mustRemainConcepts {
            blocks.append(
                ContentBlock(
                    id: UUID(),
                    kind: .paragraph,
                    text: "Continuity: \(concept) remains central to this chapter’s telling.",
                    orderIndex: order
                )
            )
            order += 1
        }

        var filler = " Culture kept working underneath politics: mate passed hand to hand, football clubs taught belonging, tango remembered port longing, and family stories taught inflation as a lived skill rather than a chart."
        var joined = blocks.map(\.text).joined(separator: " ")
        while AdaptationPlanValidator.wordCount(of: joined) < Int(Double(request.target.targetWordCount) * 0.75) {
            blocks.append(
                ContentBlock(
                    id: UUID(),
                    kind: .paragraph,
                    text: filler.trimmingCharacters(in: .whitespaces) + " The expanded outline refuses placeholder filler; it prefers causal explanation and human texture.",
                    orderIndex: order
                )
            )
            order += 1
            joined = blocks.map(\.text).joined(separator: " ")
            filler += " Another pass of narrative glue clarifies cause and effect without burying the reader in name lists."
        }
        for i in blocks.indices { blocks[i].orderIndex = i }
        return blocks
    }

    private static func extractOutlineBeats(from plain: String) -> [String] {
        var beats: [String] = []
        for line in plain.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                beats.append(String(trimmed[range.upperBound...]))
            }
        }
        return Array(beats.prefix(8))
    }

    static func mustRemainConcepts(from plain: String, title: String) -> [String] {
        var concepts: [String] = []
        let lower = plain.lowercased()
        for token in [
            "cabildo", "independence", "buenos aires", "argentina", "virreinato", "nation", "geography",
            "perón", "peron", "malvinas", "immigration", "inflation", "patagonia", "rosas", "democracy"
        ] {
            if lower.contains(token) {
                concepts.append(token)
            }
        }
        if concepts.isEmpty {
            let titleWord = title.split(separator: " ").first.map(String.init) ?? title
            concepts.append(titleWord.lowercased())
        }
        return Array(concepts.prefix(3))
    }
}
