import Foundation
import Testing
@testable import FanControlXPC

private typealias C = FanControlHelperConstants

@Suite("Manual install mode", .tags(.install, .helper))
struct ManualInstallModeTests {
    static let hash = "0123456789abcdef0123456789abcdef01234567"

    @Test func cdHashValidation() {
        #expect(C.isValidCDHash(Self.hash))
        #expect(C.isValidCDHash(Self.hash.uppercased()))
        #expect(C.normalizedCDHash(Self.hash.uppercased()) == Self.hash)
        for bad in ["", "0123", String(Self.hash.dropLast()), Self.hash + "0", "g" + Self.hash.dropFirst(),
                    " " + Self.hash.dropFirst(), String(repeating: "\u{FF10}", count: 40), "0x" + Self.hash.dropFirst(2)] {
            #expect(!C.isValidCDHash(bad), Comment(rawValue: bad.debugDescription))
            #expect(C.normalizedCDHash(bad) == nil)
        }
    }

    @Test func requirementBuilders() {
        #expect(C.manualModeClientRequirement(cdhash: Self.hash)
                == "identifier \"com.example.dynamicnotch.DynamicNotch\" and cdhash H\"\(Self.hash)\"")
        #expect(C.manualModeHelperRequirement(cdhash: Self.hash.uppercased())
                == "identifier \"com.example.dynamicnotch.DynamicNotch.fanfi\" and cdhash H\"\(Self.hash)\"")
        #expect(C.manualModeClientRequirement(cdhash: "abc") == nil)
        #expect(C.manualModeHelperRequirement(cdhash: "") == nil)
    }

    @Test func validatorAcceptsBuilderOutput() throws {
        let req = try #require(C.manualModeClientRequirement(cdhash: Self.hash))
        #expect(C.validateManualClientRequirement(req) == .success(Self.hash))
        #expect(C.validateManualClientRequirement("  \(req)\n") == .success(Self.hash))
        let upper = "identifier \"\(C.appBundleIdentifier)\" and cdhash H\"\(Self.hash.uppercased())\""
        #expect(C.validateManualClientRequirement(upper) == .success(Self.hash))
    }

    @Test func clientPinCheck() throws {
        let app = String(repeating: "ab", count: 20)
        let other = String(repeating: "cd", count: 20)
        let pinnedApp = try #require(C.manualModeClientRequirement(cdhash: app))
        let pinnedOther = try #require(C.manualModeClientRequirement(cdhash: other))
        #expect(C.manualClientPinCheck(pinnedRequirement: pinnedApp, appCDHash: app) == .matches)
        // Case-insensitive on the app side.
        #expect(C.manualClientPinCheck(pinnedRequirement: pinnedApp, appCDHash: app.uppercased()) == .matches)
        #expect(C.manualClientPinCheck(pinnedRequirement: pinnedOther, appCDHash: app)
                == .mismatch(pinnedCDHash: other, appCDHash: app))
        // Undecidable inputs never claim a mismatch.
        for (requirement, hash) in [(nil, app), (pinnedOther, nil), (pinnedOther, "xyz"),
                                    ("identifier \"evil\" and cdhash H\"\(other)\"", app)] as [(String?, String?)] {
            guard case .unknown = C.manualClientPinCheck(pinnedRequirement: requirement, appCDHash: hash) else {
                Issue.record("expected .unknown for \(String(describing: requirement)) / \(String(describing: hash))")
                continue
            }
        }
    }

    @Test func validatorRejectsWeakOrMalformed() {
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

    @Test func resolveWithoutOverrideUsesTeamID() {
        let result = C.resolveClientRequirement(environment: ["PATH": "/usr/bin"], teamID: "ABCDE12345")
        #expect(result == .success(ClientRequirement(mode: .teamID,
                                                     requirement: C.clientCodeSigningRequirement(teamID: "ABCDE12345"))))
    }

    @Test func resolveWithValidOverride() throws {
        let req = try #require(C.manualModeClientRequirement(cdhash: Self.hash))
        var teamIDEvaluated = false
        func team() -> String { teamIDEvaluated = true; return "ABCDE12345" }
        let result = C.resolveClientRequirement(environment: [C.clientRequirementEnvironmentKey: req + "\n"], teamID: team())
        #expect(result == .success(ClientRequirement(mode: .manualCDHash(Self.hash), requirement: req)))
        #expect(!teamIDEvaluated, "Team ID lookup (and its placeholder warning) must be skipped in manual mode")
    }

    @Test func resolveWithInvalidOverrideFails() {
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

    @Test func helperRequirementMode() {
        #expect(C.helperRequirementMode(appTeamID: "ABCDE12345", manualInstallDetected: false) == .teamID)
        #expect(C.helperRequirementMode(appTeamID: "ABCDE12345", manualInstallDetected: true) == .manualCDHash)
        #expect(C.helperRequirementMode(appTeamID: nil, manualInstallDetected: false) == .manualCDHash)
        #expect(C.helperRequirementMode(appTeamID: "", manualInstallDetected: false) == .manualCDHash)
    }

    @Test func manualInstallState() {
        #expect(C.manualInstallState(plistExists: true, helperExists: true) == .installed)
        #expect(C.manualInstallState(plistExists: false, helperExists: false) == .absent)
        #expect(C.manualInstallState(plistExists: true, helperExists: false) == .incomplete(missing: C.manualHelperPath))
        #expect(C.manualInstallState(plistExists: false, helperExists: true) == .incomplete(missing: C.manualLaunchDaemonPlistPath))
    }

    @Test func pathsAndTrustAnchorCheck() {
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
@Suite("Manual install scripts match the Swift constants", .tags(.install))
struct ManualInstallScriptConsistencyTests {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Support/manual-install")

    static let supportDir = dir.deletingLastPathComponent()

    @Test func templatePlistMatchesConstants() throws {
        // install.sh rewrites Label, Program and MachServices for the actual identifiers;
        // the template carries the defaults.
        let url = Self.dir.appendingPathComponent("FanControlHelper.manual.plist")
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

    @Test func commonShMatchesConstants() throws {
        let sh = try String(contentsOf: Self.dir.appendingPathComponent("common.sh"), encoding: .utf8)
        // identifiers.sh from the source tree (Support/) or from a flat copy next to common.sh.
        #expect(sh.contains("source \"${FC_LIB_DIR}/identifiers.sh\""))
        #expect(sh.contains("FC_LIB_DIR=\"$(cd \"${SCRIPT_DIR}/..\" && pwd)\""))
        #expect(sh.contains("TEMPLATE=\"${SCRIPT_DIR}/FanControlHelper.manual.plist\""))
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

/// `Support/identifiers.sh`, `Helper-Info.plist` and the checked-in LaunchDaemon plist must agree
/// with `FanControlIdentifiers` (keys, defaults, fallback order).
@Suite("Identifier configuration files match the Swift constants", .tags(.install))
struct IdentifierConfigurationConsistencyTests {
    static let support = ManualInstallScriptConsistencyTests.supportDir
    private typealias I = FanControlIdentifiers
    private typealias K = FanControlIdentifiers.InfoKey

    @Test func identifiersShMatchesSwift() throws {
        let sh = try String(contentsOf: Self.support.appendingPathComponent("identifiers.sh"), encoding: .utf8)
        #expect(sh.contains("DEFAULT_HELPER_ID=\"\(I.defaultHelperIdentifier)\""))
        #expect(sh.contains("DEFAULT_APP_BUNDLE_ID=\"\(I.defaultClientBundleIdentifier)\""))
        for key in K.all {
            #expect(sh.contains("plist_string \"$f\" \(key)"), Comment(rawValue: key))
        }
        // Fallbacks: helper <- Mach service <- default; Mach service <- helper; client <- default.
        #expect(sh.contains("[[ -n \"$helper\" ]] || helper=\"${mach:-$DEFAULT_HELPER_ID}\""))
        #expect(sh.contains("[[ -n \"$mach\" ]] || mach=\"$helper\""))
        #expect(sh.contains("[[ -n \"$client\" ]] || client=\"$DEFAULT_APP_BUNDLE_ID\""))
        let embed = Self.support.appendingPathComponent("embed-helper-config.sh")
        #expect(FileManager.default.isExecutableFile(atPath: embed.path))
    }

    /// Helper-Info.plist carries every key, and resolving it gives the defaults (DynamicNotch).
    @Test func helperInfoPlist() throws {
        let url = Self.support.appendingPathComponent("Helper-Info.plist")
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        for key in K.all {
            #expect(plist[key] is String, Comment(rawValue: key))
        }
        let ids = I(infoDictionary: plist)
        #expect(ids.issues.isEmpty)
        #expect(ids.helperIdentifier == I.defaultHelperIdentifier)
        #expect(ids.machServiceName == I.defaultHelperIdentifier)
        #expect(ids.clientBundleIdentifier == I.defaultClientBundleIdentifier)
        #expect(ids.clientTeamID == FanControlHelperConstants.teamIdentifierPlaceholder)
        #expect(plist["CFBundleIdentifier"] as? String == ids.helperIdentifier)
    }

    /// The checked-in SMAppService plist (copied as-is by DynamicNotchApp) is what
    /// `embed-helper-config.sh` generates from Helper-Info.plist.
    @Test func checkedInLaunchDaemonPlist() throws {
        let ids = I.defaults
        let url = Self.support.appendingPathComponent("LaunchDaemons/\(ids.machServiceName).plist")
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == ids.machServiceName)
        #expect((plist["MachServices"] as? [String: Bool]) == [ids.machServiceName: true])
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [ids.clientBundleIdentifier])
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/\(FanControlHelperConstants.helperExecutableName)")
    }
}
