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

        // Diagnostic-only: inspects the real internal structure of the
        // newest .3mf in the configured Studio project folder — lists every
        // ZIP member, then dumps stats + a preview of any Metadata/plate_*.gcode
        // found, so the toolpath-preview overlay (4th "Servidores" row, in
        // progress) gets built against confirmed real member names/format
        // instead of assumed ones.
        //
        // Triggered by env var (works when launched from a shell that
        // forwards it) OR a UserDefaults flag (works when launched via
        // `open`, which does NOT forward the launching shell's environment —
        // needed because Desktop-folder TCC access is granted per launched
        // *process instance*, so this has to run as its own top-level
        // process, not spawned from another app's shell). Output goes to
        // both stdout and a fixed log file, since a plain-`open`-launched
        // GUI process has no terminal attached to read stdout from.
        let inspect3MFRequested = ProcessInfo.processInfo.environment["OA_INSPECT_3MF"] == "1"
            || UserDefaults.standard.bool(forKey: "OAInspect3MFPending")
        if inspect3MFRequested {
            UserDefaults.standard.removeObject(forKey: "OAInspect3MFPending")
            var logLines: [String] = []
            func log(_ s: String) {
                print(s)
                logLines.append(s)
            }
            let logURL = URL(fileURLWithPath: "/tmp/oa_inspect3mf.log")
            func flush() {
                try? logLines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
            }

            let folder = AppSettings.shared.studioProjectFolderPath
            log("[Inspect3MF] folder: \(folder)")
            do {
                let expanded = (folder as NSString).expandingTildeInPath
                let contents = try FileManager.default.contentsOfDirectory(atPath: expanded)
                log("[Inspect3MF] raw directory listing (\(contents.count) entries): \(contents)")
                // Diagnostic-only sweep: which of these already has a real
                // "prediction" total-time value vs. just a header-only
                // slice_info.config — see readNewestTotalPrintTimeSeconds's
                // doc comment. Checks every .3mf here, not just the newest.
                for name in contents where name.lowercased().hasSuffix(".3mf") {
                    let fileURL = URL(fileURLWithPath: expanded).appendingPathComponent(name)
                    if let data = BambuStudioProjectReader.extractMember(from: fileURL, member: "Metadata/slice_info.config") {
                        let hasPlate = String(data: data, encoding: .utf8)?.contains("<plate>") ?? false
                        log("[Inspect3MF] \(name): slice_info.config \(data.count) bytes, has <plate>: \(hasPlate)")
                        if hasPlate {
                            let folderOfThisFile = fileURL.deletingLastPathComponent().path
                            // Only valid when this file happens to be the
                            // newest in the folder, since the real function
                            // always targets "newest" — fine for this
                            // one-off diagnostic sweep.
                            if let seconds = BambuStudioProjectReader.readNewestTotalPrintTimeSeconds(inFolder: folderOfThisFile) {
                                log("[Inspect3MF] \(name): readNewestTotalPrintTimeSeconds (if newest) = \(seconds)s = \(BambuStudioProjectReader.formatDuration(seconds: seconds))")
                            }
                            if let text = String(data: data, encoding: .utf8), let range = text.range(of: "prediction") {
                                let snippet = text[range.lowerBound...].prefix(60)
                                log("[Inspect3MF] \(name): raw prediction snippet: \(snippet)")
                            }
                        }
                    } else {
                        log("[Inspect3MF] \(name): no slice_info.config member")
                    }
                }
            } catch {
                log("[Inspect3MF] directory listing threw: \(error)")
            }
            guard let fileURL = BambuStudioProjectReader.newestProjectFile(inFolder: folder) else {
                log("[Inspect3MF] no .3mf found (folder unreadable or empty)")
                flush()
                exit(0)
            }
            log("[Inspect3MF] newest file: \(fileURL.lastPathComponent)")
            let members = BambuStudioProjectReader.listMembers(of: fileURL)
            if members.isEmpty {
                log("[Inspect3MF] could not list ZIP members (unzip failed or file unreadable)")
            } else {
                log("[Inspect3MF] \(members.count) members:")
                for m in members { log("    \(m)") }
            }
            let gcodeMembers = members.filter { $0.hasPrefix("Metadata/plate_") && $0.hasSuffix(".gcode") }
            if gcodeMembers.isEmpty {
                log("[Inspect3MF] no Metadata/plate_*.gcode member found")
            }
            for extra in ["Metadata/slice_info.config", "3D/Objects/object_1.model", "Metadata/model_settings.config"] {
                guard let data = BambuStudioProjectReader.extractMember(from: fileURL, member: extra) else {
                    log("[Inspect3MF] \(extra): extraction failed")
                    continue
                }
                let text = String(data: data, encoding: .utf8) ?? "<non-utf8, \(data.count) bytes>"
                log("[Inspect3MF] \(extra): \(data.count) bytes")
                log("[Inspect3MF] \(extra) first 2000 chars:")
                log(String(text.prefix(2000)))
            }
            for member in gcodeMembers {
                guard let data = BambuStudioProjectReader.extractMember(from: fileURL, member: member) else {
                    log("[Inspect3MF] \(member): extraction failed")
                    continue
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                log("[Inspect3MF] \(member): \(data.count) bytes, \(lines.count) lines")
                log("[Inspect3MF] \(member) first 25 lines:")
                for line in lines.prefix(25) { log("    \(line)") }
                let layerChangeCount = lines.filter { $0.contains("LAYER_CHANGE") }.count
                log("[Inspect3MF] \(member): \(layerChangeCount) lines containing LAYER_CHANGE")
                if let firstLayerChangeIdx = lines.firstIndex(where: { $0.contains("LAYER_CHANGE") }) {
                    let around = lines[firstLayerChangeIdx..<min(firstLayerChangeIdx + 15, lines.count)]
                    log("[Inspect3MF] \(member) around first LAYER_CHANGE:")
                    for line in around { log("    \(line)") }
                }
            }
            flush()
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

            // Diagnostic-only: starts the "Preview 3D" server right away
            // instead of waiting for a manual click in the menu — used to
            // verify /preview.png and /overlay.html serve real bytes end-to-
            // end without driving the SwiftUI menu-bar UI by hand. Every
            // overlay server still starts stopped by default for a real
            // launch; this is purely a testing shortcut. Same dual env-var-
            // or-UserDefaults trigger as OA_INSPECT_3MF, for the same
            // reason (a plain `open` launch doesn't forward env vars).
            if ProcessInfo.processInfo.environment["OA_START_PREVIEW_SERVER"] == "1"
                || UserDefaults.standard.bool(forKey: "OAStartPreviewServerPending") {
                UserDefaults.standard.removeObject(forKey: "OAStartPreviewServerPending")
                state.startPreviewServer()
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
