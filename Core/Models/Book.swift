import Foundation

struct Book: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var title: String
    var author: String
    var subtitle: String? = nil
    var synopsis: String? = nil
    /// Named cover treatment for library chrome (e.g. "argentina-sky").
    var coverAccent: String? = nil
    var edition: BookEdition? = nil
    var timeline: [TimelineEvent] = []
    var provenanceNotes: [String] = []
    var chapters: [Chapter]

    var polishedChapterCount: Int {
        chapters.filter { ($0.manuscriptStatus ?? .polished) == .polished }.count
    }

    var outlineChapterCount: Int {
        chapters.filter { ($0.manuscriptStatus ?? .polished) == .outline }.count
    }

    /// Friend-demo chrome: imported files are Canon (verbatim); generated/seeded books are Living.
    /// `edition.label == "Living"` wins so a Canon import that was Made Living stays Living
    /// even if the cover treatment is still `imported` (no new cover assets).
    var isCanonImport: Bool {
        if edition?.label == "Living" { return false }
        return coverAccent == "imported"
            || edition?.label == "Canon"
            || edition?.label == "Imported"
            || subtitleStartsWithCanon
    }

    /// True after Make Living / first successful adapt Apply from a Canon import.
    var isLivingFromCanon: Bool {
        guard !isCanonImport else { return false }
        if subtitle?.localizedCaseInsensitiveContains("from Canon") == true { return true }
        return provenanceNotes.contains {
            $0.localizedCaseInsensitiveContains("Made Living from Canon")
        }
    }

    var libraryKindLabel: String {
        isCanonImport ? "CANON" : "A LIVING BOOK"
    }

    /// Canon More shows Make Living only for a user-owned import. Quran seed is refused
    /// (folded from closed GenAB #56). Argentina / generated Living books keep Regen.
    var canMakeLivingFromCanon: Bool {
        isCanonImport && id != QuranFixtureIDs.book
    }

    private var subtitleStartsWithCanon: Bool {
        guard let subtitle, !subtitle.isEmpty else { return false }
        return subtitle.range(of: "Canon", options: [.caseInsensitive, .anchored]) != nil
    }

    /// Metadata-only flip: Canon import → Living. Chapters and revisions are unchanged.
    func promotedToLivingFromCanon(at date: Date = Date()) -> Book {
        var next = self
        next.subtitle = "Living · from Canon"
        if var edition {
            edition.label = "Living"
            next.edition = edition
        } else {
            next.edition = BookEdition(
                id: UUID(),
                bookId: id,
                label: "Living",
                localeIdentifier: "en"
            )
        }
        let stamp = ISO8601DateFormatter().string(from: date)
        next.provenanceNotes.append(
            "Made Living from Canon import on \(stamp). Unread future may adapt; consumed past stays the exact imported words."
        )
        return next
    }
}
