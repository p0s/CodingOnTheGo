import XCTest
@testable import HostBootstrap

final class HostRouteDetectionTests: XCTestCase {
    func testRuntimeProbeCollectsHostRouteSignals() async {
        let runner = RouteSignalRunner(
            responses: [
                "bash -lc 'scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null'": .init(
                    exitStatus: 0,
                    standardOutput: "example-mac\n"
                ),
                "bash -lc 'for iface in en0 en1 bridge0; do ip=$(ipconfig getifaddr \"$iface\" 2>/dev/null || true); if [[ -n \"$ip\" ]]; then echo \"$ip\"; break; fi; done'": .init(
                    exitStatus: 0,
                    standardOutput: "192.168.50.164\n"
                ),
                "bash -lc 'open -Ra Tailscale'": .init(exitStatus: 0),
                "bash -lc 'if command -v tailscale >/dev/null 2>&1; then tailscale status --json; elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then /Applications/Tailscale.app/Contents/MacOS/Tailscale status --json; else exit 1; fi'": .init(
                    exitStatus: 0,
                    standardOutput: """
                    {
                      "Self": {
                        "DNSName": "example-mac.example.ts.net.",
                        "TailscaleIPs": ["100.88.10.4", "fd7a:115c:a1e0::701:0a04"],
                        "Online": true
                      }
                    }
                    """
                ),
                "bash -lc 'open -Ra \"Coding On The Go Companion\"'": .init(exitStatus: 0)
            ]
        )

        let diagnostics = await HostCapabilityRuntimeProbe.collect(
            base: HostCapabilityDiagnostics(
                sshReachable: true,
                remoteLoginEnabled: true,
                codexInstalled: false,
                appServerAvailable: false,
                websocketSupported: false,
                authConfigured: true,
                hostKeyTrusted: true
            ),
            using: runner
        )

        XCTAssertEqual(diagnostics.localNetworkHostName, "example-mac")
        XCTAssertEqual(diagnostics.localNetworkAddress, "192.168.50.164")
        XCTAssertTrue(diagnostics.externalTailnetAppInstalledOnHost)
        XCTAssertTrue(diagnostics.externalTailnetRunningOnHost)
        XCTAssertEqual(diagnostics.externalTailnetDNSName, "example-mac.example.ts.net")
        XCTAssertEqual(diagnostics.externalTailnetIPAddress, "100.88.10.4")
        XCTAssertTrue(diagnostics.companionAppInstalled)
    }
}

private struct RouteSignalRunner: HostCapabilityCommandRunning {
    let responses: [String: HostCapabilityCommandResult]

    func run(command: String) async throws -> HostCapabilityCommandResult {
        responses[command] ?? HostCapabilityCommandResult(exitStatus: 1)
    }
}
