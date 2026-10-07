import Foundation

/// Shelf visibility only. Archiving never removes a manuscript or its reading data.
struct LibraryVisibilityStore {
    let fileURL: URL

    init(rootDirectory: URL) {
        fileURL = rootDirectory.appendingPathComponent("LibraryVisibility.json")
    }

    func loadArchivedIDs() throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return Set(try JSONDecoder().decode([UUID].self, from: Data(contentsOf: fileURL)))
    }

    /// Re-read first so a failed read cannot replace an existing preference file.
    func setArchived(_ archived: Bool, bookID: UUID) throws -> Set<UUID> {
        var ids = try loadArchivedIDs()
        if archived { ids.insert(bookID) } else { ids.remove(bookID) }
        let ordered = ids.sorted { $0.uuidString < $1.uuidString }
        try AtomicFileWriter.writeAtomically(JSONEncoder().encode(ordered), to: fileURL)
        return ids
    }
}
