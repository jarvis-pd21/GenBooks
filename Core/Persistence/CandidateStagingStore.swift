import Foundation

protocol CandidateStagingStore: Sendable {
    func save(_ candidate: CandidateRevision) async throws
    func load(id: UUID) async throws -> CandidateRevision?
    func delete(id: UUID) async throws
}

struct FileCandidateStagingStore: CandidateStagingStore {
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func save(_ candidate: CandidateRevision) throws {
        let data = try JSONCoding.encoder.encode(candidate)
        try AtomicFileWriter.writeAtomically(data, to: url(for: candidate.id))
    }

    func load(id: UUID) throws -> CandidateRevision? {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        do {
            return try JSONCoding.decoder.decode(CandidateRevision.self, from: data)
        } catch {
            throw ManuscriptError.malformedCandidate("decode failed: \(error.localizedDescription)")
        }
    }

    func delete(id: UUID) throws {
        let file = url(for: id)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Writes raw bytes (used by crash-safety tests to plant malformed candidates).
    func writeRaw(id: UUID, data: Data) throws {
        try AtomicFileWriter.writeAtomically(data, to: url(for: id))
    }
}
