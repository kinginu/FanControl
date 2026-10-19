import SwiftUI
import FanControlCore
import FanControlKit

/// Minimal app used only to validate the helper embedding recipe (README.md).
/// The buttons call the real APIs but are not meant to be clicked during the build-only check.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HelperInstaller.status(): \(String(describing: installerStatus))")
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
                Button("Refresh status") { installerStatus = HelperInstaller().status() }
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
    }
}
