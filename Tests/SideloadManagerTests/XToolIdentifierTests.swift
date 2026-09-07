import XCTest
@testable import SideloadManager

final class XToolIdentifierTests: XCTestCase {
    func testExtractsOriginalBundleIdentifierFromInstalledApp() {
        XCTAssertEqual(
            XToolIdentifier.originalBundleIdentifier(from: "XTL-1234ABCD.com.example.Reader"),
            "com.example.Reader"
        )
    }

    func testExtractsOriginalBundleIdentifierFromProfileApplicationIdentifier() {
        XCTAssertEqual(
            XToolIdentifier.originalBundleIdentifier(from: "TEAM123456.XTL-1234ABCD.com.example.Reader"),
            "com.example.Reader"
        )
    }

    func testRejectsUnrelatedEmbeddedMarker() {
        XCTAssertNil(
            XToolIdentifier.originalBundleIdentifier(from: "com.example.XTL-1234ABCD.Reader")
        )
        XCTAssertFalse(
            XToolIdentifier.matches(
                "TEAM123456.com.example.Reader",
                originalBundleIdentifier: "com.example.Reader"
            )
        )
    }

    func testMatchesOriginalAndXToolIdentifiersOnly() {
        XCTAssertTrue(
            XToolIdentifier.matches("com.example.Reader", originalBundleIdentifier: "com.example.Reader")
        )
        XCTAssertTrue(
            XToolIdentifier.matches(
                "XTL-1234ABCD.com.example.Reader",
                originalBundleIdentifier: "com.example.Reader"
            )
        )
        XCTAssertFalse(
            XToolIdentifier.matches(
                "XTL-1234ABCD.com.example.ReaderPro",
                originalBundleIdentifier: "com.example.Reader"
            )
        )
    }
}
