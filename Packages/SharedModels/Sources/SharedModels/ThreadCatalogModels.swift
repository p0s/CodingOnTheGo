import Foundation

public enum HostThreadCatalogProvenance: String, Hashable, Codable, Sendable {
    case liveAppServer
    case cachedHostCatalog
    case sqliteRepaired
}

public struct HostThreadCatalogEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var machineID: MachineRecord.ID
    public var workspaceRoot: String
    public var name: String?
    public var preview: String
    public var modelProvider: String
    public var createdAt: Date
    public var updatedAt: Date
    public var observedAt: Date
    public var provenance: HostThreadCatalogProvenance

    enum CodingKeys: String, CodingKey {
        case id
        case machineID
        case workspaceRoot
        case name
        case preview
        case modelProvider
        case createdAt
        case updatedAt
        case observedAt
        case provenance
    }

    public init(
        id: String,
        machineID: MachineRecord.ID,
        workspaceRoot: String,
        name: String? = nil,
        preview: String,
        modelProvider: String,
        createdAt: Date,
        updatedAt: Date,
        observedAt: Date? = nil,
        provenance: HostThreadCatalogProvenance = .cachedHostCatalog
    ) {
        self.id = id
        self.machineID = machineID
        self.workspaceRoot = workspaceRoot
        self.name = name
        self.preview = preview
        self.modelProvider = modelProvider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.observedAt = observedAt ?? updatedAt
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let machineID = try container.decode(MachineRecord.ID.self, forKey: .machineID)
        let workspaceRoot = try container.decode(String.self, forKey: .workspaceRoot)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let preview = try container.decode(String.self, forKey: .preview)
        let modelProvider = try container.decode(String.self, forKey: .modelProvider)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt) ?? updatedAt
        let provenance = try container.decodeIfPresent(HostThreadCatalogProvenance.self, forKey: .provenance) ?? .cachedHostCatalog

        self.init(
            id: id,
            machineID: machineID,
            workspaceRoot: workspaceRoot,
            name: name,
            preview: preview,
            modelProvider: modelProvider,
            createdAt: createdAt,
            updatedAt: updatedAt,
            observedAt: observedAt,
            provenance: provenance
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(machineID, forKey: .machineID)
        try container.encode(workspaceRoot, forKey: .workspaceRoot)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(preview, forKey: .preview)
        try container.encode(modelProvider, forKey: .modelProvider)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(provenance, forKey: .provenance)
    }

    public func merged(with other: HostThreadCatalogEntry) -> HostThreadCatalogEntry {
        let primary: HostThreadCatalogEntry
        let secondary: HostThreadCatalogEntry
        if observedAt > other.observedAt {
            primary = self
            secondary = other
        } else if observedAt < other.observedAt {
            primary = other
            secondary = self
        } else if updatedAt >= other.updatedAt {
            primary = self
            secondary = other
        } else {
            primary = other
            secondary = self
        }

        let mergedName = Self.preferredName(primary: primary, secondary: secondary)
        let mergedPreview = Self.preferredPreview(
            primary: primary.preview,
            secondary: secondary.preview,
            chosenName: mergedName
        )

        return HostThreadCatalogEntry(
            id: primary.id,
            machineID: primary.machineID,
            workspaceRoot: Self.preferredText(primary.workspaceRoot, fallback: secondary.workspaceRoot)
                ?? primary.workspaceRoot,
            name: mergedName,
            preview: mergedPreview,
            modelProvider: Self.preferredText(primary.modelProvider, fallback: secondary.modelProvider)
                ?? primary.modelProvider,
            createdAt: min(createdAt, other.createdAt),
            updatedAt: max(updatedAt, other.updatedAt),
            observedAt: max(observedAt, other.observedAt),
            provenance: Self.preferredProvenance(primary: primary, secondary: secondary)
        )
    }

    public func asCachedCatalog() -> HostThreadCatalogEntry {
        var cached = self
        cached.provenance = .cachedHostCatalog
        return cached
    }

    private static func preferredName(
        primary: HostThreadCatalogEntry,
        secondary: HostThreadCatalogEntry
    ) -> String? {
        let primaryName = normalizedText(primary.name)
        let secondaryName = normalizedText(secondary.name)
        let primaryPreview = normalizedText(primary.preview)
        let secondaryPreview = normalizedText(secondary.preview)

        if let primaryName,
           !sameText(primaryName, primaryPreview) {
            return primaryName
        }

        if let secondaryName,
           !sameText(secondaryName, secondaryPreview) {
            return secondaryName
        }

        return primaryName ?? secondaryName
    }

    private static func preferredPreview(
        primary: String,
        secondary: String,
        chosenName: String?
    ) -> String {
        let primaryPreview = normalizedText(primary)
        let secondaryPreview = normalizedText(secondary)

        if let primaryPreview,
           !sameText(primaryPreview, chosenName) {
            return primaryPreview
        }

        if let secondaryPreview,
           !sameText(secondaryPreview, chosenName) {
            return secondaryPreview
        }

        return primaryPreview ?? secondaryPreview ?? ""
    }

    private static func preferredText(_ primary: String?, fallback secondary: String?) -> String? {
        normalizedText(primary) ?? normalizedText(secondary)
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func sameText(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalizedText(lhs),
              let rhs = normalizedText(rhs) else {
            return false
        }
        return lhs == rhs
    }

    private static func preferredProvenance(
        primary: HostThreadCatalogEntry,
        secondary: HostThreadCatalogEntry
    ) -> HostThreadCatalogProvenance {
        if primary.observedAt != secondary.observedAt {
            return primary.provenance
        }

        if primary.provenance == .sqliteRepaired || secondary.provenance == .sqliteRepaired {
            return .sqliteRepaired
        }
        if primary.provenance == .liveAppServer || secondary.provenance == .liveAppServer {
            return .liveAppServer
        }
        return .cachedHostCatalog
    }
}
