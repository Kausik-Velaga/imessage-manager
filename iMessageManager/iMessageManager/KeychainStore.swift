import Foundation
import Security

enum KeychainStore {
    private static let service = "com.kausik.iMessageManager"
    private static let openAIAPIKeyAccount = "openai-api-key"

    static func openAIAPIKey() -> String? {
        var query = baseQuery(account: openAIAPIKeyAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }

        return key
    }

    static func setOpenAIAPIKey(_ key: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedKey.isEmpty {
            try deleteOpenAIAPIKey()
            return
        }

        let data = Data(trimmedKey.utf8)
        var query = baseQuery(account: openAIAPIKeyAccount)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledStatus(addStatus)
        }
    }

    private static func deleteOpenAIAPIKey() throws {
        let status = SecItemDelete(baseQuery(account: openAIAPIKeyAccount) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum KeychainError: Error {
    case unhandledStatus(OSStatus)
}
