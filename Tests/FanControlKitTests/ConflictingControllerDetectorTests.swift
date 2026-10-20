#if os(macOS)
import Foundation
import Testing
@testable import FanControlKit

@Suite("Conflicting controller detector", .tags(.manager))
struct ConflictingControllerDetectorTests {

    private func detector(running: Set<String> = [], files: Set<String> = []) -> ConflictingControllerDetector {
        ConflictingControllerDetector(isAppRunning: { running.contains($0) },
                                      fileExists: { files.contains($0) })
    }

    @Test func fanFiIdentifiers() {
        #expect(ConflictingController.fanFi.bundleIdentifiers == ["com.fanfi.fanfi"])
        #expect(ConflictingController.fanFi.helperLabels == ["com.fanfi.fanfi.smcwrite"])
        #expect(ConflictingControllerDetector.helperPaths(label: "com.fanfi.fanfi.smcwrite") == [
            "/Library/LaunchDaemons/com.fanfi.fanfi.smcwrite.plist",
            "/Library/PrivilegedHelperTools/com.fanfi.fanfi.smcwrite",
        ])
    }

    @Test func nothingFound() {
        let statuses = detector().detect()
        #expect(statuses.isEmpty)
        #expect(ConflictingControllerDetector.runningNames(statuses).isEmpty)
    }

    @Test func appRunning() {
        let statuses = detector(running: ["com.fanfi.fanfi"]).detect()
        #expect(statuses == [ConflictingControllerStatus(controller: .fanFi, isAppRunning: true,
                                                          isHelperInstalled: false)])
        #expect(ConflictingControllerDetector.runningNames(statuses) == ["FanFi"])
    }

    /// An installed helper alone is reported but is not a running conflict.
    @Test func helperInstalledOnly() {
        for path in ["/Library/LaunchDaemons/com.fanfi.fanfi.smcwrite.plist",
                     "/Library/PrivilegedHelperTools/com.fanfi.fanfi.smcwrite"] {
            let statuses = detector(files: [path]).detect()
            #expect(statuses == [ConflictingControllerStatus(controller: .fanFi, isAppRunning: false,
                                                              isHelperInstalled: true)])
            #expect(ConflictingControllerDetector.runningNames(statuses).isEmpty)
        }
    }

    /// Our own helper (`com.example.dynamicnotch.DynamicNotch.fanfi`) is not FanFi's.
    @Test func ownHelperIsNotAConflict() {
        let statuses = detector(files: ["/Library/LaunchDaemons/com.example.dynamicnotch.DynamicNotch.fanfi.plist",
                                        "/Library/PrivilegedHelperTools/com.example.dynamicnotch.DynamicNotch.fanfi"])
            .detect()
        #expect(statuses.isEmpty)
    }

    @Test func runningNamesDeduplicatesInOrder() {
        let other = ConflictingController(displayName: "Other", bundleIdentifiers: ["x.other"], helperLabels: [])
        let detector = ConflictingControllerDetector(controllers: [.fanFi, other, .fanFi],
                                                     isAppRunning: { _ in true }, fileExists: { _ in false })
        #expect(ConflictingControllerDetector.runningNames(detector.detect()) == ["FanFi", "Other"])
    }

    @Test func relevantBundleIdentifiers() {
        let detector = detector()
        #expect(detector.isRelevant(bundleIdentifier: "com.fanfi.fanfi"))
        #expect(!detector.isRelevant(bundleIdentifier: "com.apple.Safari"))
        #expect(!detector.isRelevant(bundleIdentifier: nil))
    }
}
#endif
