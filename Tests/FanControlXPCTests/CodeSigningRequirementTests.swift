import Foundation
import Testing
@testable import FanControlXPC
#if os(macOS)
import Security
#endif

private typealias C = FanControlHelperConstants
private typealias R = CodeSigningRequirement

/// Table tests for the requirement strings both install paths enforce
/// (`CodeSigningRequirement`, `SigningPin`) and their fail-closed behaviour.
struct CodeSigningRequirementTests {
    static let hash = "0123456789abcdef0123456789abcdef01234567"
    static let team = "ABCDE12345"

    /// Values that must never reach a requirement string: each one would change its
    /// meaning (quote / clause injection) or is simply not a reverse-DNS identifier.
    static let invalidIdentifiers: [String] = [
        "", " ", ".", "a..b", ".a", "a.", "a b", "a/b", "a\"b", "a\\b", "a\nb", "é.app",
        "com.example\" or always or identifier \"x",
        "com.example.DynamicNotch\" and cdhash H\"\(hash)",
        String(repeating: "a", count: 256),
    ]
    static let invalidTeamIDs: [String] = [
        "", "ABCDE1234", "ABCDE123456", "abcde12345", "ABCDE 1234", "ABCDE-1234",
        "ABCDE1234\"", "\" or always", "ＡBCDE12345",
    ]
    static let invalidCDHashes: [String] = [
        "", "0123", String(hash.dropLast()), hash + "0", "g" + hash.dropFirst(),
        " " + hash.dropFirst(), "0x" + hash.dropFirst(2), String(repeating: "\u{FF10}", count: 40),
        String(hash.dropLast()) + "\"",
    ]

    // MARK: Builders

    @Test(arguments: [
        ("com.example.dynamicnotch.DynamicNotch", "ABCDE12345"),
        ("com.acme.Notch.helper", "Z9Y8X7W6V5"),
        ("a", "0000000000"),
    ])
    func teamPinnedFormat(identifier: String, teamID: String) {
        let expected = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        #expect(R.teamPinned(identifier: identifier, teamID: teamID) == expected)
        #expect(R.make(identifier: identifier, pin: .teamID(teamID)) == expected)
    }

    @Test(arguments: [
        ("com.example.dynamicnotch.DynamicNotch", hash, hash),
        ("com.acme.Notch", hash.uppercased(), hash),
        ("x-y.z", String(repeating: "Ab", count: 20), String(repeating: "ab", count: 20)),
    ])
    func cdhashPinnedFormatIsCanonical(identifier: String, cdhash: String, canonical: String) {
        let expected = "identifier \"\(identifier)\" and cdhash H\"\(canonical)\""
        #expect(R.cdhashPinned(identifier: identifier, cdhash: cdhash) == expected)
        #expect(R.make(identifier: identifier, pin: .cdhash(cdhash)) == expected)
        // Round trip through the strict parser.
        #expect(R.parseCDHashPinned(expected, identifier: identifier) == .success(canonical))
    }

    @Test(arguments: invalidIdentifiers)
    func invalidIdentifierBuildsNothing(identifier: String) {
        #expect(R.teamPinned(identifier: identifier, teamID: Self.team) == nil)
        #expect(R.cdhashPinned(identifier: identifier, cdhash: Self.hash) == nil)
        #expect(C.manualModeClientRequirement(cdhash: Self.hash, clientBundleIdentifier: identifier) == nil)
        #expect(C.manualModeHelperRequirement(cdhash: Self.hash, helperIdentifier: identifier) == nil)
        // The String-returning Team-ID builders fail closed.
        #expect(C.clientCodeSigningRequirement(teamID: Self.team, clientBundleIdentifier: identifier) == R.never)
        #expect(C.helperCodeSigningRequirement(teamID: Self.team, helperIdentifier: identifier) == R.never)
        // And nothing validates against an invalid identifier.
        let forged = "identifier \"\(identifier)\" and cdhash H\"\(Self.hash)\""
        guard case .failure = R.parseCDHashPinned(forged, identifier: identifier) else {
            Issue.record("parsed a requirement for invalid identifier \(identifier.debugDescription)")
            return
        }
    }

    @Test(arguments: invalidTeamIDs)
    func invalidTeamIDFailsClosed(teamID: String) {
        #expect(R.teamPinned(identifier: "com.acme.Notch", teamID: teamID) == nil)
        #expect(R.make(identifier: "com.acme.Notch", pin: .teamID(teamID)) == nil)
        #expect(C.clientCodeSigningRequirement(teamID: teamID) == R.never)
        #expect(C.helperCodeSigningRequirement(teamID: teamID) == R.never)
        // Without an override the helper then enforces `never` (rejects every client).
        #expect(C.resolveClientRequirement(environment: [:], teamID: teamID)
                == .success(ClientRequirement(mode: .teamID, requirement: R.never)))
        // The app does not pick the Team-ID path for a malformed Team ID.
        #expect(C.helperRequirementMode(appTeamID: teamID, manualInstallDetected: false) == .manualCDHash)
    }

    @Test(arguments: invalidCDHashes)
    func invalidCDHashBuildsNothing(cdhash: String) {
        #expect(!C.isValidCDHash(cdhash))
        #expect(C.normalizedCDHash(cdhash) == nil)
        #expect(R.cdhashPinned(identifier: "com.acme.Notch", cdhash: cdhash) == nil)
        #expect(R.make(identifier: "com.acme.Notch", pin: .cdhash(cdhash)) == nil)
        #expect(C.manualModeClientRequirement(cdhash: cdhash) == nil)
        #expect(C.manualModeHelperRequirement(cdhash: cdhash) == nil)
        #expect(C.manualClientPinCheck(pinnedRequirement: C.manualModeClientRequirement(cdhash: Self.hash),
                                       appCDHash: cdhash) == .unknown("the app's own cdhash is not available"))
    }

    @Test func placeholderTeamIDIsWellFormed() {
        // The placeholder must build a (never-satisfied) Team-ID requirement, not `never`,
        // so its log line still names the identifier being pinned.
        #expect(FanControlIdentifiers.isValidTeamID(C.teamIdentifierPlaceholder))
        #expect(C.clientCodeSigningRequirement(teamID: C.teamIdentifierPlaceholder).hasSuffix("= \"TEAMID0000\""))
    }

    // MARK: Parser

    /// `(input, expected)`; `id` is the default client identifier.
    static let parseTable: [(String, Result<String, ManualRequirementError>)] = {
        let id = "identifier \"com.example.dynamicnotch.DynamicNotch\""
        let ok = "\(id) and cdhash H\"\(hash)\""
        return [
            (ok, .success(hash)),
            ("\t\(ok) \n", .success(hash)),
            ("\(id) and cdhash H\"\(hash.uppercased())\"", .success(hash)),
            ("", .failure(.empty)),
            (" \n", .failure(.empty)),
            (id, .failure(.wrongIdentifier(id))),
            ("cdhash H\"\(hash)\"", .failure(.wrongIdentifier("cdhash H\"\(hash)\""))),
            ("identifier \"com.example.dynamicnotch.DynamicNotch.fanfi\" and cdhash H\"\(hash)\"",
             .failure(.wrongIdentifier("identifier \"com.example.dynamicnotch.DynamicNotch.fanfi\" and cdhash H\"\(hash)\""))),
            ("\(id) and anchor apple", .failure(.missingCDHash("\(id) and anchor apple"))),
            ("\(id) or cdhash H\"\(hash)\"", .failure(.malformed("\(id) or cdhash H\"\(hash)\""))),
            ("\(ok) or always", .failure(.malformed("\(ok) or always"))),
            ("\(ok)\"", .failure(.malformed("\(ok)\""))),
            ("\(id) and  cdhash H\"\(hash)\"", .failure(.malformed("\(id) and  cdhash H\"\(hash)\""))),
            ("\(id) and cdhash H\"\(hash.dropLast())\"", .failure(.malformed("\(id) and cdhash H\"\(hash.dropLast())\""))),
            ("\(id) and cdhash H\"\(String(repeating: "z", count: 40))\"",
             .failure(.invalidCDHash(String(repeating: "z", count: 40)))),
        ]
    }()

    @Test func parserTable() {
        for (input, expected) in Self.parseTable {
            #expect(C.validateManualClientRequirement(input) == expected, Comment(rawValue: input.debugDescription))
        }
    }

    @Test func overrideIsEnforcedInCanonicalForm() throws {
        let upper = "  identifier \"\(C.appBundleIdentifier)\" and cdhash H\"\(Self.hash.uppercased())\"\n"
        let canonical = try #require(C.manualModeClientRequirement(cdhash: Self.hash))
        #expect(C.resolveClientRequirement(environment: [C.clientRequirementEnvironmentKey: upper], teamID: Self.team)
                == .success(ClientRequirement(mode: .manualCDHash(Self.hash), requirement: canonical)))
    }

    @Test func pinCheckHonoursCustomClientIdentifier() throws {
        let pinned = try #require(C.manualModeClientRequirement(cdhash: Self.hash, clientBundleIdentifier: "com.acme.Notch"))
        #expect(C.manualClientPinCheck(pinnedRequirement: pinned, appCDHash: Self.hash,
                                       clientBundleIdentifier: "com.acme.Notch") == .matches)
        // Against the default client the same pin is not this app's: undecidable, never a mismatch.
        guard case .unknown = C.manualClientPinCheck(pinnedRequirement: pinned, appCDHash: Self.hash) else {
            Issue.record("a requirement for another identifier must not be reported as matching")
            return
        }
    }

    #if os(macOS)
    /// Everything the builders can return compiles with the Security framework (what
    /// `setCodeSigningRequirement` and the helper's start-up check do).
    @Test func buildersProduceCompilableRequirements() throws {
        let built: [String] = [
            R.never,
            C.clientCodeSigningRequirement(teamID: Self.team),
            C.helperCodeSigningRequirement(teamID: C.teamIdentifierPlaceholder),
            try #require(C.manualModeClientRequirement(cdhash: Self.hash)),
            try #require(C.manualModeHelperRequirement(cdhash: Self.hash.uppercased())),
        ]
        for requirement in built {
            var compiled: SecRequirement?
            let status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
            #expect(status == errSecSuccess && compiled != nil, Comment(rawValue: requirement))
        }
    }
    #endif
}

/// The XPC wire contract (`FanControlHelperProtocol`, protocol version 2; F1: charge limit).
struct HelperWireContractTests {
    @Test func protocolVersion() {
        // Bumping it requires updating the history table in FanControlHelperProtocol.swift.
        #expect(C.protocolVersion == 2)  // F1: v2 adds setChargeLimitEnabled
    }

    @Test func errorCodeRawValuesAreStable() {
        let expected: [FanControlHelperErrorCode: Int] = [
            .ok: 0, .notSessionOwner: 1, .sessionNotOpen: 2, .invalidKey: 3,
            .keyNotAllowed: 4, .smcUnavailable: 5, .smcError: 6, .badRequest: 7,
        ]
        #expect(FanControlHelperErrorCode.allCases.count == expected.count)
        for code in FanControlHelperErrorCode.allCases {
            #expect(code.rawValue == expected[code], Comment(rawValue: code.description))
        }
        #expect(FanControlHelperErrorCode(rawValue: 8) == nil)
        #expect(FanControlHelperErrorCode(rawValue: -1) == nil)
        #expect(FanControlHelperErrorCode.badRequest.description == "badRequest")
    }

    #if os(macOS)
    @Test func selectorsArePinned() {
        let proto: Protocol = FanControlHelperProtocol.self
        let selectors = ["versionWithReply:", "openSessionWithReply:", "writeKey:bytes:reply:",
                         "closeSessionWithReply:", "readKeyInfo:reply:",
                         "setChargeLimitEnabled:reply:"]  // F1: protocol v2
        for name in selectors {
            let method = protocol_getMethodDescription(proto, NSSelectorFromString(name), true, true)
            #expect(method.name != nil, Comment(rawValue: name))
        }
        var count: UInt32 = 0
        let all = protocol_copyMethodDescriptionList(proto, true, true, &count)
        free(all)
        #expect(Int(count) == selectors.count, "a new method needs a protocolVersion bump and a test entry")
        #expect(makeHelperInterface().protocol === proto)
    }
    #endif

    @Test func allowlistIsExactlyModeAndTargetOfSingleDigitFans() {
        var allowed: [String] = []
        let ascii = (0x20...0x7E).map { Character(Unicode.Scalar(UInt8($0))) }
        for second in ascii {
            for suffix in ["Tg", "Md", "Mn", "Mx", "Ac", "tg", "TG", "St"] {
                let key = "F\(second)\(suffix)"
                if C.isWriteAllowed(key: key) { allowed.append(key) }
            }
        }
        let expected = (0...9).flatMap { ["F\($0)Tg", "F\($0)Md"] }
        #expect(allowed.sorted() == expected.sorted())
    }
}
