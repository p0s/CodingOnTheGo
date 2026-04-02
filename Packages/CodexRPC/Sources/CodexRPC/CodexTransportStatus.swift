public enum CodexTransportKind: String, CaseIterable, Sendable {
    case stdio
    case websocket
}

public struct CodexTransportStatus: Hashable, Sendable {
    public var stdioAvailable: Bool
    public var websocketAvailable: Bool

    public init(
        stdioAvailable: Bool,
        websocketAvailable: Bool
    ) {
        self.stdioAvailable = stdioAvailable
        self.websocketAvailable = websocketAvailable
    }
}
