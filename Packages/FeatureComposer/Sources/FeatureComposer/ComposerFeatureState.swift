import Foundation

public enum ComposerAttachmentKind: String, Codable, Sendable {
    case photo
    case voiceMemo
}

public struct ComposerAttachment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: ComposerAttachmentKind
    public var displayName: String
    public var suggestedFilename: String?
    public var payload: Data?

    public init(
        id: UUID = UUID(),
        kind: ComposerAttachmentKind,
        displayName: String,
        suggestedFilename: String? = nil,
        payload: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.suggestedFilename = suggestedFilename
        self.payload = payload
    }
}

public enum VoiceInputAvailability: String, Codable, Sendable {
    case available
    case permissionRequired
    case unavailable
}

public struct ComposerFeatureState: Hashable, Codable, Sendable {
    public var draft: String
    public var attachments: [ComposerAttachment]
    public var canAttachPhotos: Bool
    public var voiceInputAvailability: VoiceInputAvailability

    public init(
        draft: String = "",
        attachments: [ComposerAttachment] = [],
        canAttachPhotos: Bool = true,
        voiceInputAvailability: VoiceInputAvailability = .available
    ) {
        self.draft = draft
        self.attachments = attachments
        self.canAttachPhotos = canAttachPhotos
        self.voiceInputAvailability = voiceInputAvailability
    }

    public var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
}
