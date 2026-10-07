import Foundation

/// File-backed home for the three PE packets, beside the preference and
/// manuscript/version stores under the same root.
///
/// The store owns persistence only. Mutation stays in the sanctioned engines:
/// `ReaderBrief.make` (projection of `ReaderPreferenceProfile`),
/// `ContinuityMerge`, and `FactChecklistMerge`.
protocol PEPacketStoring: Sendable {
    func loadBrief(bookId: UUID) throws -> ReaderBrief?
    func saveBrief(_ brief: ReaderBrief) throws

    func loadContinuity(bookId: UUID) throws -> ContinuityState
    func saveContinuity(_ state: ContinuityState) throws

    func loadFactChecklist(bookId: UUID) throws -> FactChecklist
    func saveFactChecklist(_ checklist: FactChecklist) throws
    /// Compare-and-swap only the continuation field; nil next archives the old draft.
    func transitionSourceContinuation(bookId: UUID, expected: SourceContinuationState?, next: SourceContinuationState?) throws

    /// All three packets in one read, for prompt assembly.
    func loadPacket(bookId: UUID) throws -> PEContinuityPacket

    /// Re-derives the brief from the sanctioned preference profile and persists it.
    @discardableResult
    func refreshBrief(book: Book, profile: ReaderPreferenceProfile) throws -> ReaderBrief

    /// Merges a continuity delta, preserving consumed timeline entries verbatim.
    @discardableResult
    func mergeContinuity(_ delta: ContinuityDelta) throws -> ContinuityMergeResult

    /// Pins a finished chapter's continuity entry as immutable.
    @discardableResult
    func recordConsumedContinuity(
        bookId: UUID,
        chapter: Chapter,
        revision: ChapterRevision
    ) throws -> ContinuityState
}

extension PEPacketStoring {
    func transitionSourceContinuation(bookId: UUID, expected: SourceContinuationState?, next: SourceContinuationState?) throws {
        throw SourceGroundingError.invalid("This packet store cannot safely save a source continuation.")
    }
}

/// Same canonical directory, same lock across store instances in this process.
/// This is not a cross-process or multi-file transaction.
private final class PacketDirectoryLock: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: PacketDirectoryLock] = [:]
    private let lock = NSRecursiveLock()
    static func shared(_ directory: URL) -> PacketDirectoryLock {
        registryLock.lock(); defer { registryLock.unlock() }
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        if let value = registry[path] { return value }
        let value = PacketDirectoryLock()
        registry[path] = value
        return value
    }
    func sync<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }
}

final class FilePEPacketStore: PEPacketStoring, @unchecked Sendable {
    let directory: URL
    private let queue: PacketDirectoryLock

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.queue = PacketDirectoryLock.shared(directory)
    }

    convenience init(rootDirectory: URL) throws {
        try self.init(directory: rootDirectory.appendingPathComponent("Packets", isDirectory: true))
    }

    // MARK: - Brief

    func loadBrief(bookId: UUID) throws -> ReaderBrief? {
        try queue.sync { try loadBriefUnlocked(bookId: bookId) }
    }

    func saveBrief(_ brief: ReaderBrief) throws {
        try queue.sync { try write(brief, to: url(bookId: brief.bookId, packet: "brief")) }
    }

    @discardableResult
    func refreshBrief(book: Book, profile: ReaderPreferenceProfile) throws -> ReaderBrief {
        try queue.sync {
            let brief = ReaderBrief.make(book: book, profile: profile)
            try write(brief, to: url(bookId: book.id, packet: "brief"))
            return brief
        }
    }

    // MARK: - Continuity

    func loadContinuity(bookId: UUID) throws -> ContinuityState {
        try queue.sync { try loadContinuityUnlocked(bookId: bookId) }
    }

    func saveContinuity(_ state: ContinuityState) throws {
        try queue.sync { try write(state, to: url(bookId: state.bookId, packet: "continuity")) }
    }

    @discardableResult
    func mergeContinuity(_ delta: ContinuityDelta) throws -> ContinuityMergeResult {
        try queue.sync {
            let current = try loadContinuityUnlocked(bookId: delta.bookId)
            let result = try ContinuityMerge.merge(delta, into: current)
            try write(result.state, to: url(bookId: delta.bookId, packet: "continuity"))
            return result
        }
    }

    @discardableResult
    func recordConsumedContinuity(
        bookId: UUID,
        chapter: Chapter,
        revision: ChapterRevision
    ) throws -> ContinuityState {
        try queue.sync {
            let current = try loadContinuityUnlocked(bookId: bookId)
            let next = ContinuityMerge.markConsumed(
                chapterId: chapter.id,
                in: current,
                creating: ContinuityDeltaBuilder.consumedEntry(chapter: chapter, revision: revision)
            )
            try write(next, to: url(bookId: bookId, packet: "continuity"))
            return next
        }
    }

    // MARK: - Fact checklist

    func loadFactChecklist(bookId: UUID) throws -> FactChecklist {
        try queue.sync { try loadFactsUnlocked(bookId: bookId) }
    }

    func saveFactChecklist(_ checklist: FactChecklist) throws {
        try queue.sync {
            let current = try loadFactsUnlocked(bookId: checklist.bookId)
            var next = checklist
            // Whole-checklist callers may have suspended before writing. These
            // two fields have their own CAS owner and cannot be replaced here.
            next.sourceContinuation = current.sourceContinuation
            next.sourceContinuationArchive = current.sourceContinuationArchive
            try write(next, to: url(bookId: checklist.bookId, packet: "facts"))
        }
    }

    func transitionSourceContinuation(bookId: UUID, expected: SourceContinuationState?, next: SourceContinuationState?) throws {
        try queue.sync {
            var current = try loadFactsUnlocked(bookId: bookId)
            guard try SourceGrounding.hash(current.sourceContinuation) == SourceGrounding.hash(expected),
                  next == nil || next?.bookID == bookId else {
                throw SourceGroundingError.invalid("The saved rewrite changed in another reader. Reopen it before continuing.")
            }
            if let expected, next == nil {
                var archive = current.sourceContinuationArchive ?? []
                archive.append(expected)
                current.sourceContinuationArchive = archive
            }
            current.sourceContinuation = next
            current.updatedAt = Date()
            try write(current, to: url(bookId: bookId, packet: "facts"))
        }
    }

    // MARK: - Packet

    func loadPacket(bookId: UUID) throws -> PEContinuityPacket {
        try queue.sync {
            PEContinuityPacket(
                brief: try loadBriefUnlocked(bookId: bookId),
                continuity: try loadContinuityUnlocked(bookId: bookId),
                facts: try loadFactsUnlocked(bookId: bookId)
            )
        }
    }

    // MARK: - Private

    private func url(bookId: UUID, packet: String) -> URL {
        directory.appendingPathComponent("\(bookId.uuidString)-\(packet).json")
    }

    private func loadBriefUnlocked(bookId: UUID) throws -> ReaderBrief? {
        try read(ReaderBrief.self, from: url(bookId: bookId, packet: "brief"))
    }

    private func loadContinuityUnlocked(bookId: UUID) throws -> ContinuityState {
        try read(ContinuityState.self, from: url(bookId: bookId, packet: "continuity"))
            ?? .empty(bookId: bookId)
    }

    private func loadFactsUnlocked(bookId: UUID) throws -> FactChecklist {
        try read(FactChecklist.self, from: url(bookId: bookId, packet: "facts"))
            ?? .empty(bookId: bookId)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONCoding.encoder.encode(value)
        try AtomicFileWriter.writeAtomically(data, to: url)
    }
}
