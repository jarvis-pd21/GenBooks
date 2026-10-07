import Foundation

/// Deterministic mock AI — never used on the critical reading path.
/// Tracks call counts so cold open tests can assert zero AI traffic.
final class MockAIService: AIService, @unchecked Sendable {
    var usesDeterministicGeneration: Bool { true }

    private let lock = NSLock()
    private var _adaptCallCount = 0
    private var _askCallCount = 0
    private var _lastAskRequest: AskRequest?
    private var _askHandler: ((AskRequest) async throws -> AskResponse)?
    private var _failNextGenerate = false
    private var _generateHandler: ((AdaptationGenerateRequest) async throws -> [ContentBlock])?
    private var _generateDelayNanoseconds: UInt64 = 0
    private var _planDelayNanoseconds: UInt64 = 0
    private var _packetHandler: ((AdaptationGenerateRequest) -> GeneratedChapter?)?
    private var _lastGenerateRequest: AdaptationGenerateRequest?
    private var _lastPlanRequest: AdaptationPlanRequest?

    var adaptCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _adaptCallCount
    }

    var askCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _askCallCount
    }

    var lastAskRequest: AskRequest? {
        lock.lock(); defer { lock.unlock() }
        return _lastAskRequest
    }

    /// Test seam: the PE packet the last plan / generate call actually received.
    var lastPlanRequest: AdaptationPlanRequest? {
        lock.lock(); defer { lock.unlock() }
        return _lastPlanRequest
    }

    var lastGenerateRequest: AdaptationGenerateRequest? {
        lock.lock(); defer { lock.unlock() }
        return _lastGenerateRequest
    }

    /// Total AI invocations (ask + adapt/plan/generate). Cold open must leave this at 0.
    var totalCallCount: Int { adaptCallCount + askCallCount }

    func resetCallCount() {
        lock.lock()
        _adaptCallCount = 0
        _askCallCount = 0
        _lastAskRequest = nil
        lock.unlock()
    }

    func stubAsk(_ handler: @escaping (AskRequest) async throws -> AskResponse) {
        lock.lock()
        _askHandler = handler
        lock.unlock()
    }

    func stubFailNextGenerate(_ value: Bool = true) {
        lock.lock()
        _failNextGenerate = value
        lock.unlock()
    }

    func stubGenerate(_ handler: @escaping (AdaptationGenerateRequest) async throws -> [ContentBlock]) {
        lock.lock()
        _generateHandler = handler
        lock.unlock()
    }

    /// Test seam: propose a continuity delta / fact claims alongside the prose,
    /// the way Astra does. Returning nil falls back to prose-only.
    func stubGeneratedPacket(_ handler: @escaping (AdaptationGenerateRequest) -> GeneratedChapter?) {
        lock.lock()
        _packetHandler = handler
        lock.unlock()
    }

    /// Test seam: slow generate so cancel-mid-generation can race.
    func stubGenerateDelay(nanoseconds: UInt64) {
        lock.lock()
        _generateDelayNanoseconds = nanoseconds
        lock.unlock()
    }

    func stubPlanDelay(nanoseconds: UInt64) {
        lock.lock()
        _planDelayNanoseconds = nanoseconds
        lock.unlock()
    }

    func adaptChapter(
        chapterId: UUID,
        promptContext: String
    ) async throws -> ChapterRevision {
        lock.lock()
        _adaptCallCount += 1
        lock.unlock()

        return ChapterRevision(
            id: UUID(),
            chapterId: chapterId,
            revisionIndex: 0,
            createdAt: Date(),
            blocks: [
                ContentBlock(
                    id: UUID(),
                    kind: .paragraph,
                    text: "Mock adaptation for: \(promptContext)",
                    orderIndex: 0
                )
            ],
            isConsumed: false
        )
    }

    func makeAdaptationPlan(_ request: AdaptationPlanRequest) async throws -> AdaptationPlan {
        lock.lock()
        _adaptCallCount += 1
        _lastPlanRequest = request
        let delay = _planDelayNanoseconds
        lock.unlock()
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
            try Task.checkCancellation()
        }
        return try DeterministicAdaptationSynthesizer.makePlan(request)
    }

    func generateAdaptedChapter(_ request: AdaptationGenerateRequest) async throws -> [ContentBlock] {
        lock.lock()
        _adaptCallCount += 1
        _lastGenerateRequest = request
        let fail = _failNextGenerate
        if fail { _failNextGenerate = false }
        let handler = _generateHandler
        let delay = _generateDelayNanoseconds
        lock.unlock()

        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
            try Task.checkCancellation()
        }
        if fail {
            throw AdaptationError.malformedGeneration("stubbed malformed generation")
        }
        if let handler {
            return try await handler(request)
        }
        return DeterministicAdaptationSynthesizer.generate(request)
    }

    func generateAdaptedChapterWithPacket(_ request: AdaptationGenerateRequest) async throws -> GeneratedChapter {
        let packetHandler = currentPacketHandler()

        // Route through `generateAdaptedChapter` so every existing stub
        // (failure, delay, custom blocks) keeps behaving identically.
        let blocks = try await generateAdaptedChapter(request)
        guard let proposed = packetHandler?(request) else {
            return GeneratedChapter(blocks: blocks)
        }
        return GeneratedChapter(
            blocks: proposed.blocks.isEmpty ? blocks : proposed.blocks,
            continuityDelta: proposed.continuityDelta,
            proposedClaims: proposed.proposedClaims,
            proposedEvidence: proposed.proposedEvidence
        )
    }

    func ask(_ request: AskRequest) async throws -> AskResponse {
        lock.lock()
        _askCallCount += 1
        _lastAskRequest = request
        let handler = _askHandler
        lock.unlock()

        if let handler {
            return try await handler(request)
        }

        if !request.allowUnreadSpoilers,
           AskContextBuilder.questionAppearsToNeedUnread(
            request.userQuestion,
            hasUnread: !(request.unreadContext?.isEmpty ?? true)
           ) {
            return .spoilerWarning(message: AskContextBuilder.spoilerWarningText)
        }

        let selection = request.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let focus: String
        if let selection, !selection.isEmpty {
            focus = selection
        } else {
            focus = request.userQuestion
        }

        let chapterBit = request.currentChapterTitle.map { " in “\($0)”" } ?? ""
        let revealBit = request.allowUnreadSpoilers ? " [deliberate unread reveal]" : ""
        let answer = """
        Mock answer\(chapterBit): “\(Self.shorten(focus))” relates to the passage you’ve selected \
        and the chapters you’ve already consumed in \(request.bookTitle). \
        This is a deterministic offline reply for tests — no network used.\(revealBit)
        """

        return AskResponse(
            answer: answer.replacingOccurrences(of: "  ", with: " "),
            modelUsed: "mock",
            usedUnreadSpoilers: request.allowUnreadSpoilers && !(request.unreadContext?.isEmpty ?? true),
            isSpoilerWarning: false,
            isMock: true
        )
    }

    private func currentPacketHandler() -> ((AdaptationGenerateRequest) -> GeneratedChapter?)? {
        lock.lock(); defer { lock.unlock() }
        return _packetHandler
    }

    private static func shorten(_ text: String, limit: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<idx]) + "…"
    }
}

private extension AdaptationGenerateRequest {
    var feedbackMentionsStories: Bool {
        plan.reasonsFromFeedback.contains { $0.lowercased().contains("stories") }
    }
}
