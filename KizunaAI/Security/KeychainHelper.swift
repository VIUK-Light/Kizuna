/*
仕様:
- 役割: パスワードやプロダクトキーをKeychainへ保存・取得する最小ユーティリティ。
- 主な型: `KeychainHelper`.
- 編集ポイント: 保存キー、旧サービスからの移行、削除や読込ルールを変えるときに触る。
- セキュリティ方針:
  - シークレットのメモリキャッシュはロックで保護し、バックグラウンド遷移や
    保護データ利用不可能時に速やかに消去する（GHSA-fwp3-xf4f-v466）。
  - 端末ロック後も平文シークレットをメモリに残し続けない。
*/
import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

/// シンプルなKeychainユーティリティ（クライアント完結・実験用途）
final class KeychainHelper {
    static let shared = KeychainHelper()

    /// cachedValues / missingKeys へのアクセスを直列化する。
    /// getString はレガシー移行で setString を呼ぶため、公開メソッドは
    /// ロックを取得せず、ロック内で動く private 実装に委譲する（非再帰ロックでのデッドロック回避）。
    private let cacheLock = NSLock()
    private var cachedValues: [String: String] = [:]
    private var missingKeys: Set<String> = []

    private init() {
        #if canImport(UIKit)
        // 端末ロックで保護データが利用不可能になったらキャッシュを消す。
        // WhenUnlockedThisDeviceOnly の項目もこの時点では読めなくなるため、
        // メモリだけが残存保護となる。通知はメインスレッド以外で来る場合がある。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProtectedDataUnavailable),
            name: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil
        )
        #endif
    }

    @objc private func handleProtectedDataUnavailable() {
        clearInMemoryCaches()
    }

    /// メモリ上のシークレットキャッシュを消去する。
    /// アプリがバックグラウンドへ遷移するタイミング等で呼ぶ。
    func clearInMemoryCaches() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedValues.removeAll()
        missingKeys.removeAll()
    }

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
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return setStringLocked(value, forKey: key)
    }

    func getString(forKey key: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return getStringLocked(forKey: key)
    }

    @discardableResult
    func delete(key: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return deleteLocked(key: key)
    }

    func clearAllBrandValues() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        clearAllBrandValuesLocked()
    }

    // MARK: - Locked implementations

    private func setStringLocked(_ value: String, forKey key: String) -> Bool {
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
            deleteLegacyOnlyLocked(key: key)
            return true
        }

        return false
    }

    private func getStringLocked(forKey key: String) -> String? {
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
                    _ = setStringLocked(string, forKey: key)
                }
                return string
            }
        }
        missingKeys.insert(cacheIdentifier)
        return nil
    }

    private func deleteLocked(key: String) -> Bool {
        let cacheIdentifier = cacheKey(for: key)
        var succeeded = true
        for service in readableServices {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            let legacyStatus = SecItemDelete(legacyQuery as CFDictionary)
            if legacyStatus != errSecSuccess && legacyStatus != errSecItemNotFound {
                succeeded = false
            }

            let dataProtectionQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecUseDataProtectionKeychain as String: true
            ]
            let dataProtectionStatus = SecItemDelete(dataProtectionQuery as CFDictionary)
            if dataProtectionStatus != errSecSuccess && dataProtectionStatus != errSecItemNotFound {
                succeeded = false
            }
        }
        if succeeded {
            cachedValues.removeValue(forKey: cacheIdentifier)
            missingKeys.insert(cacheIdentifier)
        }
        return succeeded
    }

    private func deleteLegacyOnlyLocked(key: String) {
        for service in AppBrand.legacyKeychainServices where service != currentService {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            SecItemDelete(legacyQuery as CFDictionary)
        }
    }

    private func clearAllBrandValuesLocked() {
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
