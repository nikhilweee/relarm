import XCTest
@testable import RelarmCore

final class AppVersionTests: XCTestCase {
    func testComparesComponentsNumerically() {
        XCTAssertTrue(AppVersion.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(AppVersion.isNewer("0.9.0", than: "0.10.0"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(AppVersion.isNewer("0.6.0", than: "0.6.0"))
        XCTAssertFalse(AppVersion.isNewer("0.6", than: "0.6.0"))
    }

    func testIgnoresTagPrefix() {
        XCTAssertTrue(AppVersion.isNewer("v0.7.0", than: "0.6.0"))
        XCTAssertEqual(AppVersion.components("v1.2.3"), [1, 2, 3])
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(AppVersion.isNewer("1.0.1", than: "1"))
    }
}
