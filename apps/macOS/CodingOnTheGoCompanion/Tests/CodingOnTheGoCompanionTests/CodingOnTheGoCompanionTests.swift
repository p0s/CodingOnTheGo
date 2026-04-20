import CompanionHost
import XCTest

final class CodingOnTheGoCompanionTests: XCTestCase {
    func testPreviewCompanionSnapshotIsReady() {
        XCTAssertTrue(CompanionHostSnapshot.preview.presence.readyForEnhancedMode)
        XCTAssertEqual(CompanionHostSnapshot.preview.notificationBridge.mode, .fileRelay)
        XCTAssertFalse(CompanionHostSnapshot.preview.publication.note.isEmpty)
    }
}
