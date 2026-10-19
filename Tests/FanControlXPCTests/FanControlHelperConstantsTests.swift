import XCTest
@testable import FanControlXPC

final class FanControlHelperConstantsTests: XCTestCase {
    func testAllowedKeys() {
        for key in ["F0Tg", "F9Md", "FS! ", "F3Mn"] {
            XCTAssertTrue(FanControlHelperConstants.isWriteAllowed(key: key), key)
        }
    }

    func testRejectedKeys() {
        for key in ["F0Tg\n", "f0Tg", "F10T", "FS!", "F0Ac", "TC0P", "", "F0Mx", "FS!\u{0}", "F0T\u{E9}"] {
            XCTAssertFalse(FanControlHelperConstants.isWriteAllowed(key: key), key.debugDescription)
        }
    }

    func testCachedRegexesMatchRepeatedly() {
        for _ in 0..<3 {
            XCTAssertTrue(FanControlHelperConstants.isWriteAllowed(key: "F0Tg"))
            XCTAssertFalse(FanControlHelperConstants.isWriteAllowed(key: "F0Ac"))
        }
    }

    func testClientRequirement() {
        let req = FanControlHelperConstants.clientCodeSigningRequirement(teamID: "ABCDE12345")
        XCTAssertTrue(req.contains("ABCDE12345"))
        XCTAssertTrue(req.contains("\"\(FanControlHelperConstants.appBundleIdentifier)\""))
        XCTAssertTrue(req.contains("com.example.dynamicnotch.DynamicNotch"))
        XCTAssertTrue(req.hasPrefix("anchor apple generic"))
    }
}

extension FanControlHelperConstantsTests {
    func testHelperRequirement() {
        let req = FanControlHelperConstants.helperCodeSigningRequirement(teamID: "ABCDE12345")
        XCTAssertEqual(req,
            "anchor apple generic and identifier \"com.example.dynamicnotch.DynamicNotch.fancontrol\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
        XCTAssertEqual(FanControlHelperConstants.helperIdentifier, FanControlHelperConstants.machServiceName)
    }
}
