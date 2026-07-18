/*
仕様:
- 役割: パスワードやプロダクトキーをKeychainへ保存・取得する最小ユーティリティ。
- 主な型: `KeychainHelper`.
- 編集ポイント: 保存キー、旧サービスからの移行、削除や読込ルールを変えるときに触る。
*/
import Foundation
import Security

/// シンプルなKeychainユーティリティ（クライアント完結・実験用途）
final class KeychainHelper {
    static let shared = KeychainHelper()
    private var cachedValues: [String: String] = [:]
    private var missingKeys: Set<String> = []
    private init() {}

    private var currentService: String { AppBrand.keychainService }
    private var readableServices: [String] { [AppBrand.keychainService] + AppBrand.legacyKeychainServices }

    private func cacheKey(for key: String) -> String {
        "\(currentService)::\(key)"
    }

    private func dataProtectionReadQuery(service: String, key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func legacyReadQuery(service: String, key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
    }

    @discardableResult
    func setString(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let cacheIdentifier = cacheKey(for: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: currentService,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status == errSecSuccess {
            cachedValues[cacheIdentifier] = value
            missingKeys.remove(cacheIdentifier)
            deleteLegacyOnly(key: key)
            return true
        }

        return false
    }

    func getString(forKey key: String) -> String? {
        let cacheIdentifier = cacheKey(for: key)
        if let cached = cachedValues[cacheIdentifier] {
            return cached
        }
        if missingKeys.contains(cacheIdentifier) {
            return nil
        }

        let queryOrder: [(service: String, query: [String: Any], migrate: Bool)] =
            [(currentService, dataProtectionReadQuery(service: currentService, key: key), false)] +
            readableServices.map { ($0, legacyReadQuery(service: $0, key: key), true) }

        for entry in queryOrder {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(entry.query as CFDictionary, &item)
            if status == errSecSuccess,
               let data = item as? Data,
               let string = String(data: data, encoding: .utf8) {
                cachedValues[cacheIdentifier] = string
                missingKeys.remove(cacheIdentifier)
                if entry.migrate {
                    setString(string, forKey: key)
                }
                return string
            }
        }
        missingKeys.insert(cacheIdentifier)
        return nil
    }

    func delete(key: String) {
        let cacheIdentifier = cacheKey(for: key)
        for service in readableServices {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            SecItemDelete(legacyQuery as CFDictionary)

            let dataProtectionQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecUseDataProtectionKeychain as String: true
            ]
            SecItemDelete(dataProtectionQuery as CFDictionary)
        }
        cachedValues.removeValue(forKey: cacheIdentifier)
        missingKeys.insert(cacheIdentifier)
    }

    private func deleteLegacyOnly(key: String) {
        for service in AppBrand.legacyKeychainServices where service != currentService {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            SecItemDelete(legacyQuery as CFDictionary)
        }
    }

    func clearAllBrandValues() {
        for service in readableServices {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            SecItemDelete(legacyQuery as CFDictionary)

            let dataProtectionQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true
            ]
            SecItemDelete(dataProtectionQuery as CFDictionary)
        }
        cachedValues.removeAll()
        missingKeys.removeAll()
    }
}
