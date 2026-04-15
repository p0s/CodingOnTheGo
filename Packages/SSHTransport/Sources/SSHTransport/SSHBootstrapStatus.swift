public struct SSHBootstrapStatus: Hashable, Sendable {
    public var remoteLoginEnabled: Bool
    public var credentialsConfigured: Bool
    public var hostKeyVerified: Bool

    public init(
        remoteLoginEnabled: Bool,
        credentialsConfigured: Bool,
        hostKeyVerified: Bool
    ) {
        self.remoteLoginEnabled = remoteLoginEnabled
        self.credentialsConfigured = credentialsConfigured
        self.hostKeyVerified = hostKeyVerified
    }

    public var readyForBootstrap: Bool {
        remoteLoginEnabled && credentialsConfigured && hostKeyVerified
    }
}

public enum SSHCredentialKind: String, CaseIterable, Sendable {
    case generatedKey
    case importedKey
    case password
}

public enum SSHTrustState: String, CaseIterable, Sendable {
    case unknown
    case trusted
    case mismatch
}

public struct SSHCredentialDescriptor: Hashable, Sendable {
    public var username: String
    public var kind: SSHCredentialKind
    public var isEncryptedAtRest: Bool

    public init(
        username: String,
        kind: SSHCredentialKind,
        isEncryptedAtRest: Bool
    ) {
        self.username = username
        self.kind = kind
        self.isEncryptedAtRest = isEncryptedAtRest
    }
}

public struct SSHConnectionSnapshot: Hashable, Sendable {
    public var bootstrap: SSHBootstrapStatus
    public var trustState: SSHTrustState
    public var credential: SSHCredentialDescriptor?

    public init(
        bootstrap: SSHBootstrapStatus,
        trustState: SSHTrustState,
        credential: SSHCredentialDescriptor?
    ) {
        self.bootstrap = bootstrap
        self.trustState = trustState
        self.credential = credential
    }

    public var failureReason: String? {
        if trustState == .mismatch {
            return "The SSH host key changed and must be re-trusted before continuing."
        }
        if !bootstrap.remoteLoginEnabled {
            return "Remote Login is disabled on the host."
        }
        if credential == nil || !bootstrap.credentialsConfigured {
            return "No valid SSH credential is configured."
        }
        if !bootstrap.hostKeyVerified {
            return "The host key has not been verified yet."
        }
        return nil
    }
}
