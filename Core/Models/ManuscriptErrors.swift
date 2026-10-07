import Foundation

enum ManuscriptError: Error, Equatable, LocalizedError {
    case bookNotFound(UUID)
    case chapterNotFound(UUID)
    case revisionNotFound(UUID)
    case chapterAlreadyConsumed(chapterId: UUID, lockedRevisionId: UUID)
    case cannotMutateConsumedChapter(UUID)
    case malformedCandidate(String)
    case candidateNotFound(UUID)
    case candidateAlreadyHandled(UUID)
    case staleRevision(expected: UUID, actual: UUID)
    case emptyBlocks
    case atomicActivationFailed(String)

    var errorDescription: String? {
        switch self {
        case .bookNotFound(let id): return "Book not found: \(id)"
        case .chapterNotFound(let id): return "Chapter not found: \(id)"
        case .revisionNotFound(let id): return "Revision not found: \(id)"
        case .chapterAlreadyConsumed(let chapterId, let locked):
            return "Chapter \(chapterId) already consumed as revision \(locked)"
        case .cannotMutateConsumedChapter(let id):
            return "Cannot mutate consumed chapter \(id)"
        case .malformedCandidate(let reason): return "Malformed candidate: \(reason)"
        case .candidateNotFound(let id): return "Candidate not found: \(id)"
        case .candidateAlreadyHandled(let id): return "Candidate already handled: \(id)"
        case .staleRevision:
            return "This chapter changed while generating. Its newer version was kept. Preview again to continue."
        case .emptyBlocks: return "Revision requires at least one content block"
        case .atomicActivationFailed(let reason): return "Atomic activation failed: \(reason)"
        }
    }
}
