import Foundation

protocol AnnotationStoring: Sendable {
    func loadHighlights(bookId: UUID) throws -> [HighlightAnnotation]
    func saveHighlight(_ highlight: HighlightAnnotation) throws
    func deleteHighlight(id: UUID, bookId: UUID) throws
    func loadNotes(bookId: UUID) throws -> [NoteAnnotation]
    func saveNote(_ note: NoteAnnotation) throws
    func deleteNote(id: UUID, bookId: UUID) throws
    func saveNotePassage(_ row: NoteRow, body: String, color: HighlightColor) throws
    func deleteNotePassage(_ row: NoteRow) throws
    func loadAllHighlights() throws -> [HighlightAnnotation]
    func loadAllNotes() throws -> [NoteAnnotation]
}

private struct AnnotationBookPayload: Codable, Equatable, Sendable {
    var highlights: [HighlightAnnotation]
    var notes: [NoteAnnotation]
}

/// File-backed highlights + notes. Keys are semantic (revision + block + range), not pixels.
final class FileAnnotationStore: AnnotationStoring, @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "com.jarvis.livingreader.annotations")

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(rootDirectory: URL) throws {
        try self.init(directory: rootDirectory.appendingPathComponent("Annotations", isDirectory: true))
    }

    func loadHighlights(bookId: UUID) throws -> [HighlightAnnotation] {
        try loadPayload(bookId: bookId).highlights.sorted { $0.createdAt > $1.createdAt }
    }

    func loadNotes(bookId: UUID) throws -> [NoteAnnotation] {
        try loadPayload(bookId: bookId).notes.sorted { $0.createdAt > $1.createdAt }
    }

    func saveHighlight(_ highlight: HighlightAnnotation) throws {
        try queue.sync {
            var payload = try loadPayloadUnlocked(bookId: highlight.bookId)
            if let idx = payload.highlights.firstIndex(where: { $0.id == highlight.id }) {
                payload.highlights[idx] = highlight
            } else {
                payload.highlights.append(highlight)
            }
            try writePayloadUnlocked(payload, bookId: highlight.bookId)
        }
    }

    func deleteHighlight(id: UUID, bookId: UUID) throws {
        try queue.sync {
            var payload = try loadPayloadUnlocked(bookId: bookId)
            payload.highlights.removeAll { $0.id == id }
            try writePayloadUnlocked(payload, bookId: bookId)
        }
    }

    func saveNote(_ note: NoteAnnotation) throws {
        try queue.sync {
            var payload = try loadPayloadUnlocked(bookId: note.bookId)
            if let idx = payload.notes.firstIndex(where: { $0.id == note.id }) {
                payload.notes[idx] = note
            } else {
                payload.notes.append(note)
            }
            try writePayloadUnlocked(payload, bookId: note.bookId)
        }
    }

    func deleteNote(id: UUID, bookId: UUID) throws {
        try queue.sync {
            var payload = try loadPayloadUnlocked(bookId: bookId)
            payload.notes.removeAll { $0.id == id }
            try writePayloadUnlocked(payload, bookId: bookId)
        }
    }

    /// The visible Note is one object even though older payloads have two records.
    /// Update both halves in one atomic payload write, preserving other passages.
    func saveNotePassage(_ row: NoteRow, body: String, color: HighlightColor) throws {
        try queue.sync {
            var payload = try loadPayloadUnlocked(bookId: row.bookId)
            let highlight = payload.highlights.first { row.matches($0) }
            let note = payload.notes.first { row.matches($0) }
            let now = Date()
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            payload.highlights.removeAll { row.matches($0) }
            payload.notes.removeAll { row.matches($0) }
            payload.highlights.append(HighlightAnnotation(
                id: highlight?.id ?? row.id, bookId: row.bookId,
                chapterId: row.chapterId, chapterTitle: row.chapterTitle,
                revisionId: row.revisionId, range: row.range, selectedText: row.selectedText,
                color: color, note: trimmed.isEmpty ? nil : trimmed,
                createdAt: highlight?.createdAt ?? row.createdAt, updatedAt: now
            ))
            if !trimmed.isEmpty {
                payload.notes.append(NoteAnnotation(
                    id: note?.id ?? UUID(), bookId: row.bookId,
                    chapterId: row.chapterId, chapterTitle: row.chapterTitle,
                    revisionId: row.revisionId, range: row.range, selectedText: row.selectedText,
                    body: trimmed, createdAt: note?.createdAt ?? row.createdAt, updatedAt: now
                ))
            }
            try writePayloadUnlocked(payload, bookId: row.bookId)
        }
    }

    /// Delete exactly the reviewed passage, including duplicate legacy halves.
    /// An overlapping neighbouring note is a different passage and stays saved.
    func deleteNotePassage(_ row: NoteRow) throws {
        try queue.sync {
            var payload = try loadPayloadUnlocked(bookId: row.bookId)
            payload.highlights.removeAll { row.matches($0) }
            payload.notes.removeAll { row.matches($0) }
            try writePayloadUnlocked(payload, bookId: row.bookId)
        }
    }

    func loadAllHighlights() throws -> [HighlightAnnotation] {
        try queue.sync {
            var all: [HighlightAnnotation] = []
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for url in files where url.pathExtension == "json" {
                let data = try Data(contentsOf: url)
                let payload = try JSONCoding.decoder.decode(AnnotationBookPayload.self, from: data)
                all.append(contentsOf: payload.highlights)
            }
            return all.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func loadAllNotes() throws -> [NoteAnnotation] {
        try queue.sync {
            var all: [NoteAnnotation] = []
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for url in files where url.pathExtension == "json" {
                let data = try Data(contentsOf: url)
                let payload = try JSONCoding.decoder.decode(AnnotationBookPayload.self, from: data)
                all.append(contentsOf: payload.notes)
            }
            return all.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func loadPayload(bookId: UUID) throws -> AnnotationBookPayload {
        try queue.sync { try loadPayloadUnlocked(bookId: bookId) }
    }

    private func loadPayloadUnlocked(bookId: UUID) throws -> AnnotationBookPayload {
        let url = fileURL(bookId: bookId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AnnotationBookPayload(highlights: [], notes: [])
        }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(AnnotationBookPayload.self, from: data)
    }

    private func writePayloadUnlocked(_ payload: AnnotationBookPayload, bookId: UUID) throws {
        let data = try JSONCoding.encoder.encode(payload)
        try AtomicFileWriter.writeAtomically(data, to: fileURL(bookId: bookId))
    }

    private func fileURL(bookId: UUID) -> URL {
        directory.appendingPathComponent("\(bookId.uuidString).json")
    }
}
