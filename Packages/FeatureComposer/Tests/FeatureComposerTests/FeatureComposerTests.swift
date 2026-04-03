import XCTest
@testable import FeatureComposer

final class FeatureComposerTests: XCTestCase {
    func testComposerCanSendWhenAttachmentExists() {
        let state = ComposerFeatureState(
            draft: "",
            attachments: [ComposerAttachment(kind: .photo, displayName: "Screenshot")]
        )

        XCTAssertTrue(state.canSend)
    }
}
