import Foundation

/// AI is never on the critical reading path. Callers must tolerate failure / offline / timeout.
protocol AIService: Sendable {
    /// Explicit source kind for generation results; never infer it from prose or a model name.
    var usesDeterministicGeneration: Bool { get }

    /// Legacy single-chapter adapt (kept for call-count / compatibility). Prefer plan + generate.
    func adaptChapter(
        chapterId: UUID,
        promptContext: String
    ) async throws -> ChapterRevision

    /// Stage 1: structured adaptation plan. Must not mutate the manuscript.
    func makeAdaptationPlan(_ request: AdaptationPlanRequest) async throws -> AdaptationPlan

    /// Stage 2: generate candidate blocks for one unread chapter from an approved plan.
    func generateAdaptedChapter(_ request: AdaptationGenerateRequest) async throws -> [ContentBlock]

    /// Stage 2 with the PE packet: prose plus the continuity delta and fact
    /// claims the generation says back it. Callers gate on the claims before
    /// anything is activated.
    func generateAdaptedChapterWithPacket(_ request: AdaptationGenerateRequest) async throws -> GeneratedChapter

    /// Book-aware Ask. Soft-fails; must not throw into reading chrome uncaught.
    func ask(_ request: AskRequest) async throws -> AskResponse
}

extension AIService {
    var usesDeterministicGeneration: Bool { false }

    /// A backend that only knows how to return prose still works — it simply
    /// proposes no claims, so it can never introduce a new essential fact.
    func generateAdaptedChapterWithPacket(_ request: AdaptationGenerateRequest) async throws -> GeneratedChapter {
        GeneratedChapter(blocks: try await generateAdaptedChapter(request))
    }
}

/// Only explicit demo/test launch arguments select Mock. Live reads its key when invoked.
enum AIServiceResolver {
    /// `-useMockAI` / `-phase4MockAsk` / `-phase5AdaptationDemo` / `-uitesting` force deterministic Mock.
    /// `-argentinaQualityRegen` does **not** force Mock — live overnight uses Astra when a Keychain key is present.
    static func prefersMock(processInfo: ProcessInfo = .processInfo) -> Bool {
        let args = processInfo.arguments
        return args.contains("-useMockAI")
            || args.contains("-phase4MockAsk")
            || args.contains("-phase5AdaptationDemo")
            || args.contains("-uitesting")
    }

    /// Resolve a single AIService for the given preferred model (Ask or generation).
    static func makeDefault(
        sharingPermission: @escaping AISharingConsentStore.PermissionProvider = { AISharingConsentStore.shared.isAllowed },
        keyStore: APIKeyStoring = KeychainAPIKeyStore.shared,
        modelPreference: OpenAIModelOption = .defaultAsk,
        session: URLSession = .shared,
        processInfo: ProcessInfo = .processInfo,
        bundleID: String? = Bundle.main.bundleIdentifier
    ) -> any AIService {
        #if DEBUG
        if SourceContinuationTrial.requested(arguments: processInfo.arguments, environment: processInfo.environment, bundleID: bundleID) {
            return SourceContinuationTrial.resolve(arguments: processInfo.arguments, environment: processInfo.environment,
                bundleID: bundleID, model: modelPreference)
        }
        #endif
        if prefersMock(processInfo: processInfo) {
            return MockAIService()
        }
        return LiveOpenAIService(
            sharingPermission: sharingPermission,
            apiKeyProvider: { try keyStore.loadAPIKey() },
            preferredModel: modelPreference,
            session: session
        )
    }

    /// Resolve Ask (luna) + adaptation/generation (astra) sharing the same Keychain key.
    static func makeAskAndAdaptation(
        sharingPermission: @escaping AISharingConsentStore.PermissionProvider = { AISharingConsentStore.shared.isAllowed },
        keyStore: APIKeyStoring = KeychainAPIKeyStore.shared,
        askModel: OpenAIModelOption = .defaultAsk,
        generationModel: OpenAIModelOption = .defaultGeneration,
        session: URLSession = .shared,
        processInfo: ProcessInfo = .processInfo,
        bundleID: String? = Bundle.main.bundleIdentifier
    ) -> (ask: any AIService, adaptation: any AIService) {
        let ask = makeDefault(
            sharingPermission: sharingPermission,
            keyStore: keyStore,
            modelPreference: askModel,
            session: session,
            processInfo: processInfo,
            bundleID: bundleID
        )
        let adaptation = makeDefault(
            sharingPermission: sharingPermission,
            keyStore: keyStore,
            modelPreference: generationModel,
            session: session,
            processInfo: processInfo,
            bundleID: bundleID
        )
        return (ask, adaptation)
    }
}
