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
            return "manual (cdhash) · app team \(team) · helper cdhash \(pinned)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HelperInstaller.status(): \(String(describing: installerStatus))")
            Text("Helper requirement mode: \(requirementSummary)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text("SMC connected: \(manager.isSMCConnected ? "yes" : "no") · helper: \(String(describing: manager.helperConnectionState))")
            Divider()
            ForEach(manager.fans) { fan in
                Text("\(fan.name): \(manager.currentRPMs[fan.id] ?? 0) RPM (\(fan.minRPM)–\(fan.maxRPM))")
            }
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
                Button("Apply first profile") {
                    Task {
                        guard let profile = manager.availableProfiles.first else { return }
                        await run { try await manager.applyProfile(profile) }
                    }
                }
                Button("Restore automatic") {
                    Task { await run { try await manager.restoreDefaultControl() } }
                }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { manager.startMonitoring() }
    }

    @MainActor
    private func run(_ action: () async throws -> Void) async {
        message = ""
        do { try await action(); if message.isEmpty { message = "OK" } } catch { message = "\(error)" }
        installerStatus = HelperInstaller().status()
        requirementSummary = Self.describeRequirementMode()
    }
}
