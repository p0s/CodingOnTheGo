import XCTest
@testable import Secrets
import SharedModels

final class SecretsTests: XCTestCase {
    func testInMemoryVaultStoresAndRemovesSecret() async throws {
        let reference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "generated-ssh-key",
            label: "Generated SSH key",
            username: "developer",
            storageScope: .thisDeviceOnlyKeychain
        )
        let vault = InMemorySecretVault()
        let payload = SecretPayload(
            reference: reference,
            value: Data("secret".utf8)
        )

        try await vault.store(payload)
        let restored = try await vault.load(reference: reference)
        XCTAssertEqual(restored?.value, Data("secret".utf8))

        try await vault.remove(reference: reference)
        let deleted = try await vault.load(reference: reference)
        XCTAssertNil(deleted)
    }

    func testSystemKeychainVaultStoresAndRemovesSecret() async throws {
        guard ProcessInfo.processInfo.environment["COTG_ENABLE_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Set COTG_ENABLE_KEYCHAIN_TESTS=1 to run real keychain integration tests.")
        }

        let reference = CredentialRef(
            kind: .sshKey,
            keychainAccount: "safe-lane-testing-key",
            label: "Safe lane testing key",
            username: "developer",
            storageScope: .thisDeviceOnlyKeychain
        )
        let vault = SystemKeychainSecretVault(service: "com.example.codingonthego.tests")
        let payload = SecretPayload(
            reference: reference,
            value: Data("ssh-secret".utf8)
        )

        try await vault.store(payload)
        let restored = try await vault.load(reference: reference)
        XCTAssertEqual(restored?.value, Data("ssh-secret".utf8))

        try await vault.remove(reference: reference)
        let deleted = try await vault.load(reference: reference)
        XCTAssertNil(deleted)
    }

    func testSecretVaultPlanReflectsStorageScope() {
        let synchronizableReference = CredentialRef(
            kind: .token,
            keychainAccount: "synced-profile-token",
            label: "Synced profile token",
            username: "developer",
            storageScope: .synchronizableKeychain
        )
        let plan = SecretVaultPlan(reference: synchronizableReference)
        XCTAssertTrue(plan.isSynchronizable)
        XCTAssertFalse(plan.isThisDeviceOnly)
    }
}
