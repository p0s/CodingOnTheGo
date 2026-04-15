import XCTest
@testable import AppState
import CodexRPC
import SharedModels

final class CodexExecutionProfileCoordinatorTests: XCTestCase {
    func testUpdateProfileStatePrefersExplicitRequestedOverrideOverBaselineFallback() {
        let updated = CodexExecutionProfileCoordinator.updateProfileState(
            existing: nil,
            runtime: nil,
            baseline: CodexExecutionBaselineConfigSnapshot(
                approvalPolicy: "on-request",
                sandboxMode: "workspace-write"
            ),
            constraints: nil,
            support: CodexExecutionSupportSnapshot(threadResumeOverrides: .supported),
            effectiveProfile: CodexExecutionProfile(
                approvalPolicy: CodexExecutionAuthority(
                    effective: "on-request",
                    status: .effective
                ),
                sandboxMode: CodexExecutionAuthority(
                    effective: "workspace-write",
                    status: .effective
                )
            ),
            requestedOverride: CodexRequestedExecutionOverride(
                approvalPolicy: "never",
                sandboxMode: "danger-full-access"
            )
        )

        XCTAssertEqual(updated.profile.approvalPolicy.requested, "never")
        XCTAssertEqual(updated.profile.sandboxMode.requested, "danger-full-access")
        XCTAssertEqual(updated.profile.approvalPolicy.effective, "on-request")
        XCTAssertEqual(updated.profile.sandboxMode.effective, "workspace-write")
        XCTAssertEqual(updated.profile.approvalPolicy.status, .constrained)
        XCTAssertEqual(updated.profile.sandboxMode.status, .constrained)
    }

    func testUpdateProfileStateMarksRequestedWhenRuntimeCannotYetProveEffectiveValue() {
        let updated = CodexExecutionProfileCoordinator.updateProfileState(
            existing: nil,
            runtime: nil,
            baseline: nil,
            constraints: nil,
            support: CodexExecutionSupportSnapshot(threadResumeOverrides: .supported),
            effectiveProfile: nil,
            requestedOverride: CodexRequestedExecutionOverride(
                approvalPolicy: "never",
                sandboxMode: "danger-full-access"
            )
        )

        XCTAssertEqual(updated.profile.approvalPolicy.requested, "never")
        XCTAssertEqual(updated.profile.sandboxMode.requested, "danger-full-access")
        XCTAssertEqual(updated.profile.approvalPolicy.status, .requested)
        XCTAssertEqual(updated.profile.sandboxMode.status, .requested)
    }

    func testUpdateProfileStateUsesExplicitRequestedOverrideSupportInsteadOfResumeFallback() {
        let updated = CodexExecutionProfileCoordinator.updateProfileState(
            existing: nil,
            runtime: nil,
            baseline: nil,
            constraints: nil,
            support: CodexExecutionSupportSnapshot(
                threadStartOverrides: .supported,
                threadResumeOverrides: .unsupported
            ),
            effectiveProfile: nil,
            requestedOverride: CodexRequestedExecutionOverride(
                approvalPolicy: "never",
                sandboxMode: "danger-full-access"
            ),
            requestedOverrideSupport: .supported
        )

        XCTAssertEqual(updated.profile.approvalPolicy.status, .requested)
        XCTAssertEqual(updated.profile.sandboxMode.status, .requested)
    }

    func testMarkResumeOverrideUnsupportedPreservesEffectiveProfileAndMarksUnsupported() {
        let existing = CodexExecutionProfileState(
            support: CodexExecutionSupportSnapshot(threadResumeOverrides: .supported),
            profile: CodexExecutionProfile(
                approvalPolicy: CodexExecutionAuthority(
                    requested: "on-request",
                    effective: "never",
                    status: .constrained
                ),
                sandboxMode: CodexExecutionAuthority(
                    requested: "workspace-write",
                    effective: "read-only",
                    status: .constrained
                )
            )
        )

        let updated = CodexExecutionProfileCoordinator.markResumeOverrideUnsupported(
            existing: existing,
            effectiveProfile: existing.profile
        )

        XCTAssertEqual(updated.support.threadResumeOverrides, .unsupported)
        XCTAssertEqual(updated.profile.approvalPolicy.status, .unsupported)
        XCTAssertEqual(updated.profile.sandboxMode.status, .unsupported)
        XCTAssertEqual(updated.profile.approvalPolicy.effective, "never")
        XCTAssertEqual(updated.profile.sandboxMode.effective, "read-only")
    }

    func testMergeSessionPermissionGrantWidensEffectiveRootsAndNetwork() {
        let existing = CodexExecutionProfileState(
            profile: CodexExecutionProfile(
                writableRoots: CodexExecutionAuthority(
                    effective: ["/tmp/existing-write"],
                    status: .effective
                ),
                extraReadableRoots: CodexExecutionAuthority(
                    effective: ["/tmp/existing-read"],
                    status: .effective
                ),
                networkAccess: CodexExecutionAuthority(
                    effective: false,
                    status: .effective
                )
            )
        )

        let updated = CodexExecutionProfileCoordinator.mergeSessionPermissionGrant(
            into: existing,
            permissions: CodexRequestedPermissions(
                readRoots: ["/tmp/new-read"],
                writeRoots: ["/tmp/new-write"],
                networkEnabled: true
            )
        )

        XCTAssertEqual(
            updated.profile.extraReadableRoots.effective,
            ["/tmp/existing-read", "/tmp/new-read"]
        )
        XCTAssertEqual(
            updated.profile.writableRoots.effective,
            ["/tmp/existing-write", "/tmp/new-write"]
        )
        XCTAssertEqual(updated.profile.networkAccess.effective, true)
    }

    @MainActor
    func testActiveAuthorityLabelsReadFromSessionExecutionProfileState() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.routes.first?.id,
            threadID: "thread-1",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now,
            executionProfileState: CodexExecutionProfileState(
                profile: CodexExecutionProfile(
                    approvalPolicy: CodexExecutionAuthority(
                        effective: "never",
                        status: .effective
                    ),
                    sandboxMode: CodexExecutionAuthority(
                        effective: "read-only",
                        status: .effective
                    ),
                    writableRoots: CodexExecutionAuthority(
                        effective: [],
                        status: .effective
                    ),
                    extraReadableRoots: CodexExecutionAuthority(
                        effective: [],
                        status: .effective
                    ),
                    readAccess: CodexExecutionAuthority(
                        effective: .fullAccess,
                        status: .effective
                    ),
                    networkAccess: CodexExecutionAuthority(
                        effective: false,
                        status: .effective
                    )
                )
            )
        )

        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )
        model.selectedMachineID = machine.id
        model.activeSessionID = session.id

        XCTAssertEqual(model.activeApprovalPolicyLabel, "Approvals: never")
        XCTAssertEqual(model.activeSandboxLabel, "Sandbox: read-only")
        XCTAssertEqual(model.activeNetworkLabel, "Network: off")
        XCTAssertEqual(model.activeAuthorityStatusLabel, "Authority: effective")
    }

    @MainActor
    func testActiveSandboxLabelFallsBackToUnknownWhenRuntimeCannotProveValue() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.routes.first?.id,
            threadID: "thread-1",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now,
            executionProfileState: CodexExecutionProfileState(
                profile: CodexExecutionProfile(
                    approvalPolicy: CodexExecutionAuthority(
                        effective: "on-request",
                        status: .effective
                    ),
                    sandboxMode: CodexExecutionAuthority(
                        status: .unknown
                    ),
                    writableRoots: CodexExecutionAuthority(
                        effective: [],
                        status: .effective
                    ),
                    extraReadableRoots: CodexExecutionAuthority(
                        effective: [],
                        status: .effective
                    ),
                    readAccess: CodexExecutionAuthority(
                        effective: .fullAccess,
                        status: .effective
                    ),
                    networkAccess: CodexExecutionAuthority(
                        effective: true,
                        status: .effective
                    )
                )
            )
        )

        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )
        model.selectedMachineID = machine.id
        model.activeSessionID = session.id

        XCTAssertEqual(model.activeSandboxLabel, "Sandbox: unknown")
        XCTAssertEqual(model.activeAuthorityStatusLabel, "Authority: unknown")
    }

    @MainActor
    func testActiveApprovalAndSandboxLabelsDoNotTreatRequestedFallbackAsEffectiveTruth() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.routes.first?.id,
            threadID: "thread-1",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now,
            executionProfileState: CodexExecutionProfileState(
                profile: CodexExecutionProfile(
                    approvalPolicy: CodexExecutionAuthority(
                        requested: "never",
                        status: .unknown
                    ),
                    sandboxMode: CodexExecutionAuthority(
                        requested: "danger-full-access",
                        status: .unknown
                    ),
                    writableRoots: CodexExecutionAuthority(
                        status: .unknown
                    ),
                    extraReadableRoots: CodexExecutionAuthority(
                        status: .unknown
                    ),
                    readAccess: CodexExecutionAuthority(
                        status: .unknown
                    ),
                    networkAccess: CodexExecutionAuthority(
                        status: .unknown
                    )
                )
            )
        )

        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )
        model.selectedMachineID = machine.id
        model.activeSessionID = session.id

        XCTAssertEqual(model.activeApprovalPolicyLabel, "Approvals: unknown")
        XCTAssertEqual(model.activeSandboxLabel, "Sandbox: unknown")
        XCTAssertEqual(model.activeAuthorityStatusLabel, "Authority: unknown")
    }

    @MainActor
    func testActiveLabelsShowRequestedMismatchWhenEffectiveAuthorityIsWeaker() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.routes.first?.id,
            threadID: "thread-1",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now,
            executionProfileState: CodexExecutionProfileState(
                profile: CodexExecutionProfile(
                    approvalPolicy: CodexExecutionAuthority(
                        requested: "never",
                        effective: "on-request",
                        status: .unsupported
                    ),
                    sandboxMode: CodexExecutionAuthority(
                        requested: "danger-full-access",
                        effective: "workspace-write",
                        status: .unsupported
                    ),
                    writableRoots: CodexExecutionAuthority(
                        effective: [],
                        status: .effective
                    ),
                    extraReadableRoots: CodexExecutionAuthority(
                        effective: [],
                        status: .effective
                    ),
                    readAccess: CodexExecutionAuthority(
                        effective: .fullAccess,
                        status: .effective
                    ),
                    networkAccess: CodexExecutionAuthority(
                        effective: true,
                        status: .effective
                    )
                )
            )
        )

        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )
        model.selectedMachineID = machine.id
        model.activeSessionID = session.id

        XCTAssertEqual(model.activeApprovalPolicyLabel, "Approvals: on-request (requested never)")
        XCTAssertEqual(model.activeSandboxLabel, "Sandbox: workspace-write (requested danger-full-access)")
        XCTAssertEqual(model.activeAuthorityStatusLabel, "Authority: unsupported")
    }

    @MainActor
    func testActiveLabelsFallBackToUnknownWhenThreadContextHasNoExecutionProfileState() {
        let machine = MachineRecord.preview
        let session = SessionRecord(
            machineID: machine.id,
            routeID: machine.routes.first?.id,
            threadID: "thread-1",
            workspaceRoot: "/workspace/coding-on-the-go",
            lastKnownProtocol: .stdio,
            lastKnownBootstrap: .standardSSH,
            lastOpenedAt: .now
        )

        let model = AppModel(
            machines: [machine],
            recentSessions: [session],
            startRuntimeServices: false
        )
        model.selectedMachineID = machine.id
        model.activeSessionID = session.id

        XCTAssertEqual(model.activeApprovalPolicyLabel, "Approvals: unknown")
        XCTAssertEqual(model.activeSandboxLabel, "Sandbox: unknown")
        XCTAssertEqual(model.activeAuthorityStatusLabel, "Authority: unknown")
    }
}
