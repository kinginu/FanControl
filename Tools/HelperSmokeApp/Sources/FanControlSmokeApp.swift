import SwiftUI
import FanControlCore
import FanControlKit

/// Minimal app used to validate the helper embedding recipe and the manual-install
/// (personal) mode (README.md). The buttons call the real APIs; "Helper version" only
/// does the XPC `version` call (no SMC write). "Install helper" is a no-op for a
/// manual installation (`HelperInstaller.register()` returns `.installedManually`).
@main
struct FanControlSmokeApp: App {
    var body: some Scene {
        MenuBarExtra("FanControlSmoke", systemImage: "fan") {
            MenuContent()
        }
        Window("FanControlSmoke", id: "main") {
            SmokeView()
        }
    }
}

struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

struct SmokeView: View {
    @State private var manager = FanControlManager.shared
    @State private var installerStatus: HelperInstallStatus = HelperInstaller().status()
    @State private var message = ""
    @State private var confirmFirstWrite = false
    @State private var confirmSixThousand = false
    @State private var confirmSensorLinked = false
    @State private var confirmLowThreshold = false
    @State private var tick = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Fixed id so repeated applies replace one stored profile (applyProfile persists user profiles).
    static let smokeProfileID = UUID(uuidString: "6F1A0000-0000-4000-8000-000000005AFE")!
    static let aggKey = "agg:cpu"

    static func sensorLinkedProfile(fans: [FanDevice]) -> FanProfile {
        var modes: [Int: FanControlMode] = [:]
        for fan in fans { modes[fan.id] = .sensor(sensorKey: aggKey, startTemperature: 45, maxTemperature: 75) }
        return FanProfile(id: smokeProfileID, name: "Smoke sensor-linked", modes: modes)
    }

    static func modeText(_ mode: FanControlMode?) -> String {
        switch mode {
        case nil, .automatic?: return "automatic"
        case .constant(let rpm)?: return "constant \(rpm)"
        case .sensor(let key, let lo, let hi)?: return "sensor \(key) \(Int(lo))→\(Int(hi)) °C"
        }
    }

    var liveStatus: String {
        _ = tick
        var lines: [String] = []
        lines.append("monitoring: \(manager.isMonitoring) (paused: \(manager.isMonitoringPaused)) · SMC: \(manager.isSMCConnected) · helper: \(String(describing: manager.helperConnectionState)) · write session: \(manager.isSMCWriteSessionOpen ? "open" : "closed")")
        for fan in manager.fans {
            lines.append("\(fan.name): current \(manager.currentRPMs[fan.id] ?? -1) / target \(manager.targetRPMs[fan.id].map(String.init) ?? "-") RPM · mode \(Self.modeText(manager.fanControlModes[fan.id]))")
        }
        let agg = manager.sensorReadings.first { $0.id == Self.aggKey }
        lines.append("agg:cpu: \(agg.map { String(format: "%.1f °C", $0.temperature) } ?? "n/a") · active profile: \(manager.activeProfile?.name ?? "-")")
        let hot = manager.hottestSensor
        lines.append("hottest emergency sensor: \(hot.map { String(format: "%@ %.1f °C", $0.id, $0.temperature) } ?? "n/a")")
        let p = manager.safetyPolicy
        lines.append("policy: emergency \(p.emergencyTemperature) / alert \(p.highTemperatureAlert) (hyst \(p.alertHysteresis)) · emergencyOverrideActive: \(manager.emergencyOverrideActive) · highTempAlertActive: \(manager.highTempAlertActive)")
        lines.append("lastError: \(manager.lastError.map { "\($0)" } ?? "none")")
        return lines.joined(separator: "\n")
    }
    @State private var requirementSummary = Self.describeRequirementMode()

    /// Which requirement `HelperClient` will put on the helper connection (manual-install mode:
    /// ad-hoc app or install.sh installation → cdhash of /Library/PrivilegedHelperTools/<label>).
    static func describeRequirementMode() -> String {
        let team = HelperInstaller.appTeamIdentifier ?? "none (ad-hoc)"
        switch HelperClient.currentRequirementMode() {
        case .teamID:
            return "Team ID (SMAppService) · app team \(team)"
        case .manualCDHash:
            let pinned: String
            do { pinned = try HelperInstaller.installedManualHelperCDHash() } catch { pinned = "unavailable: \(error)" }
            let pin: String
            switch HelperInstaller.manualClientPinCheck() {
            case .matches: pin = "plist pins this app"
            case .mismatch(let pinnedApp, let app): pin = "plist pins ANOTHER app build \(pinnedApp) (this app \(app)) → re-run sudo install.sh <this app>"
            case .unknown(let detail): pin = "pin check unknown (\(detail))"
            }
            return "manual (cdhash) · app team \(team) · helper cdhash \(pinned) · \(pin)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HelperInstaller.status(): \(String(describing: installerStatus))")
            Text("Helper requirement mode: \(requirementSummary)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text("SMC connected: \(manager.isSMCConnected ? "yes" : "no") · helper: \(String(describing: manager.helperConnectionState))")
            if case .rejected(let reason) = manager.helperConnectionState {
                // Sticky: HelperClient does not reconnect until "Check again" or a reinstall.
                Text("Helper REJECTED this app (no automatic retry): \(reason.description)")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Divider()
            ForEach(manager.fans) { fan in
                Text("\(fan.name): \(manager.currentRPMs[fan.id] ?? 0) RPM (\(fan.minRPM)–\(fan.maxRPM))")
            }
            Text(liveStatus)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            List(manager.sensorReadings) { reading in
                Text(String(format: "%@  %@  %.1f °C", reading.id, reading.name, reading.temperature))
                    .font(.system(.caption, design: .monospaced))
            }
            .frame(minHeight: 200)
            HStack {
                Button("Refresh status") {
                    installerStatus = HelperInstaller().status()
                    requirementSummary = Self.describeRequirementMode()
                }
                Button("Helper version") {
                    Task {
                        await run {
                            let client = HelperClient()
                            client.clientTeamID = manager.clientTeamID
                            defer { client.invalidate() }
                            let (proto, build) = try await client.version()
                            message = "helper protocol \(proto), build \(build)"
                        }
                    }
                }
                Button("Check again") {
                    // Resets the rejection / backoff and probes with version() (read-only).
                    Task { await run { try await manager.retryHelperConnection() } }
                }
                Button("Install helper") {
                    Task { await run { try await manager.installHelper() } }
                }
                // Phase 4 first write (pre-write-review 2026-10-20「初回書込の手順」step 3):
                // Fan 1 (F0) only, constant 3000 RPM; Fan 2 stays automatic. Confirmed first.
                Button("Fan 1 → 3000 RPM…") { confirmFirstWrite = true }
                    .confirmationDialog("Write to the SMC?", isPresented: $confirmFirstWrite) {
                        Button("Write F0Md = 1, F0Tg = 3000", role: .destructive) {
                            Task { await run { try await manager.setFanRPM(fanIndex: 0, rpm: 3000) } }
                        }
                    } message: {
                        Text("Only after fanfi-probe --watch 1 and the helper log are running and \"Restore automatic\" was checked (pre-write-review「初回書込の手順」).")
                    }
                // Every fan, constant 6000 RPM (near F<n>Mx 6800). Confirmed first.
                Button("All fans → 6000 RPM…") { confirmSixThousand = true }
                    .confirmationDialog("Write to the SMC?", isPresented: $confirmSixThousand) {
                        Button("Write F<n>Md = 1, F<n>Tg = 6000 for every fan", role: .destructive) {
                            Task {
                                await run {
                                    for (index, _) in manager.fans.enumerated() {
                                        try await manager.setFanRPM(fanIndex: index, rpm: 6000)
                                    }
                                }
                            }
                        }
                    } message: {
                        Text("Loud. Use \"Restore automatic\" to hand control back to the SMC.")
                    }
                Button("Apply sensor-linked (agg:cpu 45→75 °C)…") { confirmSensorLinked = true }
                    .confirmationDialog("Write to the SMC?", isPresented: $confirmSensorLinked) {
                        Button("Apply \"Smoke sensor-linked\" to every fan", role: .destructive) {
                            Task {
                                await run {
                                    manager.startMonitoring()
                                    try await manager.applyProfile(Self.sensorLinkedProfile(fans: manager.fans))
                                }
                            }
                        }
                    } message: {
                        Text("All fans follow agg:cpu 45→75 °C (polling keeps updating the target). Stores a temporary user profile \"Smoke sensor-linked\"; removed by \"Restore automatic\".")
                    }
                Button("Emergency test: set threshold to 55 °C…") { confirmLowThreshold = true }
                    .confirmationDialog("Lower the emergency threshold?", isPresented: $confirmLowThreshold) {
                        Button("emergency 55 °C, alert 50 °C", role: .destructive) {
                            manager.safetyPolicy.emergencyTemperature = 55
                            manager.safetyPolicy.highTemperatureAlert = 50
                            message = "thresholds lowered (in memory only); with an open session all fans go to max"
                        }
                    } message: {
                        Text("If a write session is open and a CPU/GPU sensor is above 55 °C, all fans are forced to maximum. Use \"restore default thresholds\" afterwards.")
                    }
                Button("Emergency test: restore default thresholds") {
                    manager.safetyPolicy.emergencyTemperature = FanControlPlatform.defaultSafetyPolicy.emergencyTemperature
                    manager.safetyPolicy.highTemperatureAlert = FanControlPlatform.defaultSafetyPolicy.highTemperatureAlert
                    manager.safetyPolicy.alertHysteresis = FanControlPlatform.defaultSafetyPolicy.alertHysteresis
                    message = "thresholds restored"
                }
                Button("Apply first profile") {
                    Task {
                        guard let profile = manager.availableProfiles.first else { return }
                        await run { try await manager.applyProfile(profile) }
                    }
                }
                Button("Restore automatic") {
                    Task {
                        await run {
                            try await manager.restoreDefaultControl()
                            if manager.profileStore.profiles.contains(where: { $0.id == Self.smokeProfileID }) {
                                manager.deleteProfile(FanProfile(id: Self.smokeProfileID, name: "Smoke sensor-linked"))
                            }
                        }
                    }
                }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { manager.startMonitoring() }
        .onReceive(ticker) { tick = $0 }
    }

    @MainActor
    private func run(_ action: () async throws -> Void) async {
        message = ""
        do { try await action(); if message.isEmpty { message = "OK" } } catch { message = "\(error)" }
        installerStatus = HelperInstaller().status()
        requirementSummary = Self.describeRequirementMode()
    }
}
