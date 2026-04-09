import CodexRPC
import Foundation
import SharedModels

struct CodexRequestedExecutionOverride: Hashable, Sendable {
    var approvalPolicy: String?
    var sandboxMode: String?

    init(
        approvalPolicy: String? = nil,
        sandboxMode: String? = nil
    ) {
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
    }

    init(threadOptions: CodexThreadExecutionOptions) {
        self.init(
            approvalPolicy: threadOptions.approvalPolicy,
            sandboxMode: threadOptions.sandboxMode?.rawValue
        )
    }

    init(turnOptions: CodexTurnExecutionOptions) {
        let sandboxMode: String? = switch turnOptions.sandboxPolicy {
        case .dangerFullAccess:
            CodexSandboxMode.dangerFullAccess.rawValue
        case .readOnly:
            CodexSandboxMode.readOnly.rawValue
        case .workspaceWrite:
            CodexSandboxMode.workspaceWrite.rawValue
        case .externalSandbox:
            "externalSandbox"
        case nil:
            nil
        }

        self.init(
            approvalPolicy: turnOptions.approvalPolicy,
            sandboxMode: sandboxMode
        )
    }

    var hasOverride: Bool {
        approvalPolicy != nil || sandboxMode != nil
    }
}

enum CodexExecutionProfileCoordinator {
    static func requestedThreadExecutionOptions(
        from session: SessionRecord?,
        baseline: CodexExecutionBaselineConfigSnapshot?
    ) -> CodexThreadExecutionOptions {
        CodexThreadExecutionOptions(
            cwd: session?.workspaceRoot,
            model: session?.lastModel,
            approvalPolicy: session?.executionProfileState?.profile.approvalPolicy.requested
                ?? session?.executionProfileState?.profile.approvalPolicy.effective
                ?? baseline?.approvalPolicy,
            sandboxMode: preferredSandboxMode(
                requested: session?.executionProfileState?.profile.sandboxMode.requested
                    ?? session?.executionProfileState?.profile.sandboxMode.effective
                    ?? baseline?.sandboxMode
            )
        )
    }

    static func updateProfileState(
        existing: CodexExecutionProfileState?,
        runtime: CodexResolvedRuntime?,
        baseline: CodexExecutionBaselineConfigSnapshot?,
        constraints: CodexExecutionConstraintsSnapshot?,
        support: CodexExecutionSupportSnapshot? = nil,
        effectiveProfile: CodexExecutionProfile?,
        requestedOverride: CodexRequestedExecutionOverride? = nil,
        requestedOverrideSupport: CodexExecutionSupportState? = nil
    ) -> CodexExecutionProfileState {
        let existingProfile = existing?.profile ?? .init()
        let supportSnapshot = support ?? existing?.support ?? .init()
        let normalizedRequestedOverride = requestedOverride?.hasOverride == true ? requestedOverride : nil
        let overrideSupport = requestedOverrideSupport ?? supportSnapshot.threadResumeOverrides
        let requestedApproval = normalizedRequestedOverride?.approvalPolicy
            ?? existingProfile.approvalPolicy.requested
            ?? existingProfile.approvalPolicy.effective
            ?? baseline?.approvalPolicy
        let requestedSandbox = normalizedRequestedOverride?.sandboxMode
            ?? existingProfile.sandboxMode.requested
            ?? existingProfile.sandboxMode.effective
            ?? baseline?.sandboxMode

        let effective = effectiveProfile ?? existingProfile
        var profile = effective
        profile.runtime = runtime ?? existingProfile.runtime
        profile.approvalPolicy.requested = requestedApproval
        profile.sandboxMode.requested = requestedSandbox
        profile.approvalPolicy.status = valueStatus(
            requested: requestedApproval,
            effective: profile.approvalPolicy.effective,
            support: overrideSupport
        )
        profile.sandboxMode.status = valueStatus(
            requested: requestedSandbox,
            effective: profile.sandboxMode.effective,
            support: overrideSupport
        )
        profile.writableRoots.status = inferredStatus(for: profile.writableRoots)
        profile.extraReadableRoots.status = inferredStatus(for: profile.extraReadableRoots)
        profile.readAccess.status = inferredStatus(for: profile.readAccess)
        profile.networkAccess.status = inferredStatus(for: profile.networkAccess)
        profile.approvalPolicy.detail = constrainedDetail(
            requested: requestedApproval,
            allowed: constraints?.allowedApprovalPolicies
        )
        profile.sandboxMode.detail = constrainedDetail(
            requested: requestedSandbox,
            allowed: constraints?.allowedSandboxModes
        )

        return CodexExecutionProfileState(
            baselineConfig: baseline ?? existing?.baselineConfig,
            constraints: constraints ?? existing?.constraints,
            support: supportSnapshot,
            profile: profile,
            lastUpdatedAt: .now
        )
    }

    static func markResumeOverrideUnsupported(
        existing: CodexExecutionProfileState,
        effectiveProfile: CodexExecutionProfile?
    ) -> CodexExecutionProfileState {
        var updated = updateProfileState(
            existing: existing,
            runtime: existing.profile.runtime,
            baseline: existing.baselineConfig,
            constraints: existing.constraints,
            support: {
                var support = existing.support
                support.threadResumeOverrides = .unsupported
                return support
            }(),
            effectiveProfile: effectiveProfile
        )
        updated.profile.approvalPolicy.status = .unsupported
        updated.profile.approvalPolicy.detail = "Live thread/resume did not preserve the requested approval policy."
        updated.profile.sandboxMode.status = .unsupported
        updated.profile.sandboxMode.detail = "Live thread/resume did not preserve the requested sandbox mode."
        return updated
    }

    static func mergeSessionPermissionGrant(
        into state: CodexExecutionProfileState,
        permissions: CodexRequestedPermissions
    ) -> CodexExecutionProfileState {
        var profile = state.profile
        let mergedReadRoots = Array(Set(profile.extraReadableRoots.effective ?? []).union(permissions.readRoots)).sorted()
        let mergedWriteRoots = Array(Set(profile.writableRoots.effective ?? []).union(permissions.writeRoots)).sorted()

        profile.extraReadableRoots.requested = mergedReadRoots
        profile.extraReadableRoots.effective = mergedReadRoots
        profile.extraReadableRoots.status = .effective
        profile.writableRoots.requested = mergedWriteRoots
        profile.writableRoots.effective = mergedWriteRoots
        profile.writableRoots.status = .effective

        if let networkEnabled = permissions.networkEnabled {
            profile.networkAccess.requested = networkEnabled
            profile.networkAccess.effective = networkEnabled
            profile.networkAccess.status = .effective
        }

        return CodexExecutionProfileState(
            baselineConfig: state.baselineConfig,
            constraints: state.constraints,
            support: state.support,
            profile: profile,
            lastUpdatedAt: .now
        )
    }

    static func effectiveProfileChanged(
        previous: CodexExecutionProfileState?,
        current: CodexExecutionProfileState?
    ) -> Bool {
        previous?.profile != current?.profile
    }

    private static func preferredSandboxMode(requested: String?) -> CodexSandboxMode? {
        guard let requested else {
            return nil
        }
        return CodexSandboxMode(rawValue: requested)
    }

    private static func constrainedDetail(requested: String?, allowed: [String]?) -> String? {
        guard let requested,
              let allowed,
              !allowed.contains(requested) else {
            return nil
        }

        return "Requested \(requested), but the host allows only \(allowed.joined(separator: ", "))."
    }

    private static func valueStatus<Value: Equatable>(
        requested: Value?,
        effective: Value?,
        support: CodexExecutionSupportState
    ) -> CodexExecutionValueStatus {
        switch support {
        case .unsupported:
            return .unsupported
        case .unknown:
            guard let effective else {
                return requested == nil ? .unknown : .requested
            }
            return requested == nil || requested == effective ? .effective : .constrained
        case .supported:
            guard let effective else {
                return requested == nil ? .unknown : .requested
            }
            return requested == nil || requested == effective ? .effective : .constrained
        }
    }

    private static func inferredStatus<Value: Hashable & Codable & Sendable>(
        for authority: CodexExecutionAuthority<Value>
    ) -> CodexExecutionValueStatus {
        if authority.status == .unsupported {
            return .unsupported
        }
        return authority.effective == nil ? .unknown : .effective
    }
}
