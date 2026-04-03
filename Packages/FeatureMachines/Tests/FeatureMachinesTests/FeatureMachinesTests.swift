import SharedModels
import XCTest
@testable import FeatureMachines

final class FeatureMachinesTests: XCTestCase {
    func testRouteSummaryIncludesRecommendedKind() {
        let summary = MachineDirectoryFeature.routeSummary(for: .preview)
        XCTAssertTrue(summary.contains("Embedded Tailscale"))
    }
}
