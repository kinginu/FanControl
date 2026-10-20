#if os(macOS)
import Foundation
import Testing
import FanControlCore
import FanControlXPC
@testable import FanControlKit

@Suite("Helper installer", .tags(.helper, .install))
struct HelperInstallerTests {
    private static func installer(existing: Set<String>) -> HelperInstaller {
        HelperInstaller(fileExists: { existing.contains($0) }, pinCheck: { .matches })
    }

    private static let both: Set<String> = [FanControlHelperConstants.manualLaunchDaemonPlistPath,
                                            FanControlHelperConstants.manualHelperPath]

    @Test func manualInstallStateFromInjectedProbe() {
        #expect(Self.installer(existing: Self.both).manualInstallState == .installed)
        #expect(Self.installer(existing: []).manualInstallState == .absent)
        #expect(Self.installer(existing: [FanControlHelperConstants.manualHelperPath]).manualInstallState
                == .incomplete(missing: FanControlHelperConstants.manualLaunchDaemonPlistPath))
    }

    @Test func statusDecision() {
        var serviceQueried = false
        func service() -> HelperInstallStatus { serviceQueried = true; return .enabled }
        #expect(HelperInstaller.resolveStatus(manual: .installed, serviceStatus: service()) == .installedManually)
        #expect(!serviceQueried, "a complete manual install never queries SMAppService")
        guard case .unknown(let detail) = HelperInstaller.resolveStatus(
            manual: .incomplete(missing: FanControlHelperConstants.manualHelperPath), serviceStatus: service()) else {
            Issue.record("incomplete manual install must be reported as .unknown")
            return
        }
        #expect(detail.contains(FanControlHelperConstants.manualHelperPath))
        #expect(detail.contains("install.sh"))
        #expect(!serviceQueried, "an incomplete manual install never queries SMAppService")
        #expect(HelperInstaller.resolveStatus(manual: .absent, serviceStatus: .requiresApproval) == .requiresApproval)
        #expect(HelperInstaller.resolveStatus(manual: .absent, serviceStatus: service()) == .enabled)
        #expect(serviceQueried, "without a manual install the SMAppService status decides")
    }

    @Test func statusReportsPinMismatch() throws {
        let pinned = String(repeating: "a", count: 40)
        let own = String(repeating: "b", count: 40)
        #expect(HelperInstaller.resolveStatus(manual: .installed,
                                              pinCheck: .mismatch(pinnedCDHash: pinned, appCDHash: own),
                                              serviceStatus: .enabled)
                == .installedManuallyMismatch(pinnedCDHash: pinned, appCDHash: own))
        #expect(HelperInstaller.resolveStatus(manual: .installed, pinCheck: .matches, serviceStatus: .enabled)
                == .installedManually)
        // Undecidable (e.g. plist unreadable): treated as installed, runtime detection takes over.
        #expect(HelperInstaller.resolveStatus(manual: .installed, pinCheck: .unknown("x"), serviceStatus: .enabled)
                == .installedManually)
        // The pin check only matters for a complete manual install.
        #expect(HelperInstaller.resolveStatus(manual: .absent, pinCheck: .mismatch(pinnedCDHash: pinned, appCDHash: own),
                                              serviceStatus: .enabled) == .enabled)

        let installer = HelperInstaller(fileExists: { Self.both.contains($0) },
                                        pinCheck: { .mismatch(pinnedCDHash: pinned, appCDHash: own) })
        #expect(installer.status() == .installedManuallyMismatch(pinnedCDHash: pinned, appCDHash: own))
        #expect(try installer.register() == .installedManuallyMismatch(pinnedCDHash: pinned, appCDHash: own))
        #expect(installer.status().isManualInstallation)
        #expect(HelperInstallStatus.installedManually.isManualInstallation)
        #expect(!HelperInstallStatus.enabled.isManualInstallation)
    }

    @Test func statusAndRegisterWithManualInstall() throws {
        let installer = Self.installer(existing: Self.both)
        #expect(installer.status() == .installedManually)
        // No SMAppService call: returns the manual status.
        #expect(try installer.register() == .installedManually)
    }

    @Test func registerRefusesIncompleteManualInstall() {
        let installer = Self.installer(existing: [FanControlHelperConstants.manualLaunchDaemonPlistPath])
        #expect(throws: FanControlError.self) { try installer.register() }
    }

    @Test func unregisterRefusesManualInstall() async {
        let installer = Self.installer(existing: Self.both)
        let error = await #expect(throws: FanControlError.self) { try await installer.unregister() }
        guard case .helperConnectionFailed(let reason)? = error else {
            Issue.record("expected .helperConnectionFailed naming uninstall.sh, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("uninstall.sh"))
    }

    @Test func installedHelperCDHashFailsWhenMissing() {
        #expect(throws: FanControlError.self) {
            try ManualHelperSigning.installedHelperCDHash(atPath: "/nonexistent/fanfi-test-helper")
        }
    }

    @Test func installedHelperCDHashRejectsUserOwnedFile() throws {
        // A user-writable copy must never become the trust anchor.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fanfi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("helper")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: copy.path)
        let error = #expect(throws: FanControlError.self, "a user-owned copy must be refused") {
            try ManualHelperSigning.installedHelperCDHash(atPath: copy.path)
        }
        guard case .helperConnectionFailed(let reason)? = error else {
            Issue.record("expected .helperConnectionFailed, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("owned by root"))
    }

    @Test func installedHelperCDHashOfRootOwnedSystemBinary() throws {
        // /usr/bin/true: root-owned, 0755, in a root-owned directory, platform-signed.
        let hash = try ManualHelperSigning.installedHelperCDHash(atPath: "/usr/bin/true")
        #expect(FanControlHelperConstants.isValidCDHash(hash))
        #expect(hash == hash.lowercased())
    }
}
#endif
