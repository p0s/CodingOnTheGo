public struct HostBootstrapStatus: Hashable, Sendable {
    public var codexInstalled: Bool
    public var stdioAppServerReady: Bool
    public var websocketReuseAvailable: Bool

    public init(
        codexInstalled: Bool,
        stdioAppServerReady: Bool,
        websocketReuseAvailable: Bool
    ) {
        self.codexInstalled = codexInstalled
        self.stdioAppServerReady = stdioAppServerReady
        self.websocketReuseAvailable = websocketReuseAvailable
    }
}
