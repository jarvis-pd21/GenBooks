import Foundation

/// Permission to send reading data to OpenAI is independent of storing an API key.
/// A changed disclosure version requires a new opt-in. No existing key migrates consent.
final class AISharingConsentStore: @unchecked Sendable {
    typealias PermissionProvider = @Sendable () -> Bool

    static let shared = AISharingConsentStore()
    static let currentDisclosureVersion = 1
    static let defaultsKey = "livingreader.privacy.openAISharingDisclosureVersion"
    static let permissionRequiredMessage = "OpenAI sharing is off. Review and allow it in Settings → BookBot to use this feature. Reading and saved audio still work."
    static let disclosure = """
    When you use BookBot, AI definitions, book creation or adaptation, GenBooks sends the relevant prompts, selected passages or chapter text, book titles, notes, reading preferences, feedback and research sources to OpenAI. New AI narration sends the text to be spoken and your voice choice. Your API key authenticates these requests directly with OpenAI.
    """

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isAllowed: Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults.integer(forKey: Self.defaultsKey) == Self.currentDisclosureVersion
    }

    func allowCurrentDisclosure() {
        lock.lock(); defer { lock.unlock() }
        defaults.set(Self.currentDisclosureVersion, forKey: Self.defaultsKey)
    }

    func revoke() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// Called at the network boundary, including retries, rather than at client construction.
    static func requirePermission(using provider: PermissionProvider) throws {
        guard provider() else { throw AIServiceError.underlying(permissionRequiredMessage) }
    }
}
