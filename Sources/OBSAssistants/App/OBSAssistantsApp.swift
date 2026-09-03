import SwiftUI

@main
struct OBSAssistantsApp: App {
    @StateObject private var appState: AppState
    // Independent feature, independent state — starts its own Music.app
    // poller and HTTP server (own port) right away, same "just works at
    // launch" behavior as the printer overlay below. See NowPlayingState.
    @StateObject private var nowPlayingState = NowPlayingState()

    init() {
        // Unbuffered stdout so `print()` diagnostics (discovery, etc.) show
        // up immediately when tailing a redirected log, instead of sitting
        // in a block buffer until the process exits.
        setvbuf(stdout, nil, _IONBF, 0)

        if ProcessInfo.processInfo.environment["OA_SCAN_TEST"] != nil {
            print("[ScanTest] scanning local subnet for port 8883...")
            LanCertificateScanner().scan { found in
                print("[ScanTest] found \(found.count): \(found.map { "\($0.serial)@\($0.ip)" })")
                exit(0)
            }
        }

        // Diagnostic-only: exercises the exact same Keychain save+read path
        // the UI uses for the Access Code, without needing to click through
        // the popover. `OA_KEYCHAIN_TEST=write:<value>` saves it (isolated
        // to the .testing account, same as OA_TEST_PAYLOAD does for
        // UserDefaults); `OA_KEYCHAIN_TEST=read` reads it back and prints
        // what it got. See README "Testing without hardware".
        if let mode = ProcessInfo.processInfo.environment["OA_KEYCHAIN_TEST"] {
            let settings = AppSettings.shared
            if mode.hasPrefix("write:") {
                let value = String(mode.dropFirst("write:".count))
                settings.accessCode = value
                print("[KeychainTest] wrote accessCode (\(value.count) chars)")
            } else {
                print("[KeychainTest] read accessCode: \(settings.accessCode.isEmpty ? "EMPTY" : "\(settings.accessCode.count) chars, value=\(settings.accessCode)")")
            }
            exit(0)
        }

        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        // None of the three overlay HTTP servers (printer, Bambu Studio, Now
        // Playing) auto-start anymore — they come up stopped, and the user
        // starts whichever one(s) they actually want from the menu's
        // "Servidores" section. The MQTT connection to the printer is a
        // separate concern and keeps auto-connecting below when already
        // configured.
        Task { @MainActor in
            // Diagnostic-only, real hardware: `OA_DRY_TEST=<amsID>:<filamentType>:<tempC>:<hours>`
            // connects normally (real printer, real Access Code) and, once
            // connected, sends exactly one real ams_filament_drying command
            // with the given values — used to test the corrected
            // dry_filament/dry_temperature/dry_duration field names against
            // real hardware without going through the notification/UI flow.
            if ProcessInfo.processInfo.environment["OA_SNIFF_REQUESTS"] == "1" {
                // Passive-only: subscribes to device/<serial>/request in
                // addition to /report and just logs whatever any MQTT
                // client (including the official Bambu Handy/Studio app,
                // if it's connected to the same local broker) publishes
                // there. Never sends a command itself. See README/AMS
                // drying notes for why — no public documentation exists
                // for ams_filament_drying, so this captures ground truth
                // instead of guessing field names further.
                print("[Sniff] OA_SNIFF_REQUESTS=1 — will passively log any MQTT publish on device/<serial>/request, no commands will be sent")
                state.enableRequestTopicSniff()
                state.connectPrinter()
            } else if let spec = ProcessInfo.processInfo.environment["OA_DRY_TEST"] {
                let parts = spec.split(separator: ":").map(String.init)
                if parts.count == 4, let amsID = Int(parts[0]), let tempC = Double(parts[2]), let hours = Double(parts[3]) {
                    state.connectPrinter()
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await MainActor.run {
                            print("[DryTest] sending: AMS \(amsID), \(parts[1]), \(tempC)°C, \(hours)h")
                            state.sendDryingCommandForTest(amsID: amsID, filamentType: parts[1], tempC: tempC, durationHours: hours)
                        }
                    }
                }
            } else if let amsIDString = ProcessInfo.processInfo.environment["OA_DRY_STOP_TEST"], let amsID = Int(amsIDString) {
                // Diagnostic-only, real hardware: connects and sends exactly
                // one real stop (mode 0) command to the given AMS unit —
                // used to test the stop path against a cycle that's
                // actually running (started via the official app).
                state.connectPrinter()
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run {
                        print("[DryStopTest] stopping AMS \(amsID)")
                        state.stopDrying(amsID: amsID)
                    }
                }
            } else if ProcessInfo.processInfo.environment["OA_PRINT_AMS_STATUS"] == "1" {
                // Diagnostic-only, real hardware: connects and prints every
                // AMS slot's real detected filament type/humidity/active-
                // drying status as reports come in (every ~2s, for ~80s,
                // then exits) — used to find the real amsID/filamentType to
                // pass to OA_DRY_TEST instead of guessing at values that
                // don't match what's actually loaded on the printer.
                state.connectPrinter()
                Task {
                    for _ in 0..<40 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run {
                            if state.amsSlots.isEmpty {
                                print("[AMSStatus] no AMS data yet (status: \(state.connectionStatus))")
                            }
                            for slot in state.amsSlots {
                                let humidityStr = slot.humidityPercent != nil ? "\(slot.humidityPercent!)" : "n/a"
                                let indexStr = slot.humidityIndex != nil ? "\(slot.humidityIndex!)" : "n/a"
                                let tempStr = slot.chamberTemperatureC != nil ? "\(slot.chamberTemperatureC!)" : "n/a"
                                print("[AMSStatus] ams=\(slot.amsID) tray=\(slot.trayIndex) filament=\(slot.filamentTypeDisplay) loaded=\(slot.hasFilamentLoaded) humidity%=\(humidityStr) humidityIndex=\(indexStr) activeDrying=\(String(describing: slot.activeDrying)) chamberTempC=\(tempStr)")
                            }
                        }
                    }
                    exit(0)
                }
            } else if let testPayloadPath = ProcessInfo.processInfo.environment["OA_TEST_PAYLOAD"] {
                // Dry-run mode: replay a captured report instead of connecting
                // to a real printer. See README "Testing without hardware".
                // Comma-separate multiple file paths to replay them in
                // sequence (each merges into the running snapshot, same as
                // consecutive real MQTT messages would) — useful for
                // testing that a later partial update doesn't clobber a
                // field an earlier one set (see PrinterReportStore.deepMerge).
                for path in testPayloadPath.split(separator: ",").map(String.init) {
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        state.injectTestPayload(json)
                    }
                }
            } else if state.settings.isConfigured {
                state.connectPrinter()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appState)
                .environmentObject(nowPlayingState)
        } label: {
            Image(systemName: statusIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var statusIcon: String {
        switch appState.connectionStatus {
        case .connectedPrimary, .connectedFallback: return "printer.fill"
        case .connecting: return "printer.dotmatrix"
        case .failed: return "exclamationmark.triangle.fill"
        case .disconnected: return "printer"
        }
    }
}
