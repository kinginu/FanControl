import Foundation
import Testing
@testable import FanControlXPC

private typealias C = FanControlHelperConstants

struct ManualInstallModeTests {
    static let hash = "0123456789abcdef0123456789abcdef01234567"

    @Test func testCDHashValidation() {
        #expect(C.isValidCDHash(Self.hash))
        #expect(C.isValidCDHash(Self.hash.uppercased()))
        #expect(C.normalizedCDHash(Self.hash.uppercased()) == Self.hash)
        for bad in ["", "0123", String(Self.hash.dropLast()), Self.hash + "0", "g" + Self.hash.dropFirst(),
                    " " + Self.hash.dropFirst(), String(repeating: "\u{FF10}", count: 40), "0x" + Self.hash.dropFirst(2)] {
            #expect(!C.isValidCDHash(bad), Comment(rawValue: bad.debugDescription))
            #expect(C.normalizedCDHash(bad) == nil)
        }
    }

    @Test func testRequirementBuilders() {
        #expect(C.manualModeClientRequirement(cdhash: Self.hash)
                == "identifier \"com.example.dynamicnotch.DynamicNotch\" and cdhash H\"\(Self.hash)\"")
        #expect(C.manualModeHelperRequirement(cdhash: Self.hash.uppercased())
                == "identifier \"com.example.dynamicnotch.DynamicNotch.fanfi\" and cdhash H\"\(Self.hash)\"")
        #expect(C.manualModeClientRequirement(cdhash: "abc") == nil)
        #expect(C.manualModeHelperRequirement(cdhash: "") == nil)
    }

    @Test func testValidatorAcceptsBuilderOutput() throws {
        let req = try #require(C.manualModeClientRequirement(cdhash: Self.hash))
        #expect(C.validateManualClientRequirement(req) == .success(Self.hash))
        #expect(C.validateManualClientRequirement("  \(req)\n") == .success(Self.hash))
        let upper = "identifier \"\(C.appBundleIdentifier)\" and cdhash H\"\(Self.hash.uppercased())\""
        #expect(C.validateManualClientRequirement(upper) == .success(Self.hash))
    }

    @Test func testValidatorRejectsWeakOrMalformed() {
        let id = "identifier \"\(C.appBundleIdentifier)\""
        #expect(C.validateManualClientRequirement("") == .failure(.empty))
        #expect(C.validateManualClientRequirement("   ") == .failure(.empty))
        // Bundle id only: spoofable by any ad-hoc signed process.
        #expect(C.validateManualClientRequirement(id) == .failure(.wrongIdentifier(id)))
        #expect(C.validateManualClientRequirement("\(id) and anchor apple generic") == .failure(.missingCDHash("\(id) and anchor apple generic")))
        // Other identifiers (the helper's, a prefix match, …).
        for other in ["identifier \"com.example.dynamicnotch.DynamicNotch.fanfi\" and cdhash H\"\(Self.hash)\"",
                      "identifier \"com.example.dynamicnotch.DynamicNotchX\" and cdhash H\"\(Self.hash)\"",
                      "cdhash H\"\(Self.hash)\"",
                      "anchor apple generic and \(id) and cdhash H\"\(Self.hash)\""] {
            #expect(C.validateManualClientRequirement(other) == .failure(.wrongIdentifier(other)), Comment(rawValue: other))
        }
        // Widened with a disjunction or extra clauses, or a bad hash.
        let widened = "\(id) and cdhash H\"\(Self.hash)\" or anchor apple"
        #expect(C.validateManualClientRequirement(widened) == .failure(.malformed(widened)))
        let reordered = "\(id) or cdhash H\"\(Self.hash)\""
        #expect(C.validateManualClientRequirement(reordered) == .failure(.malformed(reordered)))
        let shortHash = "\(id) and cdhash H\"0123\""
        #expect(C.validateManualClientRequirement(shortHash) == .failure(.malformed(shortHash)))
        let badHex = "\(id) and cdhash H\"\(String(repeating: "z", count: 40))\""
        #expect(C.validateManualClientRequirement(badHex) == .failure(.invalidCDHash(String(repeating: "z", count: 40))))
    }

    @Test func testResolveWithoutOverrideUsesTeamID() {
        let result = C.resolveClientRequirement(environment: ["PATH": "/usr/bin"], teamID: "ABCDE12345")
        #expect(result == .success(ClientRequirement(mode: .teamID,
                                                     requirement: C.clientCodeSigningRequirement(teamID: "ABCDE12345"))))
    }

    @Test func testResolveWithValidOverride() throws {
        let req = try #require(C.manualModeClientRequirement(cdhash: Self.hash))
        var teamIDEvaluated = false
        func team() -> String { teamIDEvaluated = true; return "ABCDE12345" }
        let result = C.resolveClientRequirement(environment: [C.clientRequirementEnvironmentKey: req + "\n"], teamID: team())
        #expect(result == .success(ClientRequirement(mode: .manualCDHash(Self.hash), requirement: req)))
        #expect(!teamIDEvaluated, "Team ID lookup (and its placeholder warning) must be skipped in manual mode")
    }

    @Test func testResolveWithInvalidOverrideFails() {
        // Present but empty / weak: never falls back to the Team ID requirement.
        #expect(C.resolveClientRequirement(environment: [C.clientRequirementEnvironmentKey: ""], teamID: "T") == .failure(.empty))
        let weak = "identifier \"\(C.appBundleIdentifier)\""
        guard case .failure = C.resolveClientRequirement(environment: [C.clientRequirementEnvironmentKey: weak], teamID: "T") else {
            Issue.record("bundle-id-only override must be refused")
            return
        }
        // The unfilled template value.
        guard case .failure = C.resolveClientRequirement(
            environment: [C.clientRequirementEnvironmentKey: "__FILLED_IN_BY_INSTALL_SH__"], teamID: "T") else {
            Issue.record("template placeholder must be refused")
            return
        }
    }

    @Test func testHelperRequirementMode() {
        #expect(C.helperRequirementMode(appTeamID: "ABCDE12345", manualInstallDetected: false) == .teamID)
        #expect(C.helperRequirementMode(appTeamID: "ABCDE12345", manualInstallDetected: true) == .manualCDHash)
        #expect(C.helperRequirementMode(appTeamID: nil, manualInstallDetected: false) == .manualCDHash)
        #expect(C.helperRequirementMode(appTeamID: "", manualInstallDetected: false) == .manualCDHash)
    }

    @Test func testManualInstallState() {
        #expect(C.manualInstallState(plistExists: true, helperExists: true) == .installed)
        #expect(C.manualInstallState(plistExists: false, helperExists: false) == .absent)
        #expect(C.manualInstallState(plistExists: true, helperExists: false) == .incomplete(missing: C.manualHelperPath))
        #expect(C.manualInstallState(plistExists: false, helperExists: true) == .incomplete(missing: C.manualLaunchDaemonPlistPath))
    }

    @Test func testPathsAndTrustAnchorCheck() {
        #expect(C.manualHelperPath == "/Library/PrivilegedHelperTools/com.example.dynamicnotch.DynamicNotch.fanfi")
        #expect(C.manualLaunchDaemonPlistPath == "/Library/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist")
        #expect(C.isRootOwnedAndProtected(ownerUID: 0, permissions: 0o755))
        #expect(C.isRootOwnedAndProtected(ownerUID: 0, permissions: 0o644))
        #expect(!C.isRootOwnedAndProtected(ownerUID: 501, permissions: 0o755))
        #expect(!C.isRootOwnedAndProtected(ownerUID: 0, permissions: 0o775))
        #expect(!C.isRootOwnedAndProtected(ownerUID: 0, permissions: 0o757))
    }
}

/// The shell scripts and the plist template must use the same names and format as the Swift code.
struct ManualInstallScriptConsistencyTests {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Support/manual-install")

    @Test func testTemplatePlistMatchesConstants() throws {
        let url = Self.dir.appendingPathComponent("\(C.launchdLabel).manual.plist")
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == C.launchdLabel)
        #expect(plist["Program"] as? String == C.manualHelperPath)
        #expect((plist["MachServices"] as? [String: Bool]) == [C.machServiceName: true])
        #expect(plist["RunAtLoad"] as? Bool == false)
        #expect(plist["ProcessType"] as? String == "Adaptive")
        #expect(plist["BundleProgram"] == nil)
        let env = try #require(plist["EnvironmentVariables"] as? [String: String])
        let placeholder = try #require(env[C.clientRequirementEnvironmentKey])
        // Installed unfilled, the helper would refuse to start.
        guard case .failure = C.validateManualClientRequirement(placeholder) else {
            Issue.record("template placeholder must not validate")
            return
        }
    }

    @Test func testCommonShMatchesConstants() throws {
        let sh = try String(contentsOf: Self.dir.appendingPathComponent("common.sh"), encoding: .utf8)
        #expect(sh.contains("LABEL=\"\(C.launchdLabel)\""))
        #expect(sh.contains("APP_BUNDLE_ID=\"\(C.appBundleIdentifier)\""))
        #expect(sh.contains("HELPER_IN_APP=\"Contents/MacOS/\(C.helperExecutableName)\""))
        #expect(sh.contains("HELPER_DEST=\"/Library/PrivilegedHelperTools/${LABEL}\""))
        #expect(sh.contains("PLIST_DEST=\"/Library/LaunchDaemons/${LABEL}.plist\""))
        #expect(sh.contains("ENV_KEY=\"\(C.clientRequirementEnvironmentKey)\""))
        // client_requirement() printf format == manualModeClientRequirement(cdhash:).
        let format = "printf 'identifier \"%s\" and cdhash H\"%s\"' \"$APP_BUNDLE_ID\" \"$1\""
        #expect(sh.contains(format))
        let rendered = "identifier \"\(C.appBundleIdentifier)\" and cdhash H\"\(ManualInstallModeTests.hash)\""
        #expect(C.manualModeClientRequirement(cdhash: ManualInstallModeTests.hash) == rendered)
        for script in [C.manualInstallScriptName, C.manualUninstallScriptName, "status.sh"] {
            #expect(FileManager.default.isExecutableFile(atPath: Self.dir.appendingPathComponent(script).path), Comment(rawValue: script))
        }
    }
}
