import Foundation
import Testing
@testable import FanControlXPC

@Suite("Helper constants and write allowlist", .tags(.helper, .install))
struct FanControlHelperConstantsTests {
    @Test(arguments: ["F0Tg", "F9Md", "F1Tg", "F1Md"])
    func allowedKeys(key: String) {
        #expect(FanControlHelperConstants.isWriteAllowed(key: key))
        #expect(FanControlHelperConstants.isWriteAllowed(key: key), "the cached regexes match again")
    }

    /// Apple Silicon only (Intel dropped 2026-10-20): no Intel force-bit key and
    /// no `F<n>Mn` pattern in the allowlist.
    @Test func allowlistHasNoIntelKeys() {
        #expect(FanControlHelperConstants.allowedWriteKeyPatterns == ["^F[0-9]Tg$", "^F[0-9]Md$"])
        #expect(!FanControlHelperConstants.allowedWriteKeyPatterns.contains { $0.contains("FS!") || $0.contains("Mn") })
        #expect(!FanControlHelperConstants.isWriteAllowed(key: "FS! "))
    }

    /// Malformed, read-only or unrelated keys; the pre-write review (2026-10-20) adds
    /// keys that are never written (read-only on Apple Silicon / the `Ftst` unlock key).
    @Test(arguments: ["F0Tg\n", "f0Tg", "F10T", "FS!", "FS! ", "F0Ac", "TC0P", "", "F0Mx", "FS!\u{0}", "F0T\u{E9}",
                      "F0Mn", "F3Mn", "Ftst", "F0St", "F0Dc"])
    func rejectedKeys(key: String) {
        #expect(!FanControlHelperConstants.isWriteAllowed(key: key), "\(key.debugDescription)")
    }

    @Test func clientRequirement() {
        let req = FanControlHelperConstants.clientCodeSigningRequirement(teamID: "ABCDE12345")
        #expect(req.contains("ABCDE12345"))
        #expect(req.contains("\"\(FanControlHelperConstants.appBundleIdentifier)\""))
        #expect(req.contains("com.example.dynamicnotch.DynamicNotch"))
        #expect(req.hasPrefix("anchor apple generic"))
    }
}

extension FanControlHelperConstantsTests {
    @Test func helperRequirement() {
        let req = FanControlHelperConstants.helperCodeSigningRequirement(teamID: "ABCDE12345")
        #expect(req == "anchor apple generic and identifier \"com.example.dynamicnotch.DynamicNotch.fanfi\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
        #expect(FanControlHelperConstants.helperIdentifier == FanControlHelperConstants.machServiceName)
    }
}
