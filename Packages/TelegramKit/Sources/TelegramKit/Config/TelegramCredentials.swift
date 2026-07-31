import Foundation
import Security

public struct TelegramCredentials: Codable, Sendable, Equatable, Hashable {
    public var apiId: Int
    public var apiHash: String

    public init(apiId: Int, apiHash: String) {
        self.apiId = apiId
        self.apiHash = apiHash
    }

    public var isValid: Bool {
        apiId > 0 && !apiHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum TelegramCredentialStore {
    private static let service = "com.melingo.mac.telegram"
    private static let account = "api-credentials"

    public static func save(_ credentials: TelegramCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TelegramKitError.tdlib("Keychain save failed (\(status))")
        }
    }

    public static func load() -> TelegramCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TelegramCredentials.self, from: data)
    }

    public static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
