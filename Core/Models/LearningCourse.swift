import Foundation

/// Bundled original content, distinct from the learner's observations.
struct LearningCourse: Decodable, Sendable {
    let schemaVersion: Int
    let id: String
    let title: String
    let subtitle: String
    let authorship: String
    let sources: [Source]
    let concepts: [Concept]
    let lessons: [Lesson]
    let delayedReview: Review

    struct Source: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let url: URL
        let supports: String
        let rights: String
    }
    struct Concept: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let objective: String
        let boundaries: String
    }
    struct Lesson: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let conceptIds: [String]
        let openingQuestion: String
        let blocks: [Block]
        let checks: [Question]
        let reflectionPrompt: String
        var text: String { blocks.map(\.text).joined(separator: "\n\n") }
    }
    struct Block: Decodable, Sendable { let kind: String; let text: String }
    struct Question: Decodable, Identifiable, Sendable {
        let id: String
        let conceptId: String
        let prompt: String
        let choices: [Choice]
        let correctChoiceId: String
        let explanation: String
        let misconception: String
        let sourceIds: [String]
        struct Choice: Decodable, Identifiable, Sendable { let id: String; let text: String }
    }
    struct Review: Decodable, Sendable { let checks: [Question] }

    static func load(bundle: Bundle = .main) throws -> LearningCourse {
        let url = try BundleFixtureLoader.urlForFixtureFile(named: "physics_foundations", ext: "json", from: bundle)
        let course = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try course.validate()
        return course
    }

    /// Pin this unit's exact wording locally; later app updates cannot silently replace it.
    static func loadSnapshot(directory: URL, bundle: Bundle = .main) throws -> LearningCourse {
        let destination = directory.appendingPathComponent("physics-foundations-v1.json")
        if FileManager.default.fileExists(atPath: destination.path) {
            let course = try JSONDecoder().decode(Self.self, from: Data(contentsOf: destination))
            try course.validate()
            return course
        }
        let source = try BundleFixtureLoader.urlForFixtureFile(named: "physics_foundations", ext: "json", from: bundle)
        let data = try Data(contentsOf: source)
        let course = try JSONDecoder().decode(Self.self, from: data)
        try course.validate()
        try AtomicFileWriter.writeAtomically(data, to: destination)
        return course
    }

    func validate() throws {
        func require(_ condition: Bool) throws {
            if !condition { throw CocoaError(.fileReadCorruptFile) }
        }
        try require(schemaVersion == 1 && !lessons.isEmpty && !concepts.isEmpty)
        try require(Set(lessons.map(\.id)).count == lessons.count)
        let conceptIDs = Set(concepts.map(\.id))
        let sourceIDs = Set(sources.map(\.id))
        try require(conceptIDs.count == concepts.count && sourceIDs.count == sources.count)
        try require(sources.allSatisfy { $0.url.scheme == "https" && $0.url.host != nil })
        let questions = lessons.flatMap(\.checks) + delayedReview.checks
        try require(Set(questions.map(\.id)).count == questions.count)
        for lesson in lessons {
            try require(!lesson.blocks.isEmpty && lesson.conceptIds.allSatisfy(conceptIDs.contains))
            try require(lesson.blocks.allSatisfy { ["paragraph", "heading", "callout", "quote"].contains($0.kind) && !$0.text.isEmpty })
        }
        for question in questions {
            try require(conceptIDs.contains(question.conceptId) && !question.sourceIds.isEmpty)
            try require(question.sourceIds.allSatisfy(sourceIDs.contains))
            try require(question.choices.count >= 2 && Set(question.choices.map(\.id)).count == question.choices.count)
            try require(question.choices.contains { $0.id == question.correctChoiceId })
        }
    }

    func questions(for conceptID: String, reviewing: Bool) -> [Question] {
        let initial = lessons.flatMap(\.checks).filter { $0.conceptId == conceptID }
        return reviewing ? delayedReview.checks.filter { $0.conceptId == conceptID } + initial : initial
    }
}
