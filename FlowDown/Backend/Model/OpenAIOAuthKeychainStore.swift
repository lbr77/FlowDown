//
//  OpenAIOAuthKeychainStore.swift
//  FlowDown
//
//  Created by LiBr on 2026/4/19.
//

import Foundation
import Security

struct OpenAIOAuthKeychainStore {
    let service: String

    func load(account: String) throws -> Data? {
        let query = baseQuery(account: account)
            .merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw NSError(
                domain: "OpenAIOAuthKeychainStore",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain read failed with status \(status)."],
            )
        }
    }

    func save(_ data: Data, account: String) throws {
        try delete(account: account)

        var query = baseQuery(account: account)
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "OpenAIOAuthKeychainStore",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain write failed with status \(status)."],
            )
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(
                domain: "OpenAIOAuthKeychainStore",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain delete failed with status \(status)."],
            )
        }
    }
}

private extension OpenAIOAuthKeychainStore {
    func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
    }
}
