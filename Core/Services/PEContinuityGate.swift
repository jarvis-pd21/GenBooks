import Foundation

/// The fact gate that runs immediately before a new *unread* revision becomes
/// active. Three reject paths, checked in a fixed order so a failure always
/// names the earliest problem:
///
///   1. evidence ids a claim cites that do not resolve in the checklist
///      (an essential claim citing nothing at all counts as missing);
///   2. cited evidence whose digest is blank — a stub, not a source;
///   3. essential claims that are not `verified`.
///
/// Every rejection is soft: the caller keeps the prior revision readable and
/// the consumed past untouched.
enum PEContinuityGate {
    static func assertActivationAllowed(
        checklist: FactChecklist,
        bookId: UUID,
        chapterId: UUID
    ) throws {
        guard checklist.bookId == bookId else {
            throw PEGateError.bookMismatch(expected: bookId, found: checklist.bookId)
        }
        let claims = checklist.claims(chapterId: chapterId)
        guard !claims.isEmpty else { return }

        for claim in claims {
            if claim.importance == .essential && claim.evidenceIds.isEmpty {
                throw PEGateError.missingEvidenceIds(claimId: claim.id, evidenceIds: [])
            }
            let unresolved = claim.evidenceIds.filter { checklist.evidenceItem(id: $0) == nil }
            if !unresolved.isEmpty {
                throw PEGateError.missingEvidenceIds(claimId: claim.id, evidenceIds: unresolved)
            }
        }

        for claim in claims {
            for evidenceId in claim.evidenceIds {
                guard let item = checklist.evidenceItem(id: evidenceId) else { continue }
                if !item.hasUsableDigest {
                    throw PEGateError.emptyEvidenceDigest(evidenceId: item.id)
                }
            }
        }

        for claim in claims where claim.importance == .essential {
            if claim.status != .verified {
                throw PEGateError.unverifiedEssentialClaim(claimId: claim.id, status: claim.status)
            }
        }
    }

    /// Runs the gate for every chapter a plan intends to touch.
    static func assertActivationAllowed(
        checklist: FactChecklist,
        bookId: UUID,
        chapterIds: [UUID]
    ) throws {
        for chapterId in chapterIds {
            try assertActivationAllowed(checklist: checklist, bookId: bookId, chapterId: chapterId)
        }
    }

    /// Human-readable readiness lines for the existing Plan → Apply review sheet.
    /// Never throws: the plan sheet must render whatever state the checklist is in.
    static func readinessNotes(checklist: FactChecklist, chapterIds: [UUID]) -> [String] {
        let scoped = chapterIds.isEmpty
            ? checklist.claims
            : checklist.claims.filter { chapterIds.contains($0.chapterId) }
        guard !scoped.isEmpty else {
            return ["No fact claims recorded yet for the planned chapters"]
        }

        let essential = scoped.filter { $0.importance == .essential }
        let verifiedEssential = essential.filter { $0.status == .verified }
        var notes = [
            "Essential claims verified: \(verifiedEssential.count) of \(essential.count)"
        ]

        let uncitedEssential = essential.filter { $0.evidenceIds.isEmpty }
        if !uncitedEssential.isEmpty {
            notes.append("Essential claims missing evidence citations: \(uncitedEssential.count)")
        }
        let citedIds = Set(scoped.flatMap(\.evidenceIds))
        let unresolved = citedIds.filter { checklist.evidenceItem(id: $0) == nil }.sorted()
        if !unresolved.isEmpty {
            notes.append("Unknown evidence ids: \(unresolved.joined(separator: ", "))")
        }
        let stubs = citedIds
            .compactMap { checklist.evidenceItem(id: $0) }
            .filter { !$0.hasUsableDigest }
            .map(\.id)
            .sorted()
        if !stubs.isEmpty {
            notes.append("Evidence still missing a digest: \(stubs.joined(separator: ", "))")
        }
        if uncitedEssential.isEmpty && unresolved.isEmpty && stubs.isEmpty
            && verifiedEssential.count == essential.count {
            notes.append("Fact gate ready — Apply may activate")
        } else {
            notes.append("Fact gate will block Apply until these are resolved")
        }
        return notes
    }
}

/// Folds model-proposed claims and evidence into the stored checklist.
///
/// Model output cannot establish verification. Vetted records remain unchanged;
/// conflicting proposals are separate unverified claims, so the gate can reject
/// them without losing the previously checked claim or its source.
enum FactChecklistMerge {
    static func merge(
        claims: [FactClaim],
        evidence: [FactEvidenceItem],
        into checklist: FactChecklist,
        at date: Date = Date()
    ) -> FactChecklist {
        var next = checklist
        var conflictingEvidenceIds: Set<String> = []
        let vettedEvidenceIds = Set(checklist.claims.filter { $0.status == .verified }.flatMap(\.evidenceIds))

        for incoming in evidence {
            let id = incoming.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            var item = incoming
            item.id = id
            if let index = next.evidence.firstIndex(where: { $0.id == id }) {
                let existing = next.evidence[index]
                if existing.retrievedSource != nil {
                    // Retrieved snapshots are immutable app records; writer echoes cannot replace them.
                    continue
                }
                if vettedEvidenceIds.contains(id) {
                    if item.hasUsableDigest && (item.digest != existing.digest
                        || item.sourceLabel != existing.sourceLabel || item.locator != existing.locator) {
                        conflictingEvidenceIds.insert(id)
                    }
                    // Neither an empty echo nor a replacement source overwrites
                    // the evidence against which a stored claim was checked.
                    continue
                }
                if existing.hasUsableDigest && !item.hasUsableDigest {
                    item.digest = existing.digest
                }
                item.recordedAt = existing.recordedAt
                next.evidence[index] = item
            } else {
                next.evidence.append(item)
                // A model-supplied source cannot make a previously uncited
                // verification valid retroactively.
                if vettedEvidenceIds.contains(id) { conflictingEvidenceIds.insert(id) }
            }
        }

        for existing in checklist.claims where existing.status == .verified
            && !conflictingEvidenceIds.isDisjoint(with: existing.evidenceIds) {
            var conflict = existing
            conflict.id = UUID()
            conflict.status = .unverified
            conflict.updatedAt = date
            next.claims.append(conflict)
        }

        for incoming in claims {
            guard !incoming.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var claim = incoming
            if claim.status == .verified { claim.status = .unverified }
            claim.updatedAt = date
            if let index = next.claims.firstIndex(where: { $0.id == claim.id }) {
                let existing = next.claims[index]
                let sameIdentity = existing.chapterId == claim.chapterId
                    && existing.statement == claim.statement
                    && existing.importance == claim.importance
                    && Set(existing.evidenceIds) == Set(claim.evidenceIds)
                if !sameIdentity {
                    // A reused id cannot transfer verification, move a prior
                    // obligation to another chapter, or lower its importance.
                    claim.id = UUID()
                    if existing.importance == .essential { claim.importance = .essential }
                    next.claims.append(claim)
                } else if existing.status != .verified {
                    if existing.status == .disputed { claim.status = .disputed }
                    next.claims[index] = claim
                }
            } else {
                next.claims.append(claim)
            }
        }

        next.updatedAt = date
        return next
    }
}
