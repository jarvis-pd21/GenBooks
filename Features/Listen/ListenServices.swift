import Foundation

/// Composition root for Listen: cache, resume store, and the synthesizer.
///
/// The synthesizer reuses the *existing* Keychain key — Listen never asks for a
/// second one. `hasAPIKey` is re-checked on demand so a key saved from Reading
/// settings mid-session enables narration without relaunching, and a run with no
/// key degrades to "plays what you already downloaded" instead of failing.
struct ListenServices: Sendable {
    let cache: any ListenAudioCaching
    let progress: any ListenProgressStoring
    /// Nil in mock / UI-test runs, which must never reach the network.
    let speech: (any SpeechSynthesizing)?
    let hasAPIKey: @Sendable () -> Bool

    init(
        cache: any ListenAudioCaching,
        progress: any ListenProgressStoring,
        speech: (any SpeechSynthesizing)?,
        hasAPIKey: @escaping @Sendable () -> Bool = { true }
    ) {
        self.cache = cache
        self.progress = progress
        self.speech = speech
        self.hasAPIKey = hasAPIKey
    }

    static func make(
        rootDirectory: URL,
        keyStore: APIKeyStoring = KeychainAPIKeyStore.shared,
        session: URLSession? = nil,
        processInfo: ProcessInfo = .processInfo
    ) -> ListenServices {
        let prefersMock = AIServiceResolver.prefersMock(processInfo: processInfo)
        let speech: (any SpeechSynthesizing)? = prefersMock
            ? nil
            : OpenAISpeechClient(
                apiKeyProvider: { try keyStore.loadAPIKey() },
                session: session
            )
        return ListenServices(
            cache: FileListenAudioCache(rootDirectory: rootDirectory),
            progress: FileListenProgressStore(rootDirectory: rootDirectory),
            speech: speech,
            hasAPIKey: {
                let key = (try? keyStore.loadAPIKey())?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !key.isEmpty
            }
        )
    }

    static func makeDefault(
        keyStore: APIKeyStoring = KeychainAPIKeyStore.shared,
        processInfo: ProcessInfo = .processInfo
    ) -> ListenServices {
        make(rootDirectory: defaultRootDirectory(), keyStore: keyStore, processInfo: processInfo)
    }

    private static func defaultRootDirectory() -> URL {
        if let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return base.appendingPathComponent("LivingReader", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("LivingReader", isDirectory: true)
    }
}
