import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Models

struct DefinitionSense: Equatable, Sendable, Codable, Identifiable {
    var id: String { number + "|" + gloss }
    var number: String
    var gloss: String
    var example: String?
    var isContextMatch: Bool
}

struct DefinitionComparison: Equatable, Sendable, Codable, Identifiable {
    var id: String { relationship + "|" + word }
    var word: String
    /// `"synonym"` or `"antonym"`.
    var relationship: String
    /// When to use this word vs the headword (merged tip / how-it-compares).
    var tip: String
}

struct RichDefinition: Equatable, Sendable, Codable {
    var term: String
    var partOfSpeech: String?
    var pronunciation: String?
    var senses: [DefinitionSense]
    var comparisons: [DefinitionComparison]
    var contextSentence: String?
}

struct DefinitionResult: Equatable, Sendable {
    var term: String
    /// Plain summary for Vocabulary / a11y; never a handoff string.
    var definition: String
    var source: DefinitionSource
    var hasNativeDictionaryEntry: Bool
    var rich: RichDefinition?
    /// True while a Luna enrichment request is in flight.
    var isEnriching: Bool
    /// Soft-fail note (offline / no key / network); definitions still stand alone when rich is present.
    var softFailMessage: String?

    static func plainSummary(from rich: RichDefinition) -> String {
        rich.senses.map { sense in
            var line = "\(sense.number). \(sense.gloss)"
            if let example = sense.example, !example.isEmpty {
                line += " — \(example)"
            }
            return line
        }.joined(separator: "\n")
    }
}

enum DefinitionSource: String, Codable, Equatable, Sendable {
    case localLexicon
    case luna
    case mock
    case offlineFallback
    /// Legacy: Apple Dictionary presence only — never used as a handoff destination.
    case appleDictionary
}

struct DefineWordRequest: Equatable, Sendable {
    var term: String
    var sentenceContext: String?
    var surroundingContext: String?
    var chapterTitle: String?
    var bookTitle: String?
}

// MARK: - DefineService

/// In-app Define. Never hands off to Apple Dictionary UI.
/// Prefers local lexicon → Luna structured JSON (Keychain key) → soft offline stub.
enum DefineService {
    static func dictionaryHasDefinition(forTerm term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        #if canImport(UIKit)
        return UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: trimmed)
        #else
        return false
        #endif
    }

    /// Synchronous path — always offline-safe, never calls the network, never hands off.
    static func define(
        term: String,
        sentenceContext: String? = nil,
        surroundingContext: String? = nil,
        processInfo: ProcessInfo = .processInfo
    ) -> DefinitionResult {
        let trimmed = normalizeTerm(term)
        let hasNative = dictionaryHasDefinition(forTerm: trimmed)
        let context = sentenceContext?.trimmingCharacters(in: .whitespacesAndNewlines)

        if prefersDeterministicRich(processInfo: processInfo) {
            let rich = mockRichDefinition(term: trimmed, sentenceContext: context)
            return DefinitionResult(
                term: trimmed,
                definition: DefinitionResult.plainSummary(from: rich),
                source: .mock,
                hasNativeDictionaryEntry: hasNative,
                rich: rich,
                isEnriching: false,
                softFailMessage: nil
            )
        }

        if let entry = LocalDictionaryLexicon.entry(for: trimmed) {
            let rich = entry.makeRich(sentenceContext: context)
            return DefinitionResult(
                term: trimmed,
                definition: DefinitionResult.plainSummary(from: rich),
                source: .localLexicon,
                hasNativeDictionaryEntry: hasNative,
                rich: rich,
                isEnriching: false,
                softFailMessage: nil
            )
        }

        let rich = offlineStubRich(term: trimmed, sentenceContext: context)
        var soft: String? = "Full Merriam-Webster–style senses need a network connection and your OpenAI key in Settings."
        if hasNative {
            soft = "Showing an in-app stub. Connect with your OpenAI key for full senses — GenBooks never hands off to another dictionary."
        }
        return DefinitionResult(
            term: trimmed,
            definition: DefinitionResult.plainSummary(from: rich),
            source: .offlineFallback,
            hasNativeDictionaryEntry: hasNative,
            rich: rich,
            isEnriching: false,
            softFailMessage: soft
        )
    }

    /// Async enrichment via Luna when a Keychain key is present. Soft-fails to `baseline`.
    static func enrich(
        request: DefineWordRequest,
        baseline: DefinitionResult,
        keyStore: APIKeyStoring = KeychainAPIKeyStore.shared,
        modelPreference: OpenAIModelOption = .defaultAsk,
        session: URLSession = .shared,
        processInfo: ProcessInfo = .processInfo
    ) async -> DefinitionResult {
        if prefersDeterministicRich(processInfo: processInfo) {
            return baseline
        }
        // Local lexicon already stands alone — still allow Luna to deepen when online.
        let key = (try? keyStore.loadAPIKey())?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else {
            var copy = baseline
            if copy.softFailMessage == nil, copy.source != .localLexicon {
                copy.softFailMessage = "Add an OpenAI key in Settings for full in-app definitions."
            }
            copy.isEnriching = false
            return copy
        }

        do {
            let client = DefineLiveClient(
                apiKey: key,
                preferredModel: modelPreference,
                session: session
            )
            let rich = try await client.fetchRichDefinition(request)
            return DefinitionResult(
                term: rich.term.isEmpty ? baseline.term : rich.term,
                definition: DefinitionResult.plainSummary(from: rich),
                source: .luna,
                hasNativeDictionaryEntry: baseline.hasNativeDictionaryEntry,
                rich: rich,
                isEnriching: false,
                softFailMessage: nil
            )
        } catch {
            var copy = baseline
            copy.isEnriching = false
            if copy.rich == nil || copy.source == .offlineFallback {
                copy.softFailMessage = "Couldn’t reach the dictionary service. Reading continues offline."
            }
            return copy
        }
    }

    static func prefersDeterministicRich(processInfo: ProcessInfo = .processInfo) -> Bool {
        AIServiceResolver.prefersMock(processInfo: processInfo)
    }

    /// Compatibility helper for seed/demo vocabulary rows.
    static func offlineFallbackDefinition(for term: String, sentenceContext: String? = nil) -> String {
        define(term: term, sentenceContext: sentenceContext).definition
    }

        static func normalizeTerm(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    // MARK: - Offline / mock builders

    static func offlineStubRich(term: String, sentenceContext: String?) -> RichDefinition {
        let gloss: String
        if let sentenceContext, !sentenceContext.isEmpty {
            let clipped = sentenceContext.count > 140
                ? String(sentenceContext.prefix(137)) + "…"
                : sentenceContext
            gloss = "Used in this passage as “\(term)” — full numbered senses appear when Luna can enrich the entry."
            return RichDefinition(
                term: term,
                partOfSpeech: nil,
                pronunciation: nil,
                senses: [
                    DefinitionSense(
                        number: "1",
                        gloss: gloss,
                        example: clipped,
                        isContextMatch: true
                    )
                ],
                comparisons: [],
                contextSentence: sentenceContext
            )
        }
        return RichDefinition(
            term: term,
            partOfSpeech: nil,
            pronunciation: nil,
            senses: [
                DefinitionSense(
                    number: "1",
                    gloss: "No local lexicon entry for “\(term)” yet. Enrichment fills Merriam-Webster–style senses in-app.",
                    example: nil,
                    isContextMatch: true
                )
            ],
            comparisons: [],
            contextSentence: nil
        )
    }

    static func mockRichDefinition(term: String, sentenceContext: String?) -> RichDefinition {
        if let entry = LocalDictionaryLexicon.entry(for: term) {
            return entry.makeRich(sentenceContext: sentenceContext)
        }
        // Deterministic UITest / Mock shape for arbitrary selections.
        let lower = term.lowercased()
        let matchFirst = (sentenceContext ?? "").localizedCaseInsensitiveContains(lower)
        return RichDefinition(
            term: term,
            partOfSpeech: "n.",
            pronunciation: nil,
            senses: [
                DefinitionSense(
                    number: "1",
                    gloss: "A word as used in this book’s passage (mock dictionary).",
                    example: sentenceContext.map { String($0.prefix(120)) },
                    isContextMatch: matchFirst || sentenceContext != nil
                ),
                DefinitionSense(
                    number: "2",
                    gloss: "A secondary, less likely reading kept for multi-sense UI coverage.",
                    example: "Not the sense suggested by the surrounding sentence.",
                    isContextMatch: false
                )
            ],
            comparisons: [
                DefinitionComparison(
                    word: "related term",
                    relationship: "synonym",
                    tip: "Prefer “\(term)” when the book’s sentence is about the primary sense; use a synonym when the nuance differs."
                ),
                DefinitionComparison(
                    word: "opposite",
                    relationship: "antonym",
                    tip: "Reach for the antonym when the passage means the reverse of sense 1."
                )
            ],
            contextSentence: sentenceContext
        )
    }
}

// MARK: - Local lexicon

struct LocalLexiconEntry: Sendable {
    var term: String
    var partOfSpeech: String
    var pronunciation: String?
    var senses: [(number: String, gloss: String, example: String?, matchHints: [String])]
    var comparisons: [(word: String, relationship: String, tip: String)]

    func makeRich(sentenceContext: String?) -> RichDefinition {
        let matchedIndex = Self.bestSenseIndex(senses: senses, context: sentenceContext)
        let richSenses: [DefinitionSense] = senses.enumerated().map { idx, sense in
            DefinitionSense(
                number: sense.number,
                gloss: sense.gloss,
                example: sense.example,
                isContextMatch: idx == matchedIndex
            )
        }
        return RichDefinition(
            term: term,
            partOfSpeech: partOfSpeech,
            pronunciation: pronunciation,
            senses: richSenses,
            comparisons: comparisons.map {
                DefinitionComparison(word: $0.word, relationship: $0.relationship, tip: $0.tip)
            },
            contextSentence: sentenceContext
        )
    }

    static func bestSenseIndex(
        senses: [(number: String, gloss: String, example: String?, matchHints: [String])],
        context: String?
    ) -> Int {
        guard let context, !context.isEmpty, !senses.isEmpty else { return 0 }
        let normalized = context.lowercased().replacingOccurrences(of: "-", with: " ")
        let tokens = Set(
            normalized
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )
        var best = 0
        var bestScore = -1
        for (idx, sense) in senses.enumerated() {
            var score = 0
            for hint in sense.matchHints where tokens.contains(hint.lowercased()) {
                score += 3
            }
            let glossTokens = sense.gloss.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 }
            score += glossTokens.filter { tokens.contains($0) }.count
            if score > bestScore {
                bestScore = score
                best = idx
            }
        }
        return best
    }
}

enum LocalDictionaryLexicon {
    static func entry(for term: String) -> LocalLexiconEntry? {
        let key = term.lowercased()
        return entries[key]
    }

    private static let entries: [String: LocalLexiconEntry] = {
        var map: [String: LocalLexiconEntry] = [:]
        for entry in catalog {
            map[entry.term.lowercased()] = entry
        }
        return map
    }()

    /// Curated literary / common words so Define stands alone offline for frequent taps.
    private static let catalog: [LocalLexiconEntry] = [
        LocalLexiconEntry(
            term: "fragile",
            partOfSpeech: "adj.",
            pronunciation: "/ˈfrædʒəl/",
            senses: [
                (
                    "1",
                    "Easily broken, damaged, or destroyed; delicate in structure.",
                    "The fragile vase tipped on the edge of the table.",
                    ["broken", "break", "glass", "delicate", "brittle", "crack"]
                ),
                (
                    "1 a",
                    "Physically weak or vulnerable; not robust.",
                    "After the fever he felt fragile for days.",
                    ["weak", "illness", "health", "body", "recover"]
                ),
                (
                    "2",
                    "Easily disrupted; tenuous or unstable (of a situation, peace, or agreement).",
                    "A fragile cease-fire held through the night.",
                    ["peace", "truce", "alliance", "situation", "tenuous", "unstable", "politics", "cease", "fire", "treaty", "ceasefire"]
                ),
                (
                    "3",
                    "Emotionally sensitive; easily hurt.",
                    "Handle the topic gently — she is feeling fragile.",
                    ["emotion", "feelings", "sensitive", "hurt", "heart"]
                )
            ],
            comparisons: [
                (
                    "delicate",
                    "synonym",
                    "Use delicate for fine workmanship or tact; fragile stresses breakability or instability."
                ),
                (
                    "frail",
                    "synonym",
                    "Frail often describes a person’s bodily weakness; fragile fits objects and situations too."
                ),
                (
                    "brittle",
                    "synonym",
                    "Brittle emphasizes snapping under stress; fragile is broader (including soft damage)."
                ),
                (
                    "sturdy",
                    "antonym",
                    "Sturdy is the opposite for physical toughness; use it when the passage means durable, not breakable."
                ),
                (
                    "resilient",
                    "antonym",
                    "Resilient fits recovery after stress — the reverse of sense 2’s unstable peace or mood."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "pampas",
            partOfSpeech: "n.",
            pronunciation: "/ˈpæmpəz/",
            senses: [
                (
                    "1",
                    "The extensive grassy plains of southern South America, especially in Argentina.",
                    "Across the pampas, settlements grew beside the river.",
                    ["argentina", "plains", "grass", "south", "america", "cattle", "settlement"]
                )
            ],
            comparisons: [
                (
                    "prairie",
                    "synonym",
                    "Prairie is the North American counterpart; pampas names the South American grasslands."
                ),
                (
                    "steppe",
                    "synonym",
                    "Steppe usually refers to Eurasian grasslands; prefer pampas for the Argentine plain."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "destiny",
            partOfSpeech: "n.",
            pronunciation: "/ˈdɛstəni/",
            senses: [
                (
                    "1",
                    "The events that will necessarily happen to a particular person or thing; fate.",
                    "Geography is destiny, the opening chapter argues.",
                    ["fate", "geography", "future", "inevitable"]
                ),
                (
                    "2",
                    "A hidden power believed to control what will happen; fortune.",
                    "They trusted destiny more than their maps.",
                    ["fortune", "power", "believe", "luck"]
                )
            ],
            comparisons: [
                (
                    "fate",
                    "synonym",
                    "Fate often sounds fixed and impersonal; destiny can imply a meaningful arc."
                ),
                (
                    "chance",
                    "antonym",
                    "Chance stresses randomness — use it when the passage denies necessity."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "geography",
            partOfSpeech: "n.",
            pronunciation: "/dʒiˈɑɡrəfi/",
            senses: [
                (
                    "1",
                    "The study of the physical features of the earth and human activity upon it.",
                    "Geography shaped the early colonies as much as politics did.",
                    ["earth", "land", "map", "study", "physical"]
                ),
                (
                    "2",
                    "The arrangement of places and physical features in a region.",
                    "The geography of the river valley favored trade.",
                    ["region", "river", "valley", "terrain", "place"]
                )
            ],
            comparisons: [
                (
                    "topography",
                    "synonym",
                    "Topography focuses on surface shape; geography includes human and political patterns too."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "settlement",
            partOfSpeech: "n.",
            pronunciation: "/ˈsɛtlmənt/",
            senses: [
                (
                    "1",
                    "A place where people establish a community.",
                    "A small settlement grew at the river bend.",
                    ["community", "town", "colony", "people", "establish"]
                ),
                (
                    "2",
                    "An official agreement ending a dispute.",
                    "The settlement ended years of border conflict.",
                    ["agreement", "dispute", "treaty", "conflict", "legal"]
                )
            ],
            comparisons: [
                (
                    "colony",
                    "synonym",
                    "Colony implies external control; settlement can be any new community."
                ),
                (
                    "wilderness",
                    "antonym",
                    "Wilderness is land without lasting habitation — the reverse of sense 1."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "republic",
            partOfSpeech: "n.",
            pronunciation: "/rɪˈpʌblɪk/",
            senses: [
                (
                    "1",
                    "A state in which supreme power rests with the people or their elected representatives.",
                    "The young republic debated its first constitution.",
                    ["government", "elected", "people", "constitution", "state"]
                )
            ],
            comparisons: [
                (
                    "monarchy",
                    "antonym",
                    "A monarchy centers on a hereditary sovereign; a republic centers on civic representation."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "colony",
            partOfSpeech: "n.",
            pronunciation: "/ˈkɑləni/",
            senses: [
                (
                    "1",
                    "A territory governed by a distant country.",
                    "The colony sent silver home across the Atlantic.",
                    ["empire", "govern", "territory", "spain", "distant"]
                ),
                (
                    "2",
                    "A group of people who settle in a new place but keep ties to a homeland.",
                    "An immigrant colony kept its language for a generation.",
                    ["immigrants", "settlers", "homeland", "group"]
                )
            ],
            comparisons: [
                (
                    "province",
                    "synonym",
                    "Province is an administrative unit of a state; colony stresses external rule from afar."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "independence",
            partOfSpeech: "n.",
            pronunciation: "/ˌɪndɪˈpɛndəns/",
            senses: [
                (
                    "1",
                    "Freedom from control by another country or power.",
                    "Independence arrived after years of war.",
                    ["freedom", "war", "nation", "sovereign", "control"]
                ),
                (
                    "2",
                    "The ability to live or act without relying on others.",
                    "She valued her financial independence.",
                    ["self", "rely", "autonomy", "financial"]
                )
            ],
            comparisons: [
                (
                    "sovereignty",
                    "synonym",
                    "Sovereignty emphasizes supreme authority; independence emphasizes freedom from outside rule."
                ),
                (
                    "dependence",
                    "antonym",
                    "Dependence is reliance on another power or person — the reverse of both senses."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "revolution",
            partOfSpeech: "n.",
            pronunciation: "/ˌrɛvəˈluʃən/",
            senses: [
                (
                    "1",
                    "A forcible overthrow of a government in favor of a new system.",
                    "The revolution redrew the map of the Americas.",
                    ["overthrow", "government", "war", "uprising", "political"]
                ),
                (
                    "2",
                    "A dramatic and wide-reaching change in conditions or ideas.",
                    "A scientific revolution changed how people measured the world.",
                    ["change", "ideas", "science", "dramatic"]
                )
            ],
            comparisons: [
                (
                    "rebellion",
                    "synonym",
                    "Rebellion can be narrower or unsuccessful; revolution implies a systemic transfer of power."
                ),
                (
                    "reform",
                    "synonym",
                    "Reform works inside existing institutions; revolution replaces them."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "sovereignty",
            partOfSpeech: "n.",
            pronunciation: "/ˈsɑvrənti/",
            senses: [
                (
                    "1",
                    "Supreme authority within a territory; the right to govern without outside interference.",
                    "The treaty recognized the nation’s sovereignty.",
                    ["authority", "govern", "territory", "nation", "treaty"]
                )
            ],
            comparisons: [
                (
                    "autonomy",
                    "synonym",
                    "Autonomy can be partial self-rule; sovereignty is full supreme authority."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "constitution",
            partOfSpeech: "n.",
            pronunciation: "/ˌkɑnstɪˈtuʃən/",
            senses: [
                (
                    "1",
                    "A body of fundamental principles by which a state is governed.",
                    "Delegates argued over every article of the constitution.",
                    ["law", "principles", "government", "article", "state"]
                ),
                (
                    "2",
                    "A person’s physical state of health.",
                    "He had a strong constitution despite the climate.",
                    ["health", "body", "physical", "strong"]
                )
            ],
            comparisons: [
                (
                    "charter",
                    "synonym",
                    "A charter often grants rights from a higher power; a constitution is the state’s own foundation."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "empire",
            partOfSpeech: "n.",
            pronunciation: "/ˈɛmpaɪər/",
            senses: [
                (
                    "1",
                    "A group of territories ruled by a single sovereign power.",
                    "The empire stretched from the Andes to the sea.",
                    ["territories", "ruled", "power", "emperor", "spain"]
                )
            ],
            comparisons: [
                (
                    "kingdom",
                    "synonym",
                    "Kingdom usually centers on one people and crown; empire stresses rule over many lands."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "frontier",
            partOfSpeech: "n.",
            pronunciation: "/frʌnˈtɪr/",
            senses: [
                (
                    "1",
                    "A border between two countries.",
                    "Soldiers patrolled the northern frontier.",
                    ["border", "boundary", "countries", "patrol"]
                ),
                (
                    "2",
                    "The edge of settled territory; a zone of expansion or exploration.",
                    "Ranchers pushed the frontier west across the plains.",
                    ["settled", "expansion", "west", "edge", "pioneer"]
                )
            ],
            comparisons: [
                (
                    "boundary",
                    "synonym",
                    "Boundary is the legal line; frontier often includes the unsettled zone beyond it."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "legacy",
            partOfSpeech: "n.",
            pronunciation: "/ˈlɛɡəsi/",
            senses: [
                (
                    "1",
                    "Something handed down from an ancestor or from the past.",
                    "The war left a complicated legacy.",
                    ["past", "handed", "ancestor", "history", "inheritance"]
                ),
                (
                    "2",
                    "Money or property left to someone in a will.",
                    "She received a small legacy from her aunt.",
                    ["will", "money", "property", "inherit"]
                )
            ],
            comparisons: [
                (
                    "inheritance",
                    "synonym",
                    "Inheritance is often legal or material; legacy can be cultural or moral as well."
                )
            ]
        ),
        LocalLexiconEntry(
            term: "narrative",
            partOfSpeech: "n.",
            pronunciation: "/ˈnærətɪv/",
            senses: [
                (
                    "1",
                    "A spoken or written account of connected events; a story.",
                    "The chapter’s narrative moves from conquest to independence.",
                    ["story", "account", "events", "chapter", "history"]
                ),
                (
                    "2",
                    "A particular way of explaining or understanding events.",
                    "Officials offered a competing narrative of the crisis.",
                    ["explanation", "framing", "version", "understanding"]
                )
            ],
            comparisons: [
                (
                    "story",
                    "synonym",
                    "Story is everyday; narrative often signals crafted structure or historical framing."
                )
            ]
        )
    ]
}

// MARK: - Luna client

struct DefineLiveClient: @unchecked Sendable {
    var apiKey: String
    var preferredModel: OpenAIModelOption
    var session: URLSession
    var endpoint: URL
    var timeout: TimeInterval

    init(
        apiKey: String,
        preferredModel: OpenAIModelOption = .defaultAsk,
        session: URLSession? = nil,
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        timeout: TimeInterval = 25
    ) {
        self.apiKey = apiKey
        self.preferredModel = preferredModel
        self.endpoint = endpoint
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    func fetchRichDefinition(_ request: DefineWordRequest) async throws -> RichDefinition {
        let system = """
        You are an in-app dictionary for GenBooks. Return Merriam-Webster–quality JSON only.
        Never tell the reader to open another dictionary app. Definitions must stand alone.
        Mark exactly one sense with "isContextMatch": true — the sense that best fits the book sentence.
        Number senses like MW: "1", "1 a", "1 b", "2", …
        comparisons merges synonyms and antonyms; each tip explains when to use that word vs the headword.
        """
        var user = "Define “\(request.term)” for a reader."
        if let sentence = request.sentenceContext, !sentence.isEmpty {
            user += "\nSentence: \(sentence)"
        }
        if let surrounding = request.surroundingContext, !surrounding.isEmpty {
            user += "\nSurrounding: \(surrounding.prefix(400))"
        }
        if let chapter = request.chapterTitle {
            user += "\nChapter: \(chapter)"
        }
        if let book = request.bookTitle {
            user += "\nBook: \(book)"
        }
        user += """

        Respond with JSON:
        {
          "term": "string",
          "partOfSpeech": "n.|v.|adj.|adv.|…",
          "pronunciation": "/…/" or null,
          "senses": [{"number":"1","gloss":"…","example":"…","isContextMatch":true}],
          "comparisons": [{"word":"…","relationship":"synonym|antonym","tip":"when to use this vs the headword"}]
        }
        """

        let models = [preferredModel] + preferredModel.fallbacks
        var lastError: Error = AIServiceError.modelUnavailable(preferredModel.rawValue)
        for model in models {
            do {
                let text = try await chat(model: model, system: system, user: user)
                return try Self.decodeRich(text, fallbackTerm: request.term, sentenceContext: request.sentenceContext)
            } catch {
                lastError = error
                if let ai = error as? AIServiceError {
                    switch ai {
                    case .modelUnavailable, .httpStatus(404, _), .httpStatus(400, _):
                        continue
                    default:
                        throw error
                    }
                }
            }
        }
        throw lastError
    }

    private func chat(model: OpenAIModelOption, system: String, user: String) async throws -> String {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model.rawValue,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.3,
            "max_tokens": 1200,
            "response_format": ["type": "json_object"]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.underlying("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AIServiceError.missingAPIKey
            }
            if http.statusCode == 404 || http.statusCode == 400 {
                throw AIServiceError.modelUnavailable(model.rawValue)
            }
            throw AIServiceError.httpStatus(http.statusCode, nil)
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw AIServiceError.malformedResponse
        }
        return content
    }

    private struct Payload: Decodable {
        var term: String?
        var partOfSpeech: String?
        var pronunciation: String?
        var senses: [Sense]?
        var comparisons: [Comparison]?

        struct Sense: Decodable {
            var number: String?
            var gloss: String?
            var example: String?
            var isContextMatch: Bool?
        }

        struct Comparison: Decodable {
            var word: String?
            var relationship: String?
            var tip: String?
        }
    }

    static func decodeRich(_ text: String, fallbackTerm: String, sentenceContext: String?) throws -> RichDefinition {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { throw AIServiceError.malformedResponse }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw AIServiceError.malformedResponse
        }
        var senses = (payload.senses ?? []).compactMap { sense -> DefinitionSense? in
            guard let gloss = sense.gloss?.trimmingCharacters(in: .whitespacesAndNewlines), !gloss.isEmpty else {
                return nil
            }
            return DefinitionSense(
                number: (sense.number?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "1",
                gloss: gloss,
                example: sense.example?.trimmingCharacters(in: .whitespacesAndNewlines),
                isContextMatch: sense.isContextMatch ?? false
            )
        }
        guard !senses.isEmpty else { throw AIServiceError.malformedResponse }
        if !senses.contains(where: \.isContextMatch) {
            senses[0].isContextMatch = true
        } else {
            // Ensure exactly one match highlight.
            var seen = false
            for i in senses.indices {
                if senses[i].isContextMatch {
                    if seen { senses[i].isContextMatch = false }
                    seen = true
                }
            }
        }
        let comparisons = (payload.comparisons ?? []).compactMap { row -> DefinitionComparison? in
            guard let word = row.word?.trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty else {
                return nil
            }
            let rel = (row.relationship ?? "synonym").lowercased()
            let relationship = (rel == "antonym") ? "antonym" : "synonym"
            let tip = row.tip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return DefinitionComparison(word: word, relationship: relationship, tip: tip)
        }
        return RichDefinition(
            term: (payload.term?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTerm,
            partOfSpeech: payload.partOfSpeech?.trimmingCharacters(in: .whitespacesAndNewlines),
            pronunciation: payload.pronunciation?.trimmingCharacters(in: .whitespacesAndNewlines),
            senses: senses,
            comparisons: comparisons,
            contextSentence: sentenceContext
        )
    }
}
