import XCTest
import CryptoKit
@testable import LivingReader

/// Typed duration contracts using authored prose and isolated temporary stores.
/// No source retrieval, live provider request, or device operation is performed.
final class CreateReadingTimeTests: XCTestCase {
    func testAcceptedMinuteHourAndCombinedFormatsResolveToOneWordBudget() throws {
        let cases: [(String, Int)] = [
            ("10", 2300), ("10 min", 2300), ("10m", 2300), ("10 minutes", 2300),
            ("12.5", 2875), ("12,5 min", 2875), (".5 min", 115), (",5 m", 115),
            ("1 h", 13800), ("1 hr", 13800), ("1 hours", 13800), ("1.5h", 20700),
            ("1,5 hours", 20700), ("2 h 15 min", 31050), ("2hr15m", 31050),
            (" \n 2 H 15 MIN \t", 31050), ("0.1", 23), ("4.35 min", 1001)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(try CreateReadingTime.targetWords(for: input), expected, input)
        }
        XCTAssertEqual(CreateReadingTime.wordsPerMinute, 230)
        XCTAssertEqual(CreateReadingTime.wordsPerPage, 250)
        XCTAssertEqual(CreateReadingTime.wordsPerChapter, 1200)
        XCTAssertEqual(CreateReadingTime.maximumChapters, 1000)
    }

    func testMalformedNonfiniteNonpositiveAndOutOfBudgetInputNeverClamps() throws {
        for input in ["", " \n ", "0", "-1", "NaN", "inf", "Infinity", "1e2", "1:30",
                      "1..5", "1,000,000", "ten minutes", "1 min trailing", "1 h -2 min", "0.08", "6000",
                      String(repeating: "9", count: 1000)] {
            XCTAssertThrowsError(try CreateReadingTime.targetWords(for: input), input)
        }
        let upper = "5217.391304347826 min"
        XCTAssertEqual(try CreateReadingTime.targetWords(for: upper), 1_200_000)
        XCTAssertThrowsError(try CreateReadingTime.targetWords(for: "5217.4 min"))
        var draft = makeDraft(input: upper)
        XCTAssertEqual(draft.resolvedOutline(for: draft.length).count, 1000)
        XCTAssertEqual(try draft.chapterWordTargets(chapterCount: 1000), Array(repeating: 1200, count: 1000))
        draft.readingTimeInput = "6000 min"
        XCTAssertNotNil(draft.lengthValidationMessage)
        XCTAssertTrue(draft.resolvedOutline(for: draft.length).isEmpty, "Do not silently use a smaller preset")
    }

    func testLegacyMissingFieldDecodesWithoutChangingLengthOrSourceBriefHashes() throws {
        struct LegacyScopedBrief: Encodable {
            let draft: CreateBookDraft
            let scope: RetrievedResearchSource.Scope
        }
        let legacyEncoder = JSONCoding.encoder
        legacyEncoder.outputFormatting = [.sortedKeys]
        for length in CreateBookLength.allCases {
            var legacy = makeDraft(input: nil)
            legacy.length = length
            legacy.outlineTitles = ["River", "Market"]
            legacy.updatedAt = Date(timeIntervalSince1970: 0)
            let encoded = try legacyEncoder.encode(legacy)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNil(object["readingTimeInput"], "Nil must remain absent from the old hash payload")
            object.removeValue(forKey: "readingTimeInput")
            let oldWire = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let decoded = try JSONCoding.decoder.decode(CreateBookDraft.self, from: oldWire)
            XCTAssertNil(decoded.readingTimeInput)
            XCTAssertEqual(decoded, legacy)
            let words = 2 * length.targetWordsPerChapter
            XCTAssertEqual(try decoded.validatedTargetWordCount(), words)
            XCTAssertEqual(try decoded.chapterWordTargets(chapterCount: 2), Array(repeating: length.targetWordsPerChapter, count: 2))
            XCTAssertEqual(try CreateReadingTime.targetWords(for: decoded.lengthInputText), words,
                           "Opening the text field must not round an old budget to a different minute target")
            // The hash contract uses JSONEncoder's key order. JSONSerialization
            // sorts importedText before importSourceKind; JSONEncoder reverses
            // those keys, so the decode fixture is not canonical hash bytes.
            XCTAssertEqual(try SourcePilotPlan.briefHash(decoded), hash(encoded))
            let scopedWire = try legacyEncoder.encode(LegacyScopedBrief(
                draft: legacy, scope: .wikipediaOpeningExcerpt))
            XCTAssertEqual(try SourcePilotPlan.briefHash(decoded, scope: .wikipediaOpeningExcerpt), hash(scopedWire))
            let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(decoded)) as? [String: Any])
            XCTAssertNil(roundTrip["readingTimeInput"])
        }
    }

    func testDraftStorePreservesExactValidAndIncompleteRawEditsAcrossReopening() throws {
        let environment = try ReadingTimeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        for raw in [" 2 h 15 min ", "1,5", "unfinished", ""] {
            let draft = makeDraft(input: raw)
            try environment.drafts.save(draft)
            let reopened = try FileCreateBookDraftStore(rootDirectory: environment.root)
            let loaded = try XCTUnwrap(reopened.load(id: draft.id))
            XCTAssertEqual(loaded.readingTimeInput, raw)
            XCTAssertEqual(loaded.lengthInputText, raw)
            XCTAssertEqual(loaded.length, draft.length)
            if raw == "unfinished" || raw.isEmpty {
                XCTAssertNotNil(loaded.lengthValidationMessage)
                XCTAssertThrowsError(try loaded.validatedTargetWordCount())
                XCTAssertEqual(loaded.estimatedReadingTime.proseWordCount, 0, "Invalid input cannot retain the previous valid preset estimate")
                XCTAssertFalse(loaded.approximatePagesLabel.hasPrefix("About "))
            } else {
                XCTAssertNil(loaded.lengthValidationMessage)
            }
        }
    }

    func testCustomEstimateAndExactUnevenAllocationsDoNotDependOnLegacyPreset() throws {
        for length in CreateBookLength.allCases {
            var draft = makeDraft(input: "10 min")
            draft.length = length
            draft.outlineTitles = ["First", "Second", "Third"]
            XCTAssertEqual(try draft.validatedTargetWordCount(), 2300)
            XCTAssertEqual(draft.estimatedReadingTime.proseWordCount, 2300)
            XCTAssertEqual(draft.estimatedReadingTime.remainingMinutes, 10, accuracy: 0.000_001)
            XCTAssertEqual(draft.approximatePagesLabel, "About 9 pages")
            XCTAssertEqual(try draft.chapterWordTargets(chapterCount: 3), [767, 767, 766])
            XCTAssertNil(draft.lengthValidationMessage)
        }
        let oneMinute = makeDraft(input: "1 min")
        XCTAssertEqual(oneMinute.approximatePagesLabel, "About 1 page")
        var uneven = makeDraft(input: "4.35 min")
        uneven.outlineTitles = ["First", "Second", "Third"]
        XCTAssertEqual(try uneven.validatedTargetWordCount(), 1001)
        XCTAssertEqual(try uneven.chapterWordTargets(chapterCount: 3), [334, 334, 333])
    }

    func testDefaultOutlineScalesWhilePastedAndProfileCardTitlesAreAllPreserved() throws {
        for (input, chapters) in [("5.2", 1), ("5.3", 2), ("30", 6), ("1 hour", 12)] {
            let draft = makeDraft(input: input)
            XCTAssertEqual(draft.resolvedOutline(for: draft.length).count, chapters)
            let budgets = try draft.chapterWordTargets(chapterCount: chapters)
            XCTAssertEqual(budgets.reduce(0, +), try draft.validatedTargetWordCount())
            XCTAssertTrue(budgets.allSatisfy { (20...1200).contains($0) })
        }
        let titles = (1...13).map { "Chapter \($0)" }
        var pasted = makeDraft(input: "10")
        pasted.length = .short
        pasted.outlineTitles = titles
        XCTAssertEqual(pasted.resolvedOutline(for: .short), titles)
        XCTAssertEqual(try pasted.validatedTargetWordCount(), 2300)
        var cards = makeDraft(input: "10")
        cards.length = .short
        cards.profileCards = [.init(title: "Outline", body: titles.map { "- " + $0 }.joined(separator: "\n"))]
        XCTAssertEqual(cards.resolvedOutline(for: .short), titles, "Custom time must not silently prefix profile-card titles to the old three chapters")
        XCTAssertEqual(try cards.chapterWordTargets(chapterCount: titles.count).reduce(0, +), 2300)
    }

    func testIncompatibleChapterCountsRejectRatherThanClampingOrDroppingTitles() throws {
        var draft = makeDraft(input: "10")
        for count in [-1, 0, 1, 116, 1001] {
            XCTAssertThrowsError(try draft.chapterWordTargets(chapterCount: count), "count \(count)")
        }
        draft.outlineTitles = ["One oversized chapter"]
        XCTAssertEqual(draft.resolvedOutline(for: .short), draft.outlineTitles)
        XCTAssertThrowsError(try draft.validatedTargetWordCount())
        XCTAssertNotNil(draft.lengthValidationMessage)
        draft.outlineTitles = (1...116).map { "Tiny chapter \($0)" }
        XCTAssertEqual(draft.resolvedOutline(for: .short).count, 116)
        XCTAssertThrowsError(try draft.validatedTargetWordCount())
    }

    func testDisplayedCustomTotalMatchesActualServicePlanAndPublishedProse() async throws {
        let environment = try ReadingTimeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        for explicitOutline in [false, true] {
            var draft = makeDraft(input: "10 min")
            if explicitOutline { draft.outlineTitles = ["First", "Second", "Third"] }
            let recorder = ReadingTimeRequestRecorder()
            let ai = MockAIService()
            ai.stubGenerate { request in
                await recorder.append(request)
                return Self.prose(for: request)
            }
            let advertised = draft.estimatedReadingTime.proseWordCount
            let result = try await environment.wizard(ai: ai).generateAndSave(draft: draft)
            let requests = await recorder.snapshot()
            let expected = explicitOutline ? [767, 767, 766] : [1150, 1150]
            XCTAssertTrue(result.isComplete)
            XCTAssertEqual(requests.map { $0.target.targetWordCount }, expected)
            XCTAssertEqual(requests.map { $0.target.targetWordCount }.reduce(0, +), advertised)
            XCTAssertEqual(requests.first?.plan.chapterTargets.map(\.targetWordCount), expected)
            XCTAssertEqual(result.book.chapters.reduce(0) { $0 + AdaptationPlanValidator.wordCount(of: $1.activeRevision?.blocks ?? []) }, advertised)
            XCTAssertEqual(result.book.chapters.count, expected.count)
            XCTAssertEqual(ai.totalCallCount, expected.count)
            XCTAssertNil(try environment.drafts.load(id: draft.id))
        }
    }

    func testPartialResumeKeepsOriginalMiddleAllocationAndPublishedConsumedPeers() async throws {
        let environment = try ReadingTimeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        var draft = makeDraft(input: "10 min")
        draft.outlineTitles = ["First", "Second", "Third"]
        let firstAI = MockAIService()
        let firstCalls = ReadingTimeRequestRecorder()
        firstAI.stubGenerate { request in
            await firstCalls.append(request)
            if request.chapterTitle == "Second" { throw CreateBookError.generationFailed("Authored connection failure") }
            return Self.prose(for: request)
        }
        let partial = try await environment.wizard(ai: firstAI).generateAndSave(draft: draft)
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.generatedChapterIds.count, 2)
        let originalRequests = await firstCalls.snapshot()
        XCTAssertEqual(originalRequests.map { $0.target.targetWordCount }, [767, 767, 766])
        let first = try XCTUnwrap(partial.book.chapters.first { $0.title == "First" })
        let firstRevision = try XCTUnwrap(first.activeRevisionId)
        try await environment.versioning.consume(bookId: draft.id, chapterId: first.id, revisionId: firstRevision)
        let consumed = try await environment.versioning.readableRevision(bookId: draft.id, chapterId: first.id)
        _ = try environment.packets.recordConsumedContinuity(bookId: draft.id, chapter: first, revision: consumed)
        let savedBefore = try await environment.versioning.loadBook(id: draft.id)
        let ledgerBefore = try await environment.versioning.ledgerSnapshot()
        let preferencesBefore = try environment.preferences.load(bookId: draft.id)
        let savedDraft = try XCTUnwrap(environment.drafts.load(id: draft.id))
        let reopened = try ReadingTimeTestEnvironment(root: environment.root)
        let retryAI = MockAIService()
        let retryCalls = ReadingTimeRequestRecorder()
        retryAI.stubGenerate { request in
            await retryCalls.append(request)
            return Self.prose(for: request)
        }
        let result = try await reopened.wizard(ai: retryAI).generateAndSave(draft: savedDraft)
        let retries = await retryCalls.snapshot()
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(retries.map(\.chapterTitle), ["Second"])
        XCTAssertEqual(retries.map { $0.target.targetWordCount }, [767], "Do not redistribute all 2300 words to the only remaining outline")
        XCTAssertEqual(result.book.chapters.map(\.id), partial.book.chapters.map(\.id))
        for title in ["First", "Third"] {
            XCTAssertEqual(result.book.chapters.first { $0.title == title }, savedBefore?.chapters.first { $0.title == title })
        }
        let ledgerAfter = try await reopened.versioning.ledgerSnapshot()
        XCTAssertEqual(ledgerAfter, ledgerBefore)
        XCTAssertEqual(try reopened.preferences.load(bookId: draft.id), preferencesBefore)
        XCTAssertEqual(retryAI.totalCallCount, 1)
        XCTAssertNil(try reopened.drafts.load(id: draft.id))
    }

    func testChangedRawDurationCannotOverwriteOrResumeSavedBriefEvenIfEquivalent() async throws {
        let environment = try ReadingTimeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let ai = MockAIService()
        ai.stubGenerate { _ in throw CreateBookError.generationFailed("Authored offline failure") }
        var draft = makeDraft(input: "10 min")
        draft.outlineTitles = ["First", "Second", "Third"]
        let service = environment.wizard(ai: ai)
        let partial = try await service.generateAndSave(draft: draft)
        XCTAssertFalse(partial.isComplete)
        let before = try environment.fileBytes()
        let callsBefore = ai.totalCallCount
        for changed in ["11 min", "10.0 minutes", ""] {
            var edited = draft
            edited.readingTimeInput = changed
            do { _ = try await service.generateAndSave(draft: edited); XCTFail("Changed raw brief must not silently resume") }
            catch { }
            XCTAssertEqual(ai.totalCallCount, callsBefore)
            XCTAssertEqual(try environment.fileBytes(), before)
        }
    }

    func testInvalidDurationOrOutlineStopsBeforeAnySavedFileOrAICall() async throws {
        let environment = try ReadingTimeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let ai = MockAIService()
        let service = environment.wizard(ai: ai)
        let before = try environment.fileBytes()
        for raw in ["", "unfinished", "0", "-10", "NaN", "0.08", "6000 min"] {
            let draft = makeDraft(input: raw)
            do { _ = try await service.generateAndSave(draft: draft); XCTFail(raw) } catch { }
            XCTAssertEqual(ai.totalCallCount, 0)
            XCTAssertNil(try environment.drafts.load(id: draft.id))
            XCTAssertEqual(try environment.fileBytes(), before)
        }
        for titles in [["Too large"], (1...116).map { "Too short \($0)" }] {
            var draft = makeDraft(input: "10 min")
            draft.outlineTitles = titles
            do { _ = try await service.generateAndSave(draft: draft); XCTFail("Incompatible outline") } catch { }
            XCTAssertEqual(ai.totalCallCount, 0)
            XCTAssertNil(try environment.drafts.load(id: draft.id))
            XCTAssertEqual(try environment.fileBytes(), before)
        }
    }

    func testChangedAndReapprovedCustomTimeSourcePlansRejectBeforeRetrievalOrProvider() async throws {
        let environment = try ReadingTimeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let retriever = ReadingTimeForbiddenRetriever()
        let session = MockURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); MockURLProtocol.reset() }
        var providerCalls = 0
        MockURLProtocol.requestHandler = { _ in providerCalls += 1; throw URLError(.badServerResponse) }
        let ai = LiveOpenAIService(apiKeyProvider: { "unused-authored-test-value" }, preferredModel: .defaultGeneration, session: session)
        let service = environment.wizard(ai: ai, retriever: retriever)
        var original = makeDraft(input: nil)
        original.length = .short
        original.outlineTitles = [original.title]
        original.sourcePilot = try SourcePilotPlan.approved(articleTitle: "River Archive", draft: original)
        let before = try environment.fileBytes()
        for reapprove in [false, true] {
            var custom = original
            custom.readingTimeInput = "10 min"
            if reapprove { custom.sourcePilot = try SourcePilotPlan.approved(articleTitle: "River Archive", draft: custom) }
            do { _ = try await service.generateAndSave(draft: custom); XCTFail("A 400-word route cannot silently ignore typed duration") }
            catch { XCTAssertTrue(error.localizedDescription.contains("400")) }
            XCTAssertEqual(try environment.fileBytes(), before)
            XCTAssertNil(try environment.drafts.load(id: custom.id))
        }
        let retrievalCalls = await retriever.calls
        XCTAssertEqual(retrievalCalls, 0); XCTAssertEqual(providerCalls, 0)
    }

    @MainActor
    func testExplicitSourcePreviewApprovalClearsCustomTimeBeforeBindingBrief() throws {
        let environment = try ReadingTimeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let suite = "CreateReadingTime-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ai = MockAIService()
        let model = CreateBookViewModel(wizard: environment.wizard(ai: ai),
            modelPrefs: AIModelPreferenceStore(defaults: defaults), draft: makeDraft(input: "2 h 15 min"))
        try model.prepareSourcePreview(articleTitle: "River Archive")
        XCTAssertNil(model.draft.readingTimeInput)
        XCTAssertEqual(model.draft.length, .short)
        XCTAssertEqual(model.draft.estimatedReadingTime.proseWordCount, 400)
        XCTAssertEqual(try model.draft.validatedTargetWordCount(), 400)
        XCTAssertEqual(model.draft.sourcePilot?.approvedBriefHash, try SourcePilotPlan.briefHash(model.draft))
        let approved = model.draft
        try model.prepareSourcePreview(articleTitle: "Another article")
        XCTAssertEqual(model.draft, approved, "Retry must not rebind an approved source or alter its length")
        XCTAssertEqual(ai.totalCallCount, 0)
        XCTAssertTrue(try environment.fileBytes().isEmpty)
    }

    private func makeDraft(input: String?) -> CreateBookDraft {
        var draft = CreateBookDraft.blank(at: Date(timeIntervalSince1970: 0))
        draft.path = .generate
        draft.title = "River Stories"
        draft.author = "Authored Fixture"
        draft.topic = "River records"
        draft.readingTimeInput = input
        return draft
    }
    private static func prose(for request: AdaptationGenerateRequest) -> [ContentBlock] {
        [.init(id: UUID(), kind: .paragraph,
               text: Array(repeating: "river", count: request.target.targetWordCount).joined(separator: " "), orderIndex: 0)]
    }
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ReadingTimeTestEnvironment {
    let root: URL
    let packets: FilePEPacketStore
    let versioning: ManuscriptVersioningService
    let preferences: FileReaderPreferenceStore
    let drafts: FileCreateBookDraftStore
    init(root: URL? = nil) throws {
        let directory = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("CreateReadingTime-" + UUID().uuidString, isDirectory: true)
        self.root = directory
        packets = try FilePEPacketStore(rootDirectory: directory)
        versioning = try ManuscriptVersioningService(rootDirectory: directory, packets: packets)
        preferences = try FileReaderPreferenceStore(rootDirectory: directory)
        drafts = try FileCreateBookDraftStore(rootDirectory: directory)
    }
    func wizard(ai: any AIService, retriever: any ResearchSourceRetrieving = ReadingTimeForbiddenRetriever()) -> CreateBookWizardService {
        CreateBookWizardService(versioning: versioning, preferenceStore: preferences, packets: packets,
                                drafts: drafts, ai: ai, sourceRetriever: retriever)
    }
    func fileBytes() throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }
}
private actor ReadingTimeRequestRecorder {
    private var requests: [AdaptationGenerateRequest] = []
    func append(_ request: AdaptationGenerateRequest) { requests.append(request) }
    func snapshot() -> [AdaptationGenerateRequest] { requests }
}
private actor ReadingTimeForbiddenRetriever: ResearchSourceRetrieving {
    private(set) var calls = 0
    func retrieve(articleTitle: String) async throws -> RetrievedResearchSource {
        calls += 1
        throw CreateBookError.generationFailed("Unexpected fixture retrieval")
    }
}
