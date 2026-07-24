// Mirrors `sdks/web/tests/uuid.test.ts`.

import XCTest
@testable import AdfiniaSDK

final class UUIDv7Tests: XCTestCase {
    override func setUp() {
        super.setUp()
        UUIDv7.resetForTests()
    }

    func testCanonicalFormat() throws {
        let id = UUIDv7.generate()
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(id.startIndex..<id.endIndex, in: id)
        XCTAssertNotNil(
            regex.firstMatch(in: id, options: [], range: range),
            "Expected canonical UUIDv7 form, got \(id)"
        )
    }

    func testEncodesCurrentTimestamp() {
        let beforeMs = Int64(Date().timeIntervalSince1970 * 1000.0)
        let id = UUIDv7.generate()
        let afterMs = Int64(Date().timeIntervalSince1970 * 1000.0)

        let hex = id.replacingOccurrences(of: "-", with: "")
        let tsHex = String(hex.prefix(12))
        guard let timestamp = Int64(tsHex, radix: 16) else {
            return XCTFail("could not parse timestamp from \(tsHex)")
        }
        XCTAssertGreaterThanOrEqual(timestamp, beforeMs)
        XCTAssertLessThanOrEqual(timestamp, afterMs + 1)
    }

    func testMonotonicallyOrdered() {
        // Generate a burst — many should hit the same millisecond and rely
        // on the 12-bit counter to stay sorted.
        let ids = (0..<200).map { _ in UUIDv7.generate() }
        let sorted = ids.sorted()
        XCTAssertEqual(ids, sorted, "UUIDv7 burst should be monotonically ordered")
    }

    func testNoDuplicatesInBurst() {
        let ids = Set((0..<500).map { _ in UUIDv7.generate() })
        XCTAssertEqual(ids.count, 500, "Burst of UUIDv7s should be unique")
    }

    func testVersionAndVariantNibbles() {
        let id = UUIDv7.generate()
        let chars = Array(id)
        XCTAssertEqual(chars[14], "7", "Version nibble should be 7")
        let variant = chars[19]
        XCTAssertTrue(
            "89ab".contains(variant),
            "Variant nibble should be 8, 9, a, or b (got \(variant))"
        )
    }
}
