import Foundation

/// Renders a `PEContinuityPacket` into the Astra plan/generate prompts.
///
/// The section order is load-bearing, not cosmetic: the model reads the standing
/// contract before it ever sees the task, so later chapter-specific instructions
/// are interpreted against it rather than replacing it.
///
///   - Packet A `READER BRIEF`     — voice, emphasis, non-negotiables
///   - Packet B `CONTINUITY STATE` — consumed (immutable) timeline, then unread, then carried threads
///   - Packet C `FACT CHECKLIST`   — claims with verification status, then evidence digests
///
/// Every section is bounded so a long book cannot crowd out the task itself.
enum PEPacketPromptAssembler {
    static var sectionOrder: [String] { PEPacketSection.allCases.map(\.title) }

    static let maxConsumedEntries = 6
    static let maxUnreadEntries = 3
    static let maxCarriedThreads = 8
    static let maxClaims = 12
    static let maxEvidence = 12
    static let entryDigestCharacters = 240
    static let evidenceDigestCharacters = 200

    /// Rules appended to the Astra system prompts. Mirrors what the gate enforces
    /// locally, so a well-behaved model never trips it.
    static let promptRules = """
    PE packet contract (packets arrive in order: \(PEPacketSection.allCases.map { "\($0.rawValue)=\($0.title)" }.joined(separator: " → "))):
    - Packet A is the reader's standing voice contract. Honour it for tone and emphasis; it never licenses changing facts.
    - Packet B entries marked CONSUMED are immutable history. Stay consistent with them; never restate them differently and never rewrite those chapters.
    - Carry Packet B's unresolved threads forward or resolve them explicitly; do not drop them silently.
    - Any load-bearing historical assertion is an ESSENTIAL claim. Essential claims must cite evidence ids that exist in Packet C and must already be verified there. If evidence is missing, omit the assertion or report insufficient evidence. Never relabel an unsupported factual assertion as supporting colour to bypass verification.
    - Never invent an evidence id, and never cite an evidence id whose digest is blank.
    - Reuse a verified claim only in its recorded chapter, by returning {"claimId":"its actual id"}. Claim text below is a bounded preview; the client resolves the exact stored statement and citations. Do not repeat or replace that claim's evidence payload.
    """

    static func render(_ packet: PEContinuityPacket?, focusChapterId: UUID? = nil) -> String {
        guard let packet else { return "" }
        let sections = [
            briefSection(packet.brief),
            continuitySection(packet.continuity),
            factSection(packet.facts, focusChapterId: focusChapterId)
        ]
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - 1. Reader brief

    private static func briefSection(_ brief: ReaderBrief?) -> String {
        guard let brief else { return "" }
        var lines = [PEPacketSection.readerBrief.header, "voice: \(brief.voice)"]
        if !brief.moreOfEmphasis.isEmpty {
            lines.append("more of: \(brief.moreOfEmphasis.joined(separator: ", "))")
        }
        if !brief.lessOfEmphasis.isEmpty {
            lines.append("less of: \(brief.lessOfEmphasis.joined(separator: ", "))")
        }
        for note in brief.readerNotes {
            lines.append("reader note: \(clip(note, to: entryDigestCharacters))")
        }
        for rule in brief.nonNegotiables {
            lines.append("non-negotiable: \(rule)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 2. Continuity state

    private static func continuitySection(_ state: ContinuityState) -> String {
        let consumed = state.consumedEntries.suffix(maxConsumedEntries)
        let unread = state.unreadEntries.prefix(maxUnreadEntries)
        if consumed.isEmpty && unread.isEmpty && state.carriedThreads.isEmpty {
            return PEPacketSection.continuityState.header + "\n(no continuity recorded yet)"
        }

        var lines = [PEPacketSection.continuityState.header]
        for entry in consumed {
            lines.append(line(for: entry, marker: "CONSUMED (immutable)"))
        }
        for entry in unread {
            lines.append(line(for: entry, marker: "unread"))
        }
        if !state.carriedThreads.isEmpty {
            let threads = state.carriedThreads.prefix(maxCarriedThreads).joined(separator: "; ")
            lines.append("open threads: \(threads)")
        }
        return lines.joined(separator: "\n")
    }

    private static func line(for entry: ContinuityEntry, marker: String) -> String {
        var text = "- ch\(entry.chapterOrderIndex) “\(entry.chapterTitle)” [\(marker)]: "
            + clip(entry.digest, to: entryDigestCharacters)
        if !entry.establishedFacts.isEmpty {
            text += "\n  established: \(entry.establishedFacts.joined(separator: ", "))"
        }
        if !entry.openThreads.isEmpty {
            text += "\n  threads: \(entry.openThreads.joined(separator: "; "))"
        }
        return text
    }

    // MARK: - 3. Fact checklist

    private static func factSection(_ checklist: FactChecklist, focusChapterId: UUID?) -> String {
        let claims = orderedClaims(checklist, focusChapterId: focusChapterId)
        if claims.isEmpty && checklist.evidence.isEmpty {
            return PEPacketSection.factChecklist.header
                + "\n(no claims recorded — do not assert new essential facts)"
        }

        var lines = [PEPacketSection.factChecklist.header]
        for claim in claims.prefix(maxClaims) {
            let ids = claim.evidenceIds.isEmpty ? "none" : claim.evidenceIds.joined(separator: ", ")
            lines.append(
                "- [\(claim.importance.rawValue)/\(claim.status.rawValue)] "
                    + "claimId=\(claim.id.uuidString) chapterId=\(claim.chapterId.uuidString) preview: "
                    + clip(claim.statement, to: entryDigestCharacters)
                    + " (evidence: \(ids))"
            )
        }

        let cited = Set(claims.flatMap(\.evidenceIds))
        let evidence = checklist.evidence
            .filter { cited.isEmpty || cited.contains($0.id) }
            .sorted { $0.id < $1.id }
            .prefix(maxEvidence)
        for item in evidence {
            let digest = item.hasUsableDigest
                ? clip(item.digest, to: evidenceDigestCharacters)
                : "(EMPTY DIGEST — unusable)"
            lines.append("- evidence \(item.id) — \(item.sourceLabel): \(digest)")
        }
        return lines.joined(separator: "\n")
    }

    /// Claims for the chapter being written come first; the rest give context.
    private static func orderedClaims(_ checklist: FactChecklist, focusChapterId: UUID?) -> [FactClaim] {
        guard let focusChapterId else { return checklist.claims }
        let focus = checklist.claims.filter { $0.chapterId == focusChapterId }
        let others = checklist.claims.filter { $0.chapterId != focusChapterId }
        return focus + others
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
