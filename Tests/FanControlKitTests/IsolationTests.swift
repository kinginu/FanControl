#if os(macOS)
import Foundation
import Testing
import FanControlCore
@testable import FanControlKit

/// Guards for `Isolated`: the doubles every Kit test builds managers from must never
/// reach the installed FanControlHelper (which would write to the SMC) or `SMAppService`.
@Suite("Test isolation", .tags(.helper, .manager))
struct IsolationTests {

    @Test func isolatedHelperClientNeverReachesTheInstalledHelper() async {
        let client = Isolated.helperClient()
        let error = await #expect(throws: FanControlError.self) { _ = try await client.version() }
        guard case .helperConnectionFailed? = error else {
            Issue.record("the refusing listener must fail the call transiently, got \(String(describing: error))")
            return
        }
        #expect(!client.isSessionOpen)
        await #expect(throws: FanControlError.sessionNotOpen, "no session, so no write is ever sent") {
            try await client.write(key: .fanMode(0), bytes: [1])
        }
    }

    @Test func isolatedInstallerNeverCallsSMAppService() throws {
        let installer = Isolated.installer()
        #expect(installer.manualInstallState == .installed)
        #expect(installer.status() == .installedManually)
        #expect(try installer.register() == .installedManually, "a manual install short-circuits SMAppService")
    }

    @Test @MainActor func isolatedManagerUsesScratchDefaults() {
        let defaults = ScratchDefaults()
        let manager = Isolated.manager(defaults: defaults)
        manager.saveProfile(FanProfile(id: UUID(), name: "Scratch", modes: [0: .constant(rpm: 3000)], isBuiltIn: false))
        #expect(defaults.defaults.data(forKey: FanControlManager.profileStoreDefaultsKey) != nil,
                "the store is persisted to the scratch suite")
        #expect(ScratchDefaults().defaults.data(forKey: FanControlManager.profileStoreDefaultsKey) == nil,
                "another scratch suite starts empty")
        #expect(!manager.isMonitoring)
    }
}
#endif
