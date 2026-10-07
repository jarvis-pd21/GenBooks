import Foundation

enum FactClaimImportance: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Load-bearing for the chapter's history; may not ship unverified.
    case essential
    /// Colour and texture; may ship while still unverified.
    case supporting

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .essential: return "Essential"
        case .supporting: return "Supporting"
        }
    }
}

enum FactVerificationStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case verified
    case unverified
    case disputed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .verified: return "Verified"
        case .unverified: return "Unverified"
        case .disputed: return "Disputed"
        }
    }
}

/// A citeable piece of evidence backing one or more claims.
///
/// `digest` carries the substance. An item with a blank digest is a stub — it
/// can be recorded while research is in flight, but it can never back a claim
/// in a revision that goes live.
struct FactEvidenceItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Stable authored id (e.g. `ev-cabildo-1810`) referenced by claims.
    var id: String
    var sourceLabel: String
    var digest: String
    var locator: String?
    var recordedAt: Date
    var retrievedSource: RetrievedResearchSource? = nil

    init(
        id: String,
        sourceLabel: String,
        digest: String,
        locator: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.sourceLabel = sourceLabel
        self.digest = digest
        self.locator = locator
        self.recordedAt = recordedAt
    }

    var hasUsableDigest: Bool {
        !digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One factual assertion a chapter makes, and the evidence it leans on.
struct FactClaim: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var chapterId: UUID
    var statement: String
    var importance: FactClaimImportance
    var status: FactVerificationStatus
    /// Evidence ids that must resolve inside the same checklist.
    var evidenceIds: [String]
    var notes: String?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        chapterId: UUID,
        statement: String,
        importance: FactClaimImportance,
        status: FactVerificationStatus,
        evidenceIds: [String],
        notes: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.chapterId = chapterId
        self.statement = statement
        self.importance = importance
        self.status = status
        self.evidenceIds = evidenceIds
        self.notes = notes
        self.updatedAt = updatedAt
    }
}

/// Per-book claim + evidence ledger consulted before an unread revision goes live.
struct FactChecklist: Codable, Equatable, Hashable, Sendable {
    var bookId: UUID
    var claims: [FactClaim]
    var evidence: [FactEvidenceItem]
    var updatedAt: Date
    var sourcePilot: SourcePilotState? = nil
    var sourceContinuation: SourceContinuationState? = nil
    var sourceContinuationArchive: [SourceContinuationState]? = nil

    static func empty(bookId: UUID, at date: Date = Date()) -> FactChecklist {
        FactChecklist(bookId: bookId, claims: [], evidence: [], updatedAt: date)
    }

    func claims(chapterId: UUID) -> [FactClaim] {
        claims.filter { $0.chapterId == chapterId }
    }

    func evidenceItem(id: String) -> FactEvidenceItem? {
        evidence.first { $0.id == id }
    }

    func essentialClaims(chapterId: UUID) -> [FactClaim] {
        claims(chapterId: chapterId).filter { $0.importance == .essential }
    }
}

extension FactClaim {
    /// Deterministic identity for a model-proposed claim, so re-generating a
    /// chapter upserts its claims instead of stacking duplicates — and so a
    /// human's `verified` status survives the next generation.
    static func stableId(chapterId: UUID, statement: String) -> UUID {
        let key = chapterId.uuidString.lowercased()
            + "|"
            + statement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var high: UInt64 = 0xcbf2_9ce4_8422_2325
        var low: UInt64 = 0x9e37_79b9_7f4a_7c15
        for byte in key.utf8 {
            high = (high ^ UInt64(byte)) &* 0x100_0000_01b3
            low = (low &+ UInt64(byte)) &* 0x100_0000_01b3
        }

        var bytes: [UInt8] = []
        for word in [high, low] {
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        // RFC 4122 name-based shape so these never collide with random UUIDs.
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        func hex(_ range: Range<Int>) -> String {
            bytes[range].map { String(format: "%02x", $0) }.joined()
        }
        let text = "\(hex(0..<4))-\(hex(4..<6))-\(hex(6..<8))-\(hex(8..<10))-\(hex(10..<16))"
        return UUID(uuidString: text) ?? UUID()
    }
}
