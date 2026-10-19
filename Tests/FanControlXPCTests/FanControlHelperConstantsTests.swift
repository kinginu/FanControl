import Foundation
import Testing
@testable import FanControlXPC

struct FanControlHelperConstantsTests {
    @Test func testAllowedKeys() {
        for key in ["F0Tg", "F9Md", "FS! ", "F3Mn"] {
            #expect(FanControlHelperConstants.isWriteAllowed(key: key), Comment(rawValue: key))
        }
    }

    @Test func testRejectedKeys() {
        for key in ["F0Tg\n", "f0Tg", "F10T", "FS!", "F0Ac", "TC0P", "", "F0Mx", "FS!\u{0}", "F0T\u{E9}"] {
            #expect(!FanControlHelperConstants.isWriteAllowed(key: key), Comment(rawValue: key.debugDescription))
        }
    }

    @Test func testCachedRegexesMatchRepeatedly() {
        for _ in 0..<3 {
            #expect(FanControlHelperConstants.isWriteAllowed(key: "F0Tg"))
            #expect(!FanControlHelperConstants.isWriteAllowed(key: "F0Ac"))
        }
    }

    @Test func testClientRequirement() {
        let req = FanControlHelperConstants.clientCodeSigningRequirement(teamID: "ABCDE12345")
        #expect(req.contains("ABCDE12345"))
        #expect(req.contains("\"\(FanControlHelperConstants.appBundleIdentifier)\""))
        #expect(req.contains("com.example.dynamicnotch.DynamicNotch"))
        #expect(req.hasPrefix("anchor apple generic"))
    }
}

extension FanControlHelperConstantsTests {
    @Test func testHelperRequirement() {
        let req = FanControlHelperConstants.helperCodeSigningRequirement(teamID: "ABCDE12345")
        #expect(req == "anchor apple generic and identifier \"com.example.dynamicnotch.DynamicNotch.fanfi\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
        #expect(FanControlHelperConstants.helperIdentifier == FanControlHelperConstants.machServiceName)
    }
}
