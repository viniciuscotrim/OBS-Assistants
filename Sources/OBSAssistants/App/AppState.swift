import Foundation
import Combine

/// Central coordinator wiring MQTT (BambuConnectionManager) to the embedded
/// HTTP server, and exposing everything the SwiftUI menu-bar UI needs.
@MainActor
final class AppState: ObservableObject {
    let settings = AppSettings.shared

    @Published var connectionStatus: PrinterConnectionStatus = .disconnected
    @Published var fields: [FieldEntry] = []
    /// Printer overlay's own HTTP server — independent of `studioServerRunning`
    /// below (see LocalHTTPServer's doc comment). Both start stopped; the
    /// user starts each from the menu.
    @Published var serverRunning = false
    /// Bambu Studio overlay's own HTTP server — independent listener/port
    /// from the printer's, so starting/stopping one never affects the other.
    @Published var studioServerRunning = false
    @Published var lastUpdate: Date?
    @Published var discoveredPrinters: [DiscoveredPrinter] = []
    @Published var isScanningNetwork = false
    /// Parsed per-tray humidity/filament-type status, recomputed on every
    /// printer report — feeds both the "Secagem do AMS" UI and
    /// DryingController's threshold checks.
    @Published var amsSlots: [AMSSlotStatus] = []
    /// Slicing details (layer height, walls, infill… ~470 fields) read from
    /// the newest `.3mf` in `settings.studioProjectFolderPath`, plus
    /// whatever `settings.studioComposites` currently resolve to — same
    /// "raw + composites" shape as `fields`, just for the separate
    /// "Overlay Bambu Studio" source. Empty whenever the folder isn't set,
    /// is empty, or the newest file isn't a readable Bambu Studio project —
    /// deliberately cleared rather than left stale (see refreshStudioProject).
    @Published var studioFields: [FieldEntry] = []
    /// The plain fields read straight from the `.3mf`, before composites —
    /// `studioFields` (published) is this plus whatever `studioComposites`
    /// currently resolve to, recomputed whenever either changes.
    private var studioRawFields: [FieldEntry] = []
    /// The file `studioFields` was read from, and when — shown in the menu
    /// so it's obvious at a glance whether this is actually today's file.
    @Published var studioProjectFileName: String = ""
    @Published var studioProjectReadAt: Date?

    private let connectionManager = BambuConnectionManager()
    private let httpServer = LocalHTTPServer()
    /// The Bambu Studio overlay's own listener — see LocalHTTPServer's doc
    /// comment for why this is a fully separate instance/port from
    /// `httpServer` now, instead of the two sharing one listener.
    private let studioHttpServer = LocalHTTPServer()
    private let discoveryService = PrinterDiscoveryService()
    private let lanScanner = LanCertificateScanner()
    private var dryingController: DryingController!
    private var rawSnapshot: [String: Any] = [:]
    private let statusQueue = DispatchQueue(label: "com.obsassistants.status-json")
    private var cachedStatusJSON = Data("{}".utf8)
    private var cachedStudioStatusJSON = Data("{}".utf8)
    private var cancellables = Set<AnyCancellable>()
    /// Last-seen printer job identity (subtask_name + gcode_file) — a
    /// change here means a new print started, which is this app's only
    /// signal to re-scan the Studio project folder (see
    /// refreshStudioProjectIfJobChanged): the newest `.3mf` there is most
    /// likely the one you just sliced and sent.
    private var lastSeenJobIdentity: String?
    private var studioProjectRefreshTimer: DispatchSourceTimer?
    /// The plain, un-augmented flattened fields from the printer — `fields`
    /// (published) is this plus whatever custom composites currently
    /// resolve, recomputed whenever either changes (a new printer report,
    /// or you add/edit/delete a composite in the menu).
    private var rawFields: [FieldEntry] = []

    init() {
        // Purely additive — see seedAdditionalComposites's doc comment.
        // Never touches/removes any composite you already have.
        settings.seedAdditionalComposites(CustomComposite.printerInfoPack)

        // Theme/text-scale changes need to reach /status right away (not
        // just on the next printer update) since overlay.js now reads them
        // live every poll — this is what makes the menu's slider/picker
        // actually take effect in OBS without re-copying the URL.
        settings.$overlayTheme
            .sink { [weak self] _ in self?.rebuildStatusJSON() }
            .store(in: &cancellables)
        settings.$overlayTextScale
            .sink { [weak self] _ in self?.rebuildStatusJSON() }
            .store(in: &cancellables)
        settings.$overlayAutoFit
            .sink { [weak self] _ in self?.rebuildStatusJSON() }
            .store(in: &cancellables)
        settings.$overlayBoxWidthScale
            .sink { [weak self] _ in self?.rebuildStatusJSON() }
            .store(in: &cancellables)
        settings.$overlayBoxHeightScale
            .sink { [weak self] _ in self?.rebuildStatusJSON() }
            .store(in: &cancellables)
        // Adding/editing/deleting a composite in the menu should show up
        // immediately, not just wait for the next printer report.
        settings.$customComposites
            .sink { [weak self] _ in self?.recomputeFields() }
            .store(in: &cancellables)
        // Theme, text scale, box size, and auto-fit are all their own
        // separate settings for the Studio overlay — used to share some or
        // all of these with the printer overlay's, which meant adjusting a
        // slider/picker in one tab silently changed the other tab's OBS
        // source too.
        settings.$studioOverlayTheme
            .sink { [weak self] _ in self?.rebuildStudioStatusJSON() }
            .store(in: &cancellables)
        settings.$studioOverlayTextScale
            .sink { [weak self] _ in self?.rebuildStudioStatusJSON() }
            .store(in: &cancellables)
        settings.$studioOverlayAutoFit
            .sink { [weak self] _ in self?.rebuildStudioStatusJSON() }
            .store(in: &cancellables)
        settings.$studioOverlayBoxWidthScale
            .sink { [weak self] _ in self?.rebuildStudioStatusJSON() }
            .store(in: &cancellables)
        settings.$studioOverlayBoxHeightScale
            .sink { [weak self] _ in self?.rebuildStudioStatusJSON() }
            .store(in: &cancellables)
        // Changing (or clearing) the watched folder in Settings re-scans
        // right away, rather than waiting for the next periodic tick.
        settings.$studioProjectFolderPath
            .sink { [weak self] _ in self?.refreshStudioProject() }
            .store(in: &cancellables)
        // Adding/editing/deleting a Studio composite should show up
        // immediately, same reasoning as the printer's $customComposites.
        settings.$studioComposites
            .sink { [weak self] _ in self?.recomputeStudioFields() }
            .store(in: &cancellables)

        studioHttpServer.statusProvider = { [weak self] in
            self?.statusQueue.sync { self?.cachedStudioStatusJSON ?? Data("{}".utf8) } ?? Data("{}".utf8)
        }
        startStudioProjectRefreshTimer()
        refreshStudioProject()

        connectionManager.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.connectionStatus = status
                self?.rebuildStatusJSON()
            }
        }
        connectionManager.onFieldsUpdate = { [weak self] fields, raw in
            Task { @MainActor in self?.handleFieldsUpdate(fields: fields, raw: raw) }
        }
        httpServer.statusProvider = { [weak self] in
            self?.statusQueue.sync { self?.cachedStatusJSON ?? Data("{}".utf8) } ?? Data("{}".utf8)
        }
        discoveryService.onUpdate = { [weak self] printers in
            Task { @MainActor in
                self?.discoveredPrinters = printers
                print("[OBS Assistants] discovered \(printers.count) printer(s): \(printers.map { "\($0.name)@\($0.ip)" })")
            }
        }
        discoveryService.start()

        dryingController = DryingController(settings: settings) { [weak self] amsID, filamentType, tempC, coolingTempC, durationHours, rotateTray, mode in
            self?.connectionManager.sendAMSDryingCommand(amsID: amsID, filamentType: filamentType, tempC: tempC, coolingTempC: coolingTempC, durationHours: durationHours, rotateTray: rotateTray, mode: mode)
        }
        dryingController.onManualAlert = { alert in
            DryingNotificationManager.shared.sendAlert(alert)
        }
        dryingController.onAutoDryStarted = { alert, profile in
            DryingNotificationManager.shared.sendAutoStartedNotice(alert, profile: profile)
        }
        dryingController.onAutoDryStopped = { amsID, humidityPercent in
            DryingNotificationManager.shared.sendAutoStoppedNotice(amsID: amsID, humidityPercent: humidityPercent)
        }

        // UNUserNotificationCenter setup (first access to .current(), plus
        // requesting authorization) talks to a system daemon over XPC —
        // seen it stall for a while on first-run-after-reinstall. Doing
        // this from a background queue, off the init() critical path,
        // means a slow/hung response there can never delay the HTTP
        // server or MQTT connection from coming up; the menu-bar app and
        // OBS overlay work regardless of whether/when notifications
        // finish setting up.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            DryingNotificationManager.shared.onStartDryingAction = { amsID, trayIndex, filamentType, humidityPercent in
                Task { @MainActor in
                    guard let self else { return }
                    // Rebuild the alert from the notification's own payload
                    // — the in-memory DryingAlert that triggered it may be
                    // long gone by the time you actually tap the action. A
                    // "/" in the type string means it was a mixed-type alert.
                    let kind: DryingAlertKind
                    if filamentType.contains("/") {
                        let types = filamentType.split(separator: "/").map(String.init)
                        let safeTemp = types.compactMap { self.settings.profile(forFilamentType: $0)?.dryTemperatureC }.min() ?? 45
                        kind = .mixedFilamentTypes(types: types, safeTempC: safeTemp)
                    } else if let profile = self.settings.profile(forFilamentType: filamentType) {
                        kind = .thresholdExceeded(profile: profile)
                    } else {
                        kind = .unknownFilamentType
                    }
                    let alert = DryingAlert(amsID: amsID, trayIndex: trayIndex, filamentType: filamentType, humidityPercent: humidityPercent, kind: kind)
                    self.presentDryConfirmation(alert)
                }
            }
            DryingNotificationManager.shared.requestAuthorizationIfNeeded()
        }

        // Passive SSDP listening (above) is the primary discovery path, but
        // plenty of real routers/mesh systems drop or mis-forward multicast
        // (missing IGMP querier, AP/client isolation) while ordinary
        // unicast TCP works fine — so also run one active LAN scan shortly
        // after launch as a fallback, without the user having to know to
        // ask for it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.scanNetwork()
        }
    }

    /// Fills IP + serial from a printer heard via SSDP discovery or found by
    /// scanNetwork(). The Access Code is never broadcast/discoverable, so
    /// it's left untouched — the user still types it in once.
    func useDiscoveredPrinter(_ printer: DiscoveredPrinter) {
        settings.printerIP = printer.ip
        settings.printerSerial = printer.serial
    }

    /// Actively probes the local subnet for Bambu printers (port 8883,
    /// identified by their TLS certificate) instead of waiting for a
    /// broadcast. See LanCertificateScanner's doc comment for why this
    /// exists alongside passive SSDP listening. Safe to call repeatedly —
    /// e.g. from a manual "buscar de novo" button — a scan in progress is
    /// not restarted.
    func scanNetwork() {
        guard !isScanningNetwork else { return }
        isScanningNetwork = true
        lanScanner.scan { [weak self] scanned in
            Task { @MainActor in
                print("[OBS Assistants] active LAN scan found \(scanned.count): \(scanned.map { "\($0.serial)@\($0.ip)" })")
                self?.mergeScanned(scanned)
                self?.isScanningNetwork = false
            }
        }
    }

    private func mergeScanned(_ scanned: [ScannedPrinter]) {
        var bySerial = Dictionary(uniqueKeysWithValues: discoveredPrinters.map { ($0.serial, $0) })
        for found in scanned {
            if var existing = bySerial[found.serial] {
                existing.ip = found.ip
                existing.lastSeen = Date()
                bySerial[found.serial] = existing
            } else {
                bySerial[found.serial] = DiscoveredPrinter(
                    serial: found.serial,
                    ip: found.ip,
                    name: found.serial,
                    model: "",
                    signal: nil,
                    firmware: nil,
                    lastSeen: Date()
                )
            }
        }
        discoveredPrinters = bySerial.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: - Printer connection

    func connectPrinter() {
        connectionManager.start()
    }

    /// Diagnostic-only: see BambuConnectionManager.sniffRequestsTopic. Must
    /// be called before connectPrinter() to take effect on the initial
    /// subscribe.
    func enableRequestTopicSniff() {
        connectionManager.sniffRequestsTopic = true
    }

    func disconnectPrinter() {
        connectionManager.stop()
    }

    /// See BambuConnectionManager.injectTestPayload — lets the overlay
    /// pipeline be exercised end-to-end without a physical printer.
    func injectTestPayload(_ json: [String: Any]) {
        connectionManager.injectTestPayload(json)
    }

    private func handleFieldsUpdate(fields: [FieldEntry], raw: [String: Any]) {
        self.rawFields = fields
        self.rawSnapshot = raw
        self.lastUpdate = Date()
        recomputeFields()

        let slots = AMSSlotParser.parse(rawSnapshot: raw)
        self.amsSlots = slots
        dryingController.evaluate(slots: slots)

        checkForNewPrintJob(raw: raw)
    }

    // MARK: - Overlay Bambu Studio (local .3mf slicing details)

    /// A changed `subtask_name`/`gcode_file` means a new job started on the
    /// printer — the best available signal to re-scan the Studio project
    /// folder, since the newest `.3mf` there is most likely the one you
    /// just sliced and sent. See BambuStudioProjectReader's doc comment for
    /// why this can't be tied to the exact file with certainty.
    private func checkForNewPrintJob(raw: [String: Any]) {
        let print = raw["print"] as? [String: Any]
        let subtaskName = (print?["subtask_name"] as? String) ?? ""
        let gcodeFile = (print?["gcode_file"] as? String) ?? ""
        let identity = "\(subtaskName)|\(gcodeFile)"
        guard !identity.isEmpty, identity != "|" else { return }
        if lastSeenJobIdentity != nil, lastSeenJobIdentity != identity {
            refreshStudioProject()
        }
        lastSeenJobIdentity = identity
    }

    private func startStudioProjectRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Backstop only — checkForNewPrintJob already refreshes on an
        // actual job change; this just catches the folder gaining/losing
        // its newest file for any other reason (e.g. you dropped a new
        // .3mf in by hand without printing yet).
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.refreshStudioProject() }
        }
        timer.resume()
        studioProjectRefreshTimer = timer
    }

    /// Re-scans `settings.studioProjectFolderPath` for its newest `.3mf`
    /// and updates `studioFields` — always clears to empty first so a
    /// removed folder, an empty one, or an unreadable file never leaves a
    /// stale reading from a previous print on screen.
    func refreshStudioProject() {
        guard !settings.studioProjectFolderPath.isEmpty,
              let info = BambuStudioProjectReader.readNewestProject(inFolder: settings.studioProjectFolderPath) else {
            studioRawFields = []
            studioProjectFileName = ""
            studioProjectReadAt = nil
            recomputeStudioFields()
            return
        }
        studioRawFields = info.fields
        studioProjectFileName = info.fileName
        studioProjectReadAt = info.modifiedAt
        recomputeStudioFields()
    }

    /// Mirrors `recomputeFields()` for the Studio overlay's own composite
    /// pool — called whenever the `.3mf` is re-read or `studioComposites`
    /// changes in the menu.
    private func recomputeStudioFields() {
        studioFields = studioRawFields + CustomComposite.available(settings.studioComposites, from: studioRawFields)
        rebuildStudioStatusJSON()
    }

    private func rebuildStudioStatusJSON() {
        let orderedKeys = settings.visibleFieldOrder
        let byKey = Dictionary(uniqueKeysWithValues: studioFields.map { ($0.key, $0) })
        var orderedFields: [FieldEntry] = []
        var seen = Set<String>()
        for key in orderedKeys {
            guard let field = byKey[key] else { continue }
            orderedFields.append(field)
            seen.insert(key)
        }
        for field in studioFields where !seen.contains(field.key) {
            orderedFields.append(field)
        }

        let visible = Set(orderedKeys)
        let fieldObjects: [[String: Any]] = orderedFields.map { field in
            [
                "key": field.key,
                "label": field.label,
                "value": field.value,
                "visible": visible.contains(field.key),
                "category": "Bambu Studio"
            ]
        }

        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "connected": !studioFields.isEmpty,
            "connectionMode": studioFields.isEmpty ? "disconnected" : "primary",
            "lastUpdate": studioProjectReadAt.map(formatter.string(from:)) ?? NSNull(),
            "fields": fieldObjects,
            "settings": [
                "theme": settings.studioOverlayTheme,
                "textScale": settings.studioOverlayTextScale,
                "autoFit": settings.studioOverlayAutoFit,
                "boxWidthScale": settings.studioOverlayBoxWidthScale,
                "boxHeightScale": settings.studioOverlayBoxHeightScale
            ],
            "raw": [:]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        statusQueue.sync { cachedStudioStatusJSON = data }
    }

    // MARK: - AMS drying

    private func presentDryConfirmation(_ alert: DryingAlert) {
        DryConfirmationWindowController.shared.present(alert: alert, settings: settings) { [weak self] filamentType, tempC, coolingTempC, durationHours, rotateTray in
            guard let self else { return }
            // Use the real saved profile for whatever type ended up
            // selected (ideal/max thresholds matter for the humidity-based
            // auto-stop target) when there is one; otherwise a synthetic
            // profile carrying just the confirmed temp/duration — covers
            // the mixed-type case, which deliberately doesn't force a
            // single type label.
            let profile = self.settings.profile(forFilamentType: filamentType)
                ?? DryingProfile(filamentType: filamentType.isEmpty ? alert.filamentType : filamentType, idealHumidityPercent: 0, maxHumidityPercent: 0, dryTemperatureC: tempC, dryDurationHours: durationHours, coolingTemperatureC: coolingTempC)
            var effectiveProfile = profile
            effectiveProfile.dryTemperatureC = tempC
            effectiveProfile.coolingTemperatureC = coolingTempC
            effectiveProfile.dryDurationHours = durationHours
            self.dryingController.startDrying(amsID: alert.amsID, profile: effectiveProfile, rotateTray: rotateTray, alert: nil)
        }
    }

    /// Manual "start drying" entry point for the AMS section in the menu —
    /// same command path as the notification action, just triggered
    /// directly instead of via a tapped notification.
    func presentDryConfirmation(forSlot slot: AMSSlotStatus) {
        let kind: DryingAlertKind
        if let profile = settings.profile(forFilamentType: slot.filamentTypeDisplay) {
            kind = .thresholdExceeded(profile: profile)
        } else {
            kind = .unknownFilamentType
        }
        let alert = DryingAlert(
            amsID: slot.amsID,
            trayIndex: slot.trayIndex,
            filamentType: slot.filamentTypeDisplay,
            humidityPercent: slot.humidityPercent ?? 0,
            kind: kind
        )
        presentDryConfirmation(alert)
    }

    /// General manual entry point — doesn't need a live AMSSlotStatus (no
    /// data flowing yet, printer just not reporting humidity for this unit,
    /// or you just want to test the command by hand): pick an AMS number
    /// and a filament type yourself and go straight to the confirmation
    /// window.
    func presentManualDryConfirmation(amsID: Int, filamentType: String) {
        let kind: DryingAlertKind
        if let profile = settings.profile(forFilamentType: filamentType) {
            kind = .thresholdExceeded(profile: profile)
        } else {
            kind = .unknownFilamentType
        }
        let currentHumidity = amsSlots.first(where: { $0.amsID == amsID })?.humidityPercent ?? 0
        let alert = DryingAlert(amsID: amsID, trayIndex: 0, filamentType: filamentType, humidityPercent: currentHumidity, kind: kind)
        presentDryConfirmation(alert)
    }

    func stopDrying(amsID: Int) {
        // filamentType intentionally left empty — see stopAMSDrying's doc
        // comment; looking up the real tray type here used to produce "?"
        // (this app's own "unidentified" placeholder) whenever the type
        // wasn't confidently known, which had no basis in anything the
        // printer actually expects for a stop command.
        connectionManager.stopAMSDrying(amsID: amsID)
    }

    /// Diagnostic-only — see OA_DRY_TEST in OBSAssistantsApp.init().
    func sendDryingCommandForTest(amsID: Int, filamentType: String, tempC: Double, durationHours: Double) {
        let coolingTempC = settings.profile(forFilamentType: filamentType)?.coolingTemperatureC ?? max(0, tempC - 5)
        connectionManager.sendAMSDryingCommand(amsID: amsID, filamentType: filamentType, tempC: tempC, coolingTempC: coolingTempC, durationHours: durationHours, rotateTray: settings.rotateTrayDefaultEnabled, mode: 1)
    }

    /// Rebuilds the published `fields` (raw + whatever composites currently
    /// resolve) and pushes a fresh /status. Composite fields are
    /// synthesized from raw ones and injected into the same list, so they
    /// flow through the exact same visibility/ordering/search pipeline as
    /// anything the printer actually sent — no special-casing needed
    /// downstream (UI, /status, overlay.js all just see more FieldEntry
    /// values).
    private func recomputeFields() {
        fields = rawFields + CustomComposite.available(settings.customComposites, from: rawFields)
        rebuildStatusJSON()
    }

    func setFieldVisible(_ key: String, visible: Bool) {
        settings.setField(key, visible: visible)
        rebuildStatusJSON()
        // visibleFieldOrder is shared with Studio fields (keys are
        // uniquely prefixed, e.g. "studio.layer_height", so there's no
        // collision) — cheap to always keep both in sync rather than
        // tracking which pool a given key belongs to.
        rebuildStudioStatusJSON()
    }

    /// Reorders a visible field — this is what controls which tile ends up
    /// next to which in the overlay grid (it renders in the same order
    /// /status lists visible fields in).
    func moveFieldUp(_ key: String) {
        settings.moveField(key, by: -1)
        rebuildStatusJSON()
        rebuildStudioStatusJSON()
    }

    func moveFieldDown(_ key: String) {
        settings.moveField(key, by: 1)
        rebuildStatusJSON()
        rebuildStudioStatusJSON()
    }

    // MARK: - HTTP servers
    // Printer and Bambu Studio overlays each have their own independent
    // listener/port (see LocalHTTPServer's doc comment) and are started
    // stopped by default — the user starts whichever one(s) they want from
    // the menu, same as the Now Playing overlay.

    func startServer() {
        do {
            try httpServer.start(port: settings.httpPort)
            serverRunning = true
        } catch {
            serverRunning = false
        }
    }

    func stopServer() {
        httpServer.stop()
        serverRunning = false
    }

    func startStudioServer() {
        do {
            try studioHttpServer.start(port: settings.studioHttpPort)
            studioServerRunning = true
        } catch {
            studioServerRunning = false
        }
    }

    func stopStudioServer() {
        studioHttpServer.stop()
        studioServerRunning = false
    }

    // MARK: - /status JSON

    private func rebuildStatusJSON() {
        // Visible fields first, in the user's chosen order (drag/move in
        // the UI) — overlay.js filters to `visible` and renders in array
        // order, so this is what actually decides layout/adjacency in the
        // grid. Anything not currently visible trails after; its order
        // doesn't matter since the overlay never renders it.
        let orderedKeys = settings.visibleFieldOrder
        let byKey = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0) })
        var orderedFields: [FieldEntry] = []
        orderedFields.reserveCapacity(fields.count)
        var seen = Set<String>()
        for key in orderedKeys {
            guard let field = byKey[key] else { continue } // stale key, e.g. an AMS slot that's gone now
            orderedFields.append(field)
            seen.insert(key)
        }
        for field in fields where !seen.contains(field.key) {
            orderedFields.append(field)
        }

        let visible = Set(orderedKeys)
        let fieldObjects: [[String: Any]] = orderedFields.map { field in
            [
                "key": field.key,
                "label": field.label,
                "value": field.value,
                "visible": visible.contains(field.key),
                "category": FieldCategory.classify(key: field.key).rawValue
            ]
        }

        let formatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "connected": connectionStatus == .connectedPrimary || connectionStatus == .connectedFallback,
            "connectionMode": connectionModeString,
            "lastUpdate": lastUpdate.map(formatter.string(from:)) ?? NSNull(),
            "fields": fieldObjects,
            // Live display settings from the app's menu — overlay.js applies
            // these on every poll (URL query params still override, for
            // pinning a specific look per-OBS-source), so moving the text
            // size slider or changing the theme in the app takes effect in
            // OBS within one poll cycle. Without this, those settings only
            // ever reached the overlay baked into the URL at the moment you
            // clicked "Copiar URL do OBS" — change the slider afterwards
            // and nothing updates until you re-copy/re-paste the URL, which
            // looks exactly like the setting doing nothing.
            "settings": [
                "theme": settings.overlayTheme,
                "textScale": settings.overlayTextScale,
                "autoFit": settings.overlayAutoFit,
                "boxWidthScale": settings.overlayBoxWidthScale,
                "boxHeightScale": settings.overlayBoxHeightScale
            ]
        ]
        if JSONSerialization.isValidJSONObject(rawSnapshot) {
            payload["raw"] = rawSnapshot
        } else {
            payload["raw"] = [:]
        }

        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        statusQueue.sync { cachedStatusJSON = data }
    }

    private var connectionModeString: String {
        switch connectionStatus {
        case .connectedPrimary: return "primary"
        case .connectedFallback: return "fallback"
        case .connecting: return "connecting"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        }
    }
}
