import Foundation
import Testing
@testable import FanControlXPC

private typealias I = FanControlIdentifiers
private typealias K = FanControlIdentifiers.InfoKey

@Suite("Helper identifiers", .tags(.install))
struct FanControlIdentifiersTests {
    @Test func defaultsWithoutKeys() {
        for info in [nil, [:], ["CFBundleIdentifier": "com.apple.dt.xctest.tool"]] as [[String: Any]?] {
            let ids = I(infoDictionary: info)
            #expect(ids.helperIdentifier == "com.example.dynamicnotch.DynamicNotch.fanfi")
            #expect(ids.machServiceName == ids.helperIdentifier)
            #expect(ids.clientBundleIdentifier == "com.example.dynamicnotch.DynamicNotch")
            #expect(ids.clientTeamID == nil)
            #expect(ids.issues.isEmpty)
            #expect(ids == I.defaults)
        }
    }

    /// The test runner's Info.plist has none of the keys, so the process-wide accessors
    /// fall back to the defaults (which is also what DynamicNotchApp relies on).
    @Test func processAccessorsFallBackToDefaults() {
        #expect(FanControlHelperConstants.machServiceName == I.defaultHelperIdentifier)
        #expect(FanControlHelperConstants.helperIdentifier == I.defaultHelperIdentifier)
        #expect(FanControlHelperConstants.appBundleIdentifier == I.defaultClientBundleIdentifier)
        #expect(FanControlHelperConstants.plistName == "\(I.defaultHelperIdentifier).plist")
        #expect(FanControlHelperConstants.clientTeamID == nil)
    }

    @Test func allKeysSet() {
        let ids = I(infoDictionary: [K.helperIdentifier: "com.acme.Notch.helper",
                                     K.machServiceName: "com.acme.Notch.fan-xpc",
                                     K.clientBundleIdentifier: "com.acme.Notch",
                                     K.clientTeamID: "ABCDE12345"])
        #expect(ids.helperIdentifier == "com.acme.Notch.helper")
        #expect(ids.machServiceName == "com.acme.Notch.fan-xpc")
        #expect(ids.clientBundleIdentifier == "com.acme.Notch")
        #expect(ids.clientTeamID == "ABCDE12345")
        #expect(ids.issues.isEmpty)
        #expect(ids.infoDictionaryRepresentation == [K.helperIdentifier: "com.acme.Notch.helper",
                                                     K.machServiceName: "com.acme.Notch.fan-xpc",
                                                     K.clientBundleIdentifier: "com.acme.Notch",
                                                     K.clientTeamID: "ABCDE12345"])
    }

    /// Helper identifier and Mach service default to each other.
    @Test func helperAndMachServiceFallBackToEachOther() {
        let onlyHelper = I(infoDictionary: [K.helperIdentifier: "com.acme.Notch.helper"])
        #expect(onlyHelper.machServiceName == "com.acme.Notch.helper")
        let onlyMach = I(infoDictionary: [K.machServiceName: "com.acme.Notch.helper"])
        #expect(onlyMach.helperIdentifier == "com.acme.Notch.helper")
        #expect(onlyMach.clientBundleIdentifier == I.defaultClientBundleIdentifier)
        #expect(onlyMach.infoDictionaryRepresentation[K.clientTeamID] == nil)
    }

    @Test func invalidValuesFallBackAndAreReported() {
        let ids = I(infoDictionary: [K.helperIdentifier: "com.acme\" or anchor apple",
                                     K.machServiceName: 42,
                                     K.clientBundleIdentifier: "../etc/passwd",
                                     K.clientTeamID: "abcde12345"])
        #expect(ids == I(infoDictionary: nil).with(issues: ids.issues))
        #expect(ids.issues.count == 4)
        #expect(ids.issues.contains { $0.contains(K.helperIdentifier) })
        #expect(ids.issues.contains { $0.contains(K.machServiceName) })
        #expect(ids.issues.contains { $0.contains(K.clientBundleIdentifier) })
        #expect(ids.issues.contains { $0.contains(K.clientTeamID) })
    }

    @Test func whitespaceTrimmedAndEmptyTeamIDIgnored() {
        let ids = I(infoDictionary: [K.clientBundleIdentifier: "  com.acme.Notch\n", K.clientTeamID: ""])
        #expect(ids.clientBundleIdentifier == "com.acme.Notch")
        #expect(ids.clientTeamID == nil)
        #expect(ids.issues.isEmpty)
    }

    @Test func sameIdentifierForAppAndHelperIsReported() {
        let ids = I(infoDictionary: [K.helperIdentifier: "com.acme.Notch", K.clientBundleIdentifier: "com.acme.Notch"])
        #expect(ids.issues.count == 1)
    }

    @Test func identifierValidation() {
        for good in ["com.acme.Notch", "a", "com.example.dynamicnotch.DynamicNotch.fanfi", "com.acme-corp.x1"] {
            #expect(I.isValidIdentifier(good), Comment(rawValue: good))
        }
        for bad in ["", ".com.acme", "com.acme.", "com..acme", "com acme", "com/acme", "com\"acme", "com.acmé",
                    String(repeating: "a", count: 256)] {
            #expect(!I.isValidIdentifier(bad), Comment(rawValue: bad.debugDescription))
        }
        #expect(I.isValidTeamID("ABCDE12345"))
        #expect(I.isValidTeamID(FanControlHelperConstants.teamIdentifierPlaceholder))
        for bad in ["", "ABCDE1234", "ABCDE123456", "abcde12345", "ABCDE 1234"] {
            #expect(!I.isValidTeamID(bad), Comment(rawValue: bad.debugDescription))
        }
    }

    /// Requirement builders honour explicit identifiers (what a host with its own
    /// Info.plist gets through the defaults).
    @Test func requirementBuildersWithCustomIdentifiers() {
        let hash = ManualInstallModeTests.hash
        let C = FanControlHelperConstants.self
        #expect(C.clientCodeSigningRequirement(teamID: "ABCDE12345", clientBundleIdentifier: "com.acme.Notch")
                == "anchor apple generic and identifier \"com.acme.Notch\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
        #expect(C.helperCodeSigningRequirement(teamID: "ABCDE12345", helperIdentifier: "com.acme.Notch.helper")
                == "anchor apple generic and identifier \"com.acme.Notch.helper\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
        let pinned = C.manualModeClientRequirement(cdhash: hash, clientBundleIdentifier: "com.acme.Notch")
        #expect(pinned == "identifier \"com.acme.Notch\" and cdhash H\"\(hash)\"")
        #expect(C.manualModeHelperRequirement(cdhash: hash, helperIdentifier: "com.acme.Notch.helper")
                == "identifier \"com.acme.Notch.helper\" and cdhash H\"\(hash)\"")
        #expect(C.validateManualClientRequirement(pinned ?? "", clientBundleIdentifier: "com.acme.Notch") == .success(hash))
        // A requirement pinned for another host is refused.
        guard case .failure(.wrongIdentifier) = C.validateManualClientRequirement(pinned ?? "") else {
            Issue.record("a com.acme.Notch requirement must not validate against the default client")
            return
        }
        guard case .success(let resolved) = C.resolveClientRequirement(environment: [:], teamID: "ABCDE12345",
                                                                     clientBundleIdentifier: "com.acme.Notch") else {
            Issue.record("expected the Team-ID requirement")
            return
        }
        #expect(resolved.requirement.contains("identifier \"com.acme.Notch\""))
    }
}

private extension FanControlIdentifiers {
    func with(issues: [String]) -> FanControlIdentifiers {
        var copy = self
        copy.issues = issues
        return copy
    }
}
