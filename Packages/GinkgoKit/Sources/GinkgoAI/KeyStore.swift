import Foundation
import Security

/// API keys in the keychain, this device only (never synced to iCloud).
public struct KeyStore: Sendable {
    public let service: String

    public init(service: String = "com.kenjia.ginkgo.ai") {
        self.service = service
    }

    public func key(for provider: AIProviderKind) -> String? {
        var query = base(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Saves the key; an empty string removes it.
    @discardableResult
    public func setKey(_ key: String, for provider: AIProviderKind) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(base(provider) as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var item = base(provider)
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func base(_ provider: AIProviderKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }
}
