// Smoke tests — only exercise the public surface. Full coverage lands with
// NEXT-IOS-2 (real transport tests).

import XCTest
@testable import AdfiniaSDK

final class AdfiniaSDKTests: XCTestCase {
    func testInitializeAcceptsConfig() {
        Adfinia.initialize(AdfiniaConfig(writeKey: "pk_test_x"))
        // No assertion — just verify it doesn't throw.
    }

    func testTrackBeforeInitDoesNotCrash() {
        // Should print a warning, not throw.
        let client = AdfiniaClient()
        client.track("Order Completed")
    }

    func testIdentifyEnumStringCase() {
        let arg = AdfiniaIdentifyArg.customerId("cust_42")
        if case .customerId(let id) = arg {
            XCTAssertEqual(id, "cust_42")
        } else {
            XCTFail("expected .customerId case")
        }
    }
}
