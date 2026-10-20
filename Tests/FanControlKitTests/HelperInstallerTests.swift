#if os(macOS)
import Foundation
import Testing
import FanControlCore
import FanControlXPC
@testable import FanControlKit

struct HelperInstallerTests {
    private static func installer(existing: Set<String>) -> HelperInstaller {
        HelperInstaller(fileExists: { existing.contains($0) })
    }

    private static let both: Set<String> = [FanControlHelperConstants.manualLaunchDaemonPlistPath,
                                            FanControlHelperConstants.manualHelperPath]

    @Test func testManualInstallStateFromInjectedProbe() {
        #expect(Self.installer(existing: Self.both).manualInstallState == .installed)
        #expect(Self.installer(existing: []).manualInstallState == .absent)
        #expect(Self.installer(existing: [FanControlHelperConstants.manualHelperPath]).manualInstallState
                == .incomplete(missing: FanControlHelperConstants.manualLaunchDaemonPlistPath))
    }

    @Test func testStatusDecision() {
        var serviceQueried = false
        func service() -> HelperInstallStatus { serviceQueried = true; return .enabled }
        #expect(HelperInstaller.resolveStatus(manual: .installed, serviceStatus: service()) == .installedManually)
        #expect(!serviceQueried)
        guard case .unknown(let detail) = HelperInstaller.resolveStatus(
            manual: .incomplete(missing: FanControlHelperConstants.manualHelperPath), serviceStatus: service()) else {
            Issue.record("incomplete manual install must be reported as .unknown")
            return
        }
        #expect(detail.contains(FanControlHelperConstants.manualHelperPath))
        #expect(detail.contains("install.sh"))
        #expect(!serviceQueried)
        #expect(HelperInstaller.resolveStatus(manual: .absent, serviceStatus: .requiresApproval) == .requiresApproval)
        #expect(HelperInstaller.resolveStatus(manual: .absent, serviceStatus: service()) == .enabled)
        #expect(serviceQueried)
    }

    @Test func testStatusAndRegisterWithManualInstall() throws {
        let installer = Self.installer(existing: Self.both)
        #expect(installer.status() == .installedManually)
        // No SMAppService call: returns the manual status.
        #expect(try installer.register() == .installedManually)
    }

    @Test func testRegisterRefusesIncompleteManualInstall() {
        let installer = Self.installer(existing: [FanControlHelperConstants.manualLaunchDaemonPlistPath])
        #expect(throws: FanControlError.self) { try installer.register() }
    }

    @Test func testUnregisterRefusesManualInstall() async {
        let installer = Self.installer(existing: Self.both)
        await #expect(throws: FanControlError.self) { try await installer.unregister() }
        do {
            try await installer.unregister()
        } catch let FanControlError.helperConnectionFailed(reason) {
            #expect(reason.contains("uninstall.sh"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func testInstalledHelperCDHashFailsWhenMissing() {
        #expect(throws: FanControlError.self) {
            try ManualHelperSigning.installedHelperCDHash(atPath: "/nonexistent/fanfi-test-helper")
        }
    }

    @Test func testInstalledHelperCDHashRejectsUserOwnedFile() throws {
        // A user-writable copy must never become the trust anchor.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fanfi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("helper")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: copy.path)
        do {
            _ = try ManualHelperSigning.installedHelperCDHash(atPath: copy.path)
            Issue.record("user-owned file accepted")
        } catch let FanControlError.helperConnectionFailed(reason) {
            #expect(reason.contains("owned by root"))
        }
    }

    @Test func testInstalledHelperCDHashOfRootOwnedSystemBinary() throws {
        // /usr/bin/true: root-owned, 0755, in a root-owned directory, platform-signed.
        let hash = try ManualHelperSigning.installedHelperCDHash(atPath: "/usr/bin/true")
        #expect(FanControlHelperConstants.isValidCDHash(hash))
        #expect(hash == hash.lowercased())
    }
}
#endif
