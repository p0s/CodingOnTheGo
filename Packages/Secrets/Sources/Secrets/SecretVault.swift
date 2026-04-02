import Foundation
import SharedModels
#if canImport(Security)
import Security
#endif

public struct SecretPayload: Hashable, Sendable {
    public var reference: CredentialRef
    public var value: Data

    public init(reference: CredentialRef, value: Data) {
        self.reference = reference
        self.value = value
    }
}

public struct SecretVaultConfiguration: Hashable, Sendable {
    public var serviceName: String
    public var accessGroup: String?

    public init(
        serviceName: String = "com.example.codingonthego.shared",
        accessGroup: String? = nil
    ) {
        self.serviceName = serviceName
        self.accessGroup = accessGroup
    }
}

public protocol SecretVault: Sendable {
    func store(_ payload: SecretPayload) async throws
    func load(reference: CredentialRef) async throws -> SecretPayload?
    func remove(reference: CredentialRef) async throws
    func findReferences(accountPrefix: String, username: String?) async throws -> [SecretReferenceMatch]
}

public struct SecretReferenceMatch: Hashable, Sendable {
    public var keychainAccount: String
    public var username: String
    public var storageScope: SecretStorageScope

    public init(
        keychainAccount: String,
        username: String,
        storageScope: SecretStorageScope
    ) {
        self.keychainAccount = keychainAccount
        self.username = username
        self.storageScope = storageScope
    }
}

public enum SecretVaultError: LocalizedError {
    case unsupportedPlatform
    case keychainFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "This platform does not provide the Apple Keychain APIs."
        case let .keychainFailure(status):
            "Keychain operation failed with status \(status)."
        }
    }
}

public actor InMemorySecretVault: SecretVault {
    private var storage: [String: SecretPayload] = [:]

    public init() {}

    public func store(_ payload: SecretPayload) async throws {
        storage[storageKey(for: payload.reference)] = payload
    }

    public func load(reference: CredentialRef) async throws -> SecretPayload? {
        storage[storageKey(for: reference)]
    }

    public func remove(reference: CredentialRef) async throws {
        storage[storageKey(for: reference)] = nil
    }

    public func findReferences(accountPrefix: String, username: String?) async throws -> [SecretReferenceMatch] {
        let normalizedUsername = username?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return storage.values
            .map(\.reference)
            .filter { reference in
                guard reference.keychainAccount.hasPrefix(accountPrefix) else {
                    return false
                }
                guard let normalizedUsername else {
                    return true
                }
                return reference.username
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == normalizedUsername
            }
            .map {
                SecretReferenceMatch(
                    keychainAccount: $0.keychainAccount,
                    username: $0.username,
                    storageScope: $0.storageScope
                )
            }
            .sorted { $0.keychainAccount < $1.keychainAccount }
    }

    private func storageKey(for reference: CredentialRef) -> String {
        "\(reference.storageScope.rawValue)|\(reference.keychainAccount)"
    }
}

public struct SecretVaultPlan: Hashable, Sendable {
    public var reference: CredentialRef
    public var isSynchronizable: Bool
    public var isThisDeviceOnly: Bool

    public init(reference: CredentialRef) {
        self.reference = reference
        self.isSynchronizable = reference.storageScope == .synchronizableKeychain
        self.isThisDeviceOnly = reference.storageScope == .thisDeviceOnlyKeychain
    }
}

public actor SystemKeychainSecretVault: SecretVault {
    private let configuration: SecretVaultConfiguration

    public init(configuration: SecretVaultConfiguration = .init()) {
        self.configuration = configuration
    }

    public init(service: String) {
        self.init(configuration: SecretVaultConfiguration(serviceName: service))
    }

    public func store(_ payload: SecretPayload) async throws {
        #if canImport(Security)
        let query = keychainQuery(for: payload.reference, includeData: false)
        let attributes = payloadAttributes(for: payload)
        let addStatus = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SecretVaultError.keychainFailure(updateStatus)
            }
            return
        }

        guard addStatus == errSecSuccess else {
            throw SecretVaultError.keychainFailure(addStatus)
        }
        #else
        throw SecretVaultError.unsupportedPlatform
        #endif
    }

    public func load(reference: CredentialRef) async throws -> SecretPayload? {
        #if canImport(Security)
        var query = keychainQuery(for: reference, includeData: true)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecretVaultError.keychainFailure(status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return SecretPayload(reference: reference, value: data)
        #else
        throw SecretVaultError.unsupportedPlatform
        #endif
    }

    public func remove(reference: CredentialRef) async throws {
        #if canImport(Security)
        let status = SecItemDelete(keychainQuery(for: reference, includeData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretVaultError.keychainFailure(status)
        }
        #else
        throw SecretVaultError.unsupportedPlatform
        #endif
    }

    public func findReferences(accountPrefix: String, username: String?) async throws -> [SecretReferenceMatch] {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.serviceName,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess else {
            throw SecretVaultError.keychainFailure(status)
        }

        let normalizedUsername = username?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let attributesList: [[String: Any]]
        if let list = item as? [[String: Any]] {
            attributesList = list
        } else if let single = item as? [String: Any] {
            attributesList = [single]
        } else {
            attributesList = []
        }

        return attributesList
            .compactMap { attributes in
                guard let account = attributes[kSecAttrAccount as String] as? String,
                      account.hasPrefix(accountPrefix) else {
                    return nil
                }

                let storedUsername = (attributes[kSecAttrDescription as String] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let normalizedUsername,
                   storedUsername.lowercased() != normalizedUsername {
                    return nil
                }

                let isSynchronizable: Bool = {
                    if let number = attributes[kSecAttrSynchronizable as String] as? NSNumber {
                        return number.boolValue
                    }
                    if let value = attributes[kSecAttrSynchronizable as String] as? Bool {
                        return value
                    }
                    return false
                }()

                return SecretReferenceMatch(
                    keychainAccount: account,
                    username: storedUsername,
                    storageScope: {
                        if isSynchronizable {
                            return .synchronizableKeychain
                        }

                        let accessible = attributes[kSecAttrAccessible as String] as? String
                        if accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) {
                            return .thisDeviceOnlyKeychain
                        }

                        return .localKeychain
                    }()
                )
            }
            .sorted { $0.keychainAccount < $1.keychainAccount }
        #else
        throw SecretVaultError.unsupportedPlatform
        #endif
    }

    #if canImport(Security)
    private func payloadAttributes(for payload: SecretPayload) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecValueData as String: payload.value,
            kSecAttrLabel as String: payload.reference.label,
            kSecAttrDescription as String: payload.reference.username
        ]

        switch payload.reference.storageScope {
        case .synchronizableKeychain:
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
        case .localKeychain:
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        case .thisDeviceOnlyKeychain:
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        return attributes
    }

    private func keychainQuery(for reference: CredentialRef, includeData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.serviceName,
            kSecAttrAccount as String: reference.keychainAccount
        ]

        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        switch reference.storageScope {
        case .synchronizableKeychain:
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        case .localKeychain:
            break
        case .thisDeviceOnlyKeychain:
            break
        }

        if includeData {
            query[kSecReturnData as String] = kCFBooleanTrue
        }

        return query
    }
    #endif
}
