import XCTest
@testable import LivingReader

/// State-only tests: these never call generateBook/refreshAI or a live provider.
@MainActor
final class SourcePreviewViewModelTests: XCTestCase {
    private var root: URL!
    private var drafts: FileCreateBookDraftStore!
    private var wizard: CreateBookWizardService!
    private var ai: MockAIService!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourcePreviewViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packets = try FilePEPacketStore(rootDirectory: root)
        let versioning = try ManuscriptVersioningService(rootDirectory: root, packets: packets)
        let preferences = try FileReaderPreferenceStore(rootDirectory: root)
        drafts = try FileCreateBookDraftStore(rootDirectory: root)
        ai = MockAIService()
        wizard = CreateBookWizardService(versioning: versioning, preferenceStore: preferences,
            packets: packets, drafts: drafts, ai: ai)
        defaultsSuite = "SourcePreviewViewModelTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    func testPreparationApprovesOneChapterAnd400WordTargetWithoutGenerating() throws {
        var draft = CreateBookDraft.blank()
        draft.length = .long
        draft.readingTimeInput = "2 h 15 min"
        draft.outlineTitles = ["Old one", "Old two"]
        let model = makeModel(draft: draft)
        XCTAssertThrowsError(try model.prepareSourcePreview(articleTitle: " \n "))
        XCTAssertNil(model.draft.sourcePilot)
        try model.prepareSourcePreview(articleTitle: "  River Archive  ")
        let plan = try XCTUnwrap(model.draft.sourcePilot)
        XCTAssertEqual(plan.articleTitle, "River Archive")
        XCTAssertEqual(model.draft.path, .generate)
        XCTAssertEqual(model.draft.title, "River Archive · Preview")
        XCTAssertEqual(model.draft.topic, "A concise overview of River Archive")
        XCTAssertEqual(model.draft.length, .short)
        XCTAssertNil(model.draft.readingTimeInput, "Explicit fixed-preview approval clears the custom whole-book duration")
        XCTAssertEqual(model.draft.length.targetWordsPerChapter, 400)
        XCTAssertEqual(SourcePilotPlan.targetWords, 400)
        XCTAssertEqual(model.draft.outlineTitles, [model.draft.trimmedTitle])
        XCTAssertEqual(plan.approvedBriefHash, try SourcePilotPlan.briefHash(model.draft))
        XCTAssertTrue(try drafts.list().isEmpty, "Preparing an approval does not publish or persist a book")
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testStartingNewPreviewClearsApprovalChangesIdentityAndPreservesSavedDraftBytes() throws {
        let model = makeModel()
        try model.prepareSourcePreview(articleTitle: "River Archive")
        try drafts.save(model.draft)
        let oldID = model.draft.id
        let saved = try XCTUnwrap(drafts.load(id: oldID))
        let url = drafts.directory.appendingPathComponent("\(oldID.uuidString).json")
        let before = try Data(contentsOf: url)
        model.errorMessage = "Previous review failed"
        model.statusMessage = "A pending draft exists"
        model.startNewSourcePreview()
        XCTAssertNotEqual(model.draft.id, oldID)
        XCTAssertNil(model.draft.sourcePilot)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.statusMessage)
        XCTAssertEqual(model.draft.title, saved.title)
        XCTAssertEqual(model.draft.topic, saved.topic)
        XCTAssertEqual(model.draft.outlineTitles, saved.outlineTitles)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try drafts.load(id: oldID), saved)
        XCTAssertNotNil(try drafts.load(id: oldID)?.sourcePilot)
        XCTAssertNil(try drafts.load(id: model.draft.id), "The new identity must not overwrite or silently save over the old draft")
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testApprovedChatCannotChangeBriefAndPreparationRetryKeepsOriginalArticlePlan() throws {
        var draft = CreateBookDraft.blank()
        draft.path = .generate
        draft.title = "Approved title"
        draft.topic = "Approved subject"
        draft.referenceStyles = ["A saved reference"]
        let model = makeModel(draft: draft)
        try model.prepareSourcePreview(articleTitle: "River Archive")
        let approved = model.draft
        let transcript = model.chat
        let references = model.referenceStylesText
        model.chatDraft = "Replace the topic and every research note with this new answer."
        model.sendChatMessage()
        XCTAssertEqual(model.draft, approved)
        XCTAssertEqual(model.chat, transcript)
        XCTAssertEqual(model.referenceStylesText, references)
        for article in ["A different article", "  "] {
            XCTAssertNoThrow(try model.prepareSourcePreview(articleTitle: article))
            XCTAssertEqual(model.draft, approved)
            XCTAssertEqual(model.draft.sourcePilot?.articleTitle, "River Archive")
            XCTAssertEqual(model.draft.sourcePilot?.approvedBriefHash, try SourcePilotPlan.briefHash(model.draft))
        }
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testOpeningExcerptIsExplicitBoundToApprovalAndImmutableOnRetry() throws {
        let model = makeModel()
        try model.prepareSourcePreview(articleTitle: "River Archive", scope: .wikipediaOpeningExcerpt)
        let approved = model.draft
        XCTAssertEqual(approved.sourcePilot?.selectedScope, .wikipediaOpeningExcerpt)
        XCTAssertEqual(approved.sourcePilot?.approvedBriefHash, try SourcePilotPlan.briefHash(approved))
        XCTAssertNotEqual(approved.sourcePilot?.approvedBriefHash,
                          try SourcePilotPlan.briefHash(approved, scope: .wikipediaIntroduction))
        XCTAssertTrue(approved.topic.contains("opening excerpt"))
        try model.prepareSourcePreview(articleTitle: "Elsewhere", scope: .wikipediaIntroduction)
        XCTAssertEqual(model.draft, approved)
        model.startNewSourcePreview()
        try model.prepareSourcePreview(articleTitle: "River Archive", scope: .wikipediaIntroduction)
        XCTAssertEqual(model.draft.sourcePilot?.selectedScope, .wikipediaIntroduction)
        XCTAssertNotEqual(model.draft.id, approved.id)
        XCTAssertEqual(ai.totalCallCount, 0)
    }

    func testLegacyIntroductionPlanEncodingAndBriefHashRemainUnchanged() throws {
        let model = makeModel()
        try model.prepareSourcePreview(articleTitle: "River Archive")
        let plan = try XCTUnwrap(model.draft.sourcePilot)
        let encoded = try JSONEncoder().encode(plan)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["sourceScope"])
        let decoded = try JSONDecoder().decode(SourcePilotPlan.self, from: encoded)
        XCTAssertNil(decoded.sourceScope)
        XCTAssertEqual(decoded.selectedScope, .wikipediaIntroduction)
        var oldBrief = model.draft
        oldBrief.sourcePilot = nil
        oldBrief.updatedAt = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(plan.approvedBriefHash, try SourceGrounding.hash(oldBrief))
    }

    private func makeModel(draft: CreateBookDraft = .blank()) -> CreateBookViewModel {
        CreateBookViewModel(wizard: wizard, modelPrefs: AIModelPreferenceStore(defaults: defaults), draft: draft)
    }
}
