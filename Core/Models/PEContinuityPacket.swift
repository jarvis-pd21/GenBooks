import Foundation

/// The three packets Astra receives, in assembly order. The `A`/`B`/`C` labels
/// are part of the wire format so a prompt is self-describing and the design
/// packet (`progress/PE_CONTINUITY_PACKET.md`) and the code cannot drift.
enum PEPacketSection: String, CaseIterable, Sendable {
    case readerBrief = "A"
    case continuityState = "B"
    case factChecklist = "C"

    var title: String {
        switch self {
        case .readerBrief: return "READER BRIEF"
        case .continuityState: return "CONTINUITY STATE"
        case .factChecklist: return "FACT CHECKLIST"
        }
    }

    /// Section marker as it appears in the prompt, e.g. `[PACKET A — READER BRIEF]`.
    var header: String { "[PACKET \(rawValue) — \(title)]" }
}

/// The PE (prompt-engineering) packet handed to Astra for book generation and
/// adaptation. Assembled — and rendered into prompts — as Packet A (reader
/// brief), then Packet B (continuity state), then Packet C (fact checklist).
struct PEContinuityPacket: Equatable, Sendable {
    /// Packet A.
    var brief: ReaderBrief?
    /// Packet B.
    var continuity: ContinuityState
    /// Packet C.
    var facts: FactChecklist

    static func empty(bookId: UUID, at date: Date = Date()) -> PEContinuityPacket {
        PEContinuityPacket(
            brief: nil,
            continuity: .empty(bookId: bookId, at: date),
            facts: .empty(bookId: bookId, at: date)
        )
    }
}

/// What a Stage-2 generation returns: prose plus the continuity and facts it
/// claims to have written. A model that returns only blocks still works — it
/// simply cannot introduce new essential claims.
struct GeneratedChapter: Equatable, Sendable {
    var blocks: [ContentBlock]
    var continuityDelta: ContinuityDelta?
    var proposedClaims: [FactClaim]
    var proposedEvidence: [FactEvidenceItem]

    init(
        blocks: [ContentBlock],
        continuityDelta: ContinuityDelta? = nil,
        proposedClaims: [FactClaim] = [],
        proposedEvidence: [FactEvidenceItem] = []
    ) {
        self.blocks = blocks
        self.continuityDelta = continuityDelta
        self.proposedClaims = proposedClaims
        self.proposedEvidence = proposedEvidence
    }
}

/// Why the PE gate refused to let a new unread revision go live.
///
/// Every case is a soft failure: the prior revision stays readable and the
/// consumed past is untouched.
enum PEGateError: Error, Equatable, LocalizedError, Sendable {
    case bookMismatch(expected: UUID, found: UUID)
    case missingEvidenceIds(claimId: UUID, evidenceIds: [String])
    case emptyEvidenceDigest(evidenceId: String)
    case unverifiedEssentialClaim(claimId: UUID, status: FactVerificationStatus)
    case checklistUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .bookMismatch(let expected, let found):
            return "Packet belongs to book \(found), expected \(expected)"
        case .missingEvidenceIds(let claimId, let ids):
            let short = claimId.uuidString.prefix(8)
            if ids.isEmpty {
                return "Claim \(short)… cites no evidence"
            }
            return "Claim \(short)… cites unknown evidence: \(ids.joined(separator: ", "))"
        case .emptyEvidenceDigest(let evidenceId):
            return "Evidence \(evidenceId) has an empty digest"
        case .unverifiedEssentialClaim(let claimId, let status):
            return "Essential claim \(claimId.uuidString.prefix(8))… is \(status.rawValue)"
        case .checklistUnreadable(let reason):
            return "Fact checklist could not be read: \(reason)"
        }
    }
}
