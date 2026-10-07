import Foundation

/// Model id preferences only — never the API key. Key stays in Keychain.
/// Stores separate Ask vs book-generation model ids.
@MainActor
final class AIModelPreferenceStore: ObservableObject {
    @Published var askModel: OpenAIModelOption {
        didSet { defaults.set(askModel.rawValue, forKey: Keys.askModel) }
    }

    @Published var generationModel: OpenAIModelOption {
        didSet { defaults.set(generationModel.rawValue, forKey: Keys.generationModel) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let askModel = "livingreader.ai.askModel"
        static let generationModel = "livingreader.ai.generationModel"
        /// Legacy single-model key — migrated once into ask + generation when present.
        static let legacyPreferred = "livingreader.ai.preferredModel"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let legacy = defaults.string(forKey: Keys.legacyPreferred).flatMap(OpenAIModelOption.init(rawValue:))

        if let raw = defaults.string(forKey: Keys.askModel),
           let model = OpenAIModelOption(rawValue: raw) {
            self.askModel = model
        } else if let legacy {
            self.askModel = legacy
        } else {
            self.askModel = .defaultAsk
        }

        if let raw = defaults.string(forKey: Keys.generationModel),
           let model = OpenAIModelOption(rawValue: raw) {
            self.generationModel = model
        } else if let legacy {
            self.generationModel = legacy
        } else {
            self.generationModel = .defaultGeneration
        }

        // Persist split keys so future launches don't re-read legacy.
        defaults.set(askModel.rawValue, forKey: Keys.askModel)
        defaults.set(generationModel.rawValue, forKey: Keys.generationModel)
    }
}
