import Foundation
import XCTest
@testable import Persistence
import SharedModels

final class PersistenceTests: XCTestCase {
    func testRoundTripsMachineSnapshotToJSON() async throws {
        let store = JSONMetadataStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        try await store.save(.preview, to: url)
        let restored = try await store.load(from: url)

        XCTAssertEqual(restored.machines.count, 2)
        XCTAssertEqual(restored.preferences.preferredMachineID, MachineDirectorySnapshot.preview.preferences.preferredMachineID)
    }

    func testMergeAndSavePreservesHostThreadCatalogEntries() async throws {
        let store = JSONMetadataStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }

        let machine = try XCTUnwrap(MachineDirectorySnapshot.preview.machines.first)
        let existingEntry = HostThreadCatalogEntry(
            id: "thread-existing",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Existing thread",
            preview: "Existing preview",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let incomingEntry = HostThreadCatalogEntry(
            id: "thread-incoming",
            machineID: machine.id,
            workspaceRoot: "/workspace/reference-app",
            name: "Incoming thread",
            preview: "Incoming preview",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 400)
        )

        let existingSnapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [existingEntry],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )
        let incomingSnapshot = MachineDirectorySnapshot(
            machines: [machine],
            tailnetProfiles: [],
            recentSessions: [],
            hostThreadCatalog: [incomingEntry],
            preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
        )

        try await store.save(existingSnapshot, to: url)
        let merged = try await store.mergeAndSave(incomingSnapshot, to: url)

        XCTAssertEqual(merged.hostThreadCatalog.map(\.id), ["thread-incoming", "thread-existing"])

        let restored = try await store.load(from: url)
        XCTAssertEqual(restored.hostThreadCatalog.map(\.id), ["thread-incoming", "thread-existing"])
    }

    func testMergeAndSavePreservesCatalogTitleWhenNewerEntryDropsIt() async throws {
        let store = JSONMetadataStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }

        let machine = try XCTUnwrap(MachineDirectorySnapshot.preview.machines.first)
        let existingEntry = HostThreadCatalogEntry(
            id: "thread-existing",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: "Finish remote Codex client",
            preview: "You are working in the Coding On The Go repo.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let incomingEntry = HostThreadCatalogEntry(
            id: "thread-existing",
            machineID: machine.id,
            workspaceRoot: "/workspace/coding-on-the-go",
            name: nil,
            preview: "You are working in the Coding On The Go repo.",
            modelProvider: "openai",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 400)
        )

        try await store.save(
            MachineDirectorySnapshot(
                machines: [machine],
                tailnetProfiles: [],
                recentSessions: [],
                hostThreadCatalog: [existingEntry],
                preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
            ),
            to: url
        )

        let merged = try await store.mergeAndSave(
            MachineDirectorySnapshot(
                machines: [machine],
                tailnetProfiles: [],
                recentSessions: [],
                hostThreadCatalog: [incomingEntry],
                preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
            ),
            to: url
        )

        let mergedEntry = try XCTUnwrap(merged.hostThreadCatalog.first)
        XCTAssertEqual(mergedEntry.name, "Finish remote Codex client")
        XCTAssertEqual(mergedEntry.preview, "You are working in the Coding On The Go repo.")
        XCTAssertEqual(mergedEntry.updatedAt, incomingEntry.updatedAt)
    }

    func testMergeAndSaveKeepsDistinctSessionIDsInSameScene() async throws {
        let store = JSONMetadataStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }

        let machine = try XCTUnwrap(MachineDirectorySnapshot.preview.machines.first)
        let sceneID = "scene-a"
        let existingSession = SessionRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sceneID: sceneID,
            machineID: machine.id,
            threadID: "thread-existing",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        let incomingSession = SessionRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            sceneID: sceneID,
            machineID: machine.id,
            threadID: "thread-incoming",
            workspaceRoot: "/workspace/coding-on-the-go-worktrees/feature",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: Date(timeIntervalSince1970: 200),
            parentThreadID: "thread-existing"
        )

        try await store.save(
            MachineDirectorySnapshot(
                machines: [machine],
                tailnetProfiles: [],
                recentSessions: [existingSession],
                hostThreadCatalog: [],
                preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
            ),
            to: url
        )

        let merged = try await store.mergeAndSave(
            MachineDirectorySnapshot(
                machines: [machine],
                tailnetProfiles: [],
                recentSessions: [incomingSession],
                hostThreadCatalog: [],
                preferences: UserPreferencesSnapshot(preferredMachineID: machine.id)
            ),
            to: url
        )

        XCTAssertEqual(merged.recentSessions.count, 2)
        XCTAssertTrue(merged.recentSessions.contains(where: { $0.id == existingSession.id }))
        XCTAssertTrue(
            merged.recentSessions.contains(where: {
                $0.id == incomingSession.id
                    && $0.parentThreadID == "thread-existing"
            })
        )
    }
}
