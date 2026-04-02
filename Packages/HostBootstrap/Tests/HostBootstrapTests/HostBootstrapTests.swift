import XCTest
@testable import HostBootstrap

final class HostBootstrapTests: XCTestCase {
    func testBootstrapCanExposeCodexRuntimeSignals() {
        let status = HostBootstrapStatus(
            codexInstalled: true,
            stdioAppServerReady: true,
            websocketReuseAvailable: true
        )

        XCTAssertTrue(status.codexInstalled)
        XCTAssertTrue(status.stdioAppServerReady)
        XCTAssertTrue(status.websocketReuseAvailable)
    }

    func testCapabilityProbeProducesRemoteLoginRemediation() {
        let report = HostCapabilityProbe.assess(
            HostCapabilityDiagnostics(
                sshReachable: true,
                remoteLoginEnabled: false,
                codexInstalled: true,
                appServerAvailable: true,
                websocketSupported: false,
                authConfigured: true,
                hostKeyTrusted: true
            )
        )

        XCTAssertEqual(
            report.check(.remoteLogin).flatMap(HostCapabilityCheckFormatter.remediation(for:)),
            "On the Mac, open System Settings -> General -> Sharing -> turn on Remote Login."
        )
        XCTAssertFalse(report.isSafeLaneReady)
    }

    func testRuntimeProbeCollectsCodexGitAndHandoffSignals() async {
        let runtimeSummary = """
        binaryPath=/Applications/Codex.app/Contents/Resources/codex
        version=codex-cli 1.2.3
        provenance=appBundle
        appBundlePath=/Applications/Codex.app
        websocketSupported=true
        """
        let runner = MockRunner(
            responses: [
                CodexRuntimeDiscovery.summaryCommand(): .init(
                    exitStatus: 0,
                    standardOutput: runtimeSummary
                ),
                "bash -lc 'export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; git --version'": .init(
                    exitStatus: 0,
                    standardOutput: "git version 2.49.0\n"
                ),
                "bash -lc 'open -Ra Codex'": .init(exitStatus: 0)
            ]
        )

        let diagnostics = await HostCapabilityRuntimeProbe.collect(
            base: HostCapabilityDiagnostics(
                sshReachable: true,
                remoteLoginEnabled: true,
                codexInstalled: false,
                appServerAvailable: false,
                websocketSupported: true,
                authConfigured: true,
                hostKeyTrusted: true
            ),
            using: runner
        )

        XCTAssertTrue(diagnostics.codexInstalled)
        XCTAssertEqual(diagnostics.codexVersion, "codex-cli 1.2.3")
        XCTAssertTrue(diagnostics.appServerAvailable)
        XCTAssertTrue(diagnostics.websocketSupported)
        XCTAssertTrue(diagnostics.gitAvailable)
        XCTAssertEqual(diagnostics.gitVersion, "git version 2.49.0")
        XCTAssertTrue(diagnostics.codexMacAppInstalled)
        XCTAssertEqual(diagnostics.resolvedRuntime?.binaryPath, "/Applications/Codex.app/Contents/Resources/codex")
        XCTAssertEqual(diagnostics.resolvedRuntime?.version, "codex-cli 1.2.3")
        XCTAssertEqual(diagnostics.resolvedRuntime?.provenance.rawValue, "appBundle")
        XCTAssertEqual(diagnostics.resolvedRuntime?.appBundlePath, "/Applications/Codex.app")
    }

    func testCapabilityProbeKeepsHostRuntimeChecksPendingUntilSSHIsReady() {
        let report = HostCapabilityProbe.assess(
            HostCapabilityDiagnostics(
                sshReachable: true,
                remoteLoginEnabled: true,
                codexInstalled: false,
                appServerAvailable: false,
                websocketSupported: false,
                authConfigured: false,
                hostKeyTrusted: false
            )
        )

        XCTAssertEqual(report.check(.codexCLI)?.state, .warning)
        XCTAssertEqual(report.check(.appServer)?.state, .warning)
        XCTAssertEqual(
            report.check(.git).map(HostCapabilityCheckFormatter.summary(for:)),
            "Connect first to probe Git and unlock workspace tooling."
        )
    }
}

private struct MockRunner: HostCapabilityCommandRunning {
    let responses: [String: HostCapabilityCommandResult]

    func run(command: String) async throws -> HostCapabilityCommandResult {
        responses[command] ?? HostCapabilityCommandResult(exitStatus: 1)
    }
}
