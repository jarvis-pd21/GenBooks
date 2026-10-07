import Foundation
import Security

/// Stores the OpenAI API key. Production uses Keychain only — never UserDefaults / plist / source.
protocol APIKeyStoring: Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ key: String?) throws
}

enum APIKeyStoreError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error (\(status))"
        case .encodingFailed:
            return "Could not encode API key"
        }
    }
}

/// In-memory store for unit tests (no Keychain side effects).
final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    init(key: String? = nil) {
        self.key = key
    }

    func loadAPIKey() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    func saveAPIKey(_ key: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.key = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

/// Keychain-backed API key store. Values are never written to UserDefaults.
final class KeychainAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    static let shared = KeychainAPIKeyStore()

    private let service: String
    private let account: String
    private let lock = NSLock()

    init(
        service: String = "com.jarvis.livingreader.openai",
        account: String = "apiKey"
    ) {
        self.service = service
        self.account = account
    }

    func loadAPIKey() throws -> String? {
        #if DEBUG
        // Also isolate audio and other clients that bypass AIServiceResolver.
        if SourceContinuationTrial.requested() { return nil }
        #endif
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw APIKeyStoreError.unexpectedStatus(status)
        }
    }

    func saveAPIKey(_ key: String?) throws {
        #if DEBUG
        if SourceContinuationTrial.requested() {
            throw SourceGroundingError.invalid("The isolated continuation trial does not read or change stored API keys.")
        }
        #endif
        lock.lock()
        defer { lock.unlock() }

        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == nil || trimmed?.isEmpty == true {
            try deleteUnlocked()
            return
        }
        guard let data = trimmed!.data(using: .utf8) else {
            throw APIKeyStoreError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw APIKeyStoreError.unexpectedStatus(addStatus)
            }
            return
        }
        throw APIKeyStoreError.unexpectedStatus(updateStatus)
    }

    private func deleteUnlocked() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.unexpectedStatus(status)
        }
    }
}
