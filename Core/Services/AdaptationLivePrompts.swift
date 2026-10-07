import Foundation

/// Astra (`gpt-6-astra`) prompt assembly and JSON decoding for the two
/// adaptation stages. Foundation-only so it can be type-checked without a Mac
/// toolchain; the transport lives in `LiveOpenAIService`.
///
/// User messages are assembled packet-first: the PE packet
/// (brief → continuity → facts) states the standing contract, then the
/// stage-specific task follows. See `PEPacketPromptAssembler`.
enum AdaptationLivePrompts {
    static let planSystem = """
    You are the GenBooks adaptation planner. Return ONLY valid JSON (no markdown fences) matching:
    {
      "preferenceUpdatesSummary": [string],
      "chapterTargets": [{
        "chapterId": "uuid-string",
        "chapterTitle": string,
        "currentWordCount": int,
        "targetWordCount": int,
        "desiredChanges": [string],
        "mustRemainConcepts": [string]
      }],
      "continuityNotes": [string],
      "reasonsFromFeedback": [string]
    }
    Rules: only adapt unread chapters listed in the request; never include locked chapterIds;
    preserve continuity concepts; plan-before-mutate (do not rewrite book text here).

    \(PEPacketPromptAssembler.promptRules)
    """

    static let generateSystem = """
    You are the GenBooks chapter rewriter. Return ONLY valid JSON (no markdown fences):
    {
      "blocks": [{"kind": "heading"|"paragraph"|"quote"|"callout"|"imagePlaceholder", "text": string}],
      "continuityDelta": {
        "digest": string,
        "establishedFacts": [string],
        "openThreads": [string],
        "resolvedThreads": [string]
      },
      "factClaims": [{"claimId": "existing-verified-claim-uuid"} | {
        "statement": string,
        "importance": "essential"|"supporting",
        "status": "unverified"|"disputed",
        "evidenceIds": [string]
      }],
      "evidence": [{"id": string, "sourceLabel": string, "digest": string, "locator": string}]
    }
    Only "blocks" is required. Omit "factClaims" rather than asserting a fact you cannot evidence.
    Claims and evidence you propose are unverified; only existing independently checked records can retain verified status.
    To reuse a verified claim from Packet C for this chapter, return only its "claimId". The client copies its exact stored identity;
    any supplied bookId, chapterId, statement, importance or evidenceIds must match that record. Do not recreate its evidence.
    Rules: rewrite ONLY the requested unread chapter; keep mustRemainConcepts present in the text;
    aim near targetWordCount; never invent locked/consumed chapter changes; include a short [Adapted] marker in an early paragraph.

    \(PEPacketPromptAssembler.promptRules)
    """

    static let continueFromWordSystem = """
    You are the GenBooks continuation writer. Return ONLY valid JSON (no markdown fences):
    {
      "blocks": [{"kind": "heading"|"paragraph"|"quote"|"callout"|"imagePlaceholder", "text": string}],
      "continuityDelta": {
        "digest": string,
        "establishedFacts": [string],
        "openThreads": [string],
        "resolvedThreads": [string]
      },
      "factClaims": [{"claimId": "existing-verified-claim-uuid"} | {
        "statement": string,
        "importance": "essential"|"supporting",
        "status": "unverified"|"disputed",
        "evidenceIds": [string]
      }],
      "evidence": [{"id": string, "sourceLabel": string, "digest": string, "locator": string}]
    }
    Only "blocks" is required. Omit "factClaims" rather than asserting a fact you cannot evidence.
    Claims and evidence you propose are unverified; only existing independently checked records can retain verified status.
    To reuse a verified claim from Packet C for this chapter, return only its "claimId". The client copies its exact stored identity;
    any supplied bookId, chapterId, statement, importance or evidenceIds must match that record. Do not recreate its evidence.
    You are given the tail of text the reader has ALREADY read, INCLUDING the complete anchor word
    and its following punctuation/spacing. Rules: write ONLY the continuation AFTER that frozen text;
    never repeat the anchor word as an opening, restate, summarise or revise the frozen tail. Keep every
    mustRemainConcept present; aim near targetWordCount; emit exactly plannedVisualCount
    imagePlaceholder blocks with concrete captions; never mention chapters the reader has finished.

    \(PEPacketPromptAssembler.promptRules)
    """

    static func planUser(_ request: AdaptationPlanRequest) -> String {
        let unread = request.unreadChapters.prefix(max(1, request.maxChaptersToAdapt)).map { ch in
            """
            - id=\(ch.id.uuidString) title=\(ch.title) words=\(ch.currentWordCount)
              excerpt: \(String(ch.plainText.prefix(800)))
            """
        }.joined(separator: "\n")
        let locked = request.lockedChapterIds.map(\.uuidString).joined(separator: ", ")
        let more = request.feedback.moreOf.map(\.rawValue).joined(separator: ", ")
        let less = request.feedback.lessOf.map(\.rawValue).joined(separator: ", ")
        let task = """
        [TASK — PLAN]
        Book: \(request.book.title) by \(request.book.author) (bookId=\(request.book.id.uuidString))
        Feedback overall=\(request.feedback.overall.rawValue) more=[\(more)] less=[\(less)]
        Free text: \(request.feedback.freeText)
        Preference summary: \(ReaderPreferenceEngine.summaryLine(for: request.profile))
        Locked chapterIds (DO NOT ADAPT): [\(locked)]
        Length preset: \(request.lengthPreset.displayName) (return a FULL-chapter targetWordCount; the client scales Half)
        Unread candidates (adapt at most \(request.maxChaptersToAdapt)):
        \(unread)
        sourceFeedbackId=\(request.feedback.id.uuidString)
        """
        return assemble(packet: PEPacketPromptAssembler.render(request.packet), task: task)
    }

    static func generateUser(_ request: AdaptationGenerateRequest) -> String {
        let header = """
        [TASK — GENERATE]
        Book: \(request.book.title)
        Chapter id=\(request.chapterId.uuidString) title=\(request.chapterTitle)
        Target words=\(request.target.targetWordCount) current excerpt words≈\(AdaptationPlanValidator.wordCount(of: request.currentPlainText))
        Desired changes: \(request.target.desiredChanges.joined(separator: "; "))
        Must remain concepts: \(request.target.mustRemainConcepts.joined(separator: "; "))
        Continuity notes: \(request.continuityNotes.joined(separator: "; "))
        Profile: \(ReaderPreferenceEngine.summaryLine(for: request.profile))
        """
        let task: String
        if let anchor = request.anchorContext {
            task = header + """

            Anchor word (already frozen; do not repeat it as the opening): \(anchor.anchorWord)
            Reader request: \(anchor.userRequest)
            Reader request detail: \(anchor.requestLines.joined(separator: "; "))
            Reader preferences: \(anchor.readerPreferencesSummary)
            plannedVisualCount=\(anchor.plannedVisualCount)
            FROZEN — already read, \(anchor.frozenPrefixWordCount) words including the anchor. Do not rewrite or repeat:
            \(anchor.frozenPrefixTail)
            REPLACING — only the text after the frozen boundary:
            \(String(request.currentPlainText.prefix(6000)))
            """
        } else {
            task = header + """

            Current plain text:
            \(String(request.currentPlainText.prefix(6000)))
            """
        }
        let packet = PEPacketPromptAssembler.render(
            request.packet,
            focusChapterId: request.chapterId
        )
        return assemble(packet: packet, task: task)
    }

    private static func assemble(packet: String, task: String) -> String {
        packet.isEmpty ? task : packet + "\n\n" + task
    }

    // MARK: - Wire decoding

    private struct PlanWire: Decodable {
        var preferenceUpdatesSummary: [String]?
        var chapterTargets: [TargetWire]
        var continuityNotes: [String]?
        var reasonsFromFeedback: [String]?
    }

    private struct TargetWire: Decodable {
        var chapterId: String
        var chapterTitle: String?
        var currentWordCount: Int?
        var targetWordCount: Int
        var desiredChanges: [String]?
        var mustRemainConcepts: [String]?
    }

    private struct GenerationWire: Decodable {
        var blocks: [BlockWire]
        var continuityDelta: ContinuityDeltaWire?
        var factClaims: [ClaimWire]?
        var evidence: [EvidenceWire]?
    }

    private struct BlockWire: Decodable {
        var kind: String?
        var text: String
    }

    private struct ContinuityDeltaWire: Decodable {
        var digest: String?
        var establishedFacts: [String]?
        var openThreads: [String]?
        var resolvedThreads: [String]?
    }

    private struct ClaimWire: Decodable {
        var claimId: String?
        var bookId: String?
        var chapterId: String?
        var statement: String?
        var importance: String?
        var status: String?
        var evidenceIds: [String]?

        private enum CodingKeys: String, CodingKey {
            case claimId, bookId, chapterId, statement, importance, status, evidenceIds
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // Omitted identity fields are allowed for references; explicit null
            // is malformed, not permission to ignore a supplied identity field.
            claimId = try values.contains(.claimId) ? values.decode(String.self, forKey: .claimId) : nil
            bookId = try values.contains(.bookId) ? values.decode(String.self, forKey: .bookId) : nil
            chapterId = try values.contains(.chapterId) ? values.decode(String.self, forKey: .chapterId) : nil
            statement = try values.contains(.statement) ? values.decode(String.self, forKey: .statement) : nil
            importance = try claimId != nil && values.contains(.importance)
                ? values.decode(String.self, forKey: .importance)
                : values.decodeIfPresent(String.self, forKey: .importance)
            status = try values.decodeIfPresent(String.self, forKey: .status)
            evidenceIds = try claimId != nil && values.contains(.evidenceIds)
                ? values.decode([String].self, forKey: .evidenceIds)
                : values.decodeIfPresent([String].self, forKey: .evidenceIds)
        }
    }

    private struct EvidenceWire: Decodable {
        var id: String
        var sourceLabel: String?
        var digest: String?
        var locator: String?
    }

    static func decodePlan(_ content: String, request: AdaptationPlanRequest) throws -> AdaptationPlan {
        let data = try jsonData(from: content)
        let wire = try JSONDecoder().decode(PlanWire.self, from: data)
        guard !wire.chapterTargets.isEmpty else {
            throw AIServiceError.malformedResponse
        }
        let unreadById = Dictionary(uniqueKeysWithValues: request.unreadChapters.map { ($0.id, $0) })
        var targets: [AdaptationChapterTarget] = []
        for t in wire.chapterTargets {
            guard let id = UUID(uuidString: t.chapterId) else {
                throw AIServiceError.malformedResponse
            }
            let snapshot = unreadById[id]
            targets.append(
                AdaptationChapterTarget(
                    chapterId: id,
                    chapterTitle: t.chapterTitle ?? snapshot?.title ?? "Chapter",
                    currentWordCount: t.currentWordCount ?? snapshot?.currentWordCount ?? 0,
                    targetWordCount: request.lengthPreset.scaledWordCount(max(20, t.targetWordCount)),
                    desiredChanges: t.desiredChanges ?? [],
                    mustRemainConcepts: t.mustRemainConcepts ?? []
                )
            )
        }
        return AdaptationPlan(
            id: UUID(),
            bookId: request.book.id,
            createdAt: Date(),
            sourceFeedbackId: request.feedback.id,
            preferenceUpdatesSummary: wire.preferenceUpdatesSummary ?? [
                ReaderPreferenceEngine.summaryLine(for: request.profile)
            ],
            affectedChapterIds: targets.map(\.chapterId),
            chapterTargets: targets,
            continuityNotes: wire.continuityNotes ?? ["Do not alter consumed chapters"],
            reasonsFromFeedback: wire.reasonsFromFeedback ?? [],
            lockedChapterIds: request.lockedChapterIds,
            isValidated: false,
            lengthPreset: request.lengthPreset
        )
    }

    static func decodeBlocks(_ content: String) throws -> [ContentBlock] {
        let data = try jsonData(from: content)
        let wire = try JSONDecoder().decode(GenerationWire.self, from: data)
        return try blocks(from: wire.blocks)
    }

    /// Full Stage-2 payload: prose plus the continuity and facts the model says
    /// back it. The continuity entry's `revisionId` is stamped by the caller
    /// once activation has produced a real revision.
    static func decodeGeneration(
        _ content: String,
        request: AdaptationGenerateRequest,
        at date: Date = Date()
    ) throws -> GeneratedChapter {
        let data = try jsonData(from: content)
        let wire = try JSONDecoder().decode(GenerationWire.self, from: data)
        let decodedBlocks = try blocks(from: wire.blocks)

        var delta: ContinuityDelta?
        if let incoming = wire.continuityDelta {
            let chapter = request.book.chapters.first { $0.id == request.chapterId }
            let digest = incoming.digest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let entry = ContinuityEntry(
                id: UUID(),
                chapterId: request.chapterId,
                chapterTitle: chapter?.title ?? request.chapterTitle,
                chapterOrderIndex: chapter?.orderIndex ?? 0,
                revisionId: UUID(),
                digest: digest.isEmpty
                    ? decodedBlocks.map(\.text).joined(separator: " ")
                    : digest,
                establishedFacts: incoming.establishedFacts ?? request.target.mustRemainConcepts,
                openThreads: incoming.openThreads ?? [],
                isConsumed: false,
                recordedAt: date
            )
            delta = ContinuityDelta(
                bookId: request.book.id,
                entries: [entry],
                resolvedThreads: incoming.resolvedThreads ?? [],
                newThreads: incoming.openThreads ?? []
            )
        }

        let claims: [FactClaim] = try (wire.factClaims ?? []).compactMap { claim in
            if let bookId = claim.bookId, UUID(uuidString: bookId) != request.book.id {
                throw AIServiceError.malformedResponse
            }
            if let chapterId = claim.chapterId, UUID(uuidString: chapterId) != request.chapterId {
                throw AIServiceError.malformedResponse
            }
            if let reference = claim.claimId {
                guard let id = UUID(uuidString: reference),
                      let checklist = request.packet?.facts,
                      checklist.bookId == request.book.id,
                      let existing = checklist.claims.first(where: { $0.id == id }),
                      existing.status == .verified,
                      existing.chapterId == request.chapterId,
                      claim.statement.map({ $0 == existing.statement }) ?? true,
                      claim.importance.map({ $0 == existing.importance.rawValue }) ?? true,
                      claim.evidenceIds.map({ Set($0) == Set(existing.evidenceIds) }) ?? true else {
                    throw AIServiceError.malformedResponse
                }
                // Reference the packet's exact identity, never its verification.
                // The later merge with the current stored checklist decides if
                // that identity is still vetted or proposed evidence conflicts.
                var proposal = existing
                proposal.status = .unverified
                proposal.updatedAt = date
                return proposal
            }
            guard let rawStatement = claim.statement else { throw AIServiceError.malformedResponse }
            let statement = rawStatement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty else { return nil }
            return FactClaim(
                id: FactClaim.stableId(chapterId: request.chapterId, statement: statement),
                chapterId: request.chapterId,
                statement: statement,
                // An unrecognised importance is treated as load-bearing: the gate
                // should err toward blocking, not toward shipping unchecked prose.
                importance: FactClaimImportance(rawValue: claim.importance ?? "") ?? .essential,
                // The model cannot attest that its own claim was checked.
                status: claim.status == FactVerificationStatus.disputed.rawValue ? .disputed : .unverified,
                evidenceIds: (claim.evidenceIds ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                updatedAt: date
            )
        }

        let evidence: [FactEvidenceItem] = (wire.evidence ?? []).compactMap { item in
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            return FactEvidenceItem(
                id: id,
                sourceLabel: item.sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id,
                digest: item.digest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                locator: item.locator,
                recordedAt: date
            )
        }

        return GeneratedChapter(
            blocks: decodedBlocks,
            continuityDelta: delta,
            proposedClaims: claims,
            proposedEvidence: evidence
        )
    }

    private static func blocks(from wire: [BlockWire]) throws -> [ContentBlock] {
        guard !wire.isEmpty else { throw AIServiceError.malformedResponse }
        var blocks: [ContentBlock] = []
        for (idx, b) in wire.enumerated() {
            let text = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let kind = ContentBlockKind(rawValue: b.kind ?? "paragraph") ?? .paragraph
            blocks.append(ContentBlock(id: UUID(), kind: kind, text: text, orderIndex: idx))
        }
        guard !blocks.isEmpty else { throw AIServiceError.malformedResponse }
        for i in blocks.indices { blocks[i].orderIndex = i }
        return blocks
    }

    private static func jsonData(from content: String) throws -> Data {
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            trimmed = trimmed.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let data = trimmed.data(using: .utf8) else { throw AIServiceError.malformedResponse }
        return data
    }
}
