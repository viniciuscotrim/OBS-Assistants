import Foundation
import Security

enum PrinterConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connectedPrimary      // plain bblp/access-code TLS (pre-Jan/2025-style firmware)
    case connectedFallback     // mutual-TLS with a user-supplied client identity
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: return "Desconectado"
        case .connecting: return "Conectando…"
        case .connectedPrimary: return "Conectado"
        case .connectedFallback: return "Conectado (modo X.509)"
        case .failed(let reason): return "Falha: \(reason)"
        }
    }
}

/// Owns the MQTT connection lifecycle for one printer: tries the standard
/// bblp/access-code LAN handshake first, and if that's rejected, retries
/// once using a mutual-TLS client identity as a fallback for printers on
/// firmware that started requiring signed/authenticated local connections
/// in January 2025.
///
/// Background: Bambu Lab's "Bambu Connect" desktop app carries an X.509
/// client certificate + private key used to authenticate/sign local MQTT
/// traffic on newer firmware. That certificate was extracted from Bambu
/// Connect's bundled code and publicly documented in Jan 2025 (see
/// https://github.com/Doridian/OpenBambuAPI, which catalogs the
/// reverse-engineered local/cloud MQTT protocol, and the community writeups
/// it links to, e.g. https://hackaday.com/2025/01/19/bambu-connects-authentication-x-509-certificate-and-private-key-extracted/).
/// This app does **not** embed that (or any other) extracted credential —
/// doing so would mean shipping someone else's private key verbatim in this
/// repo. Instead, the fallback here is a generic mutual-TLS path: point
/// `AppSettings.clientCertPath` at a PKCS#12 (.p12) file containing a client
/// identity (e.g. one you exported yourself after obtaining it through the
/// resources above, or your printer's own dev credentials if you have
/// them), and this manager will retry the connection presenting it.
final class BambuConnectionManager {
    private let client = MQTTClient()
    private let reportStore = PrinterReportStore()

    private(set) var status: PrinterConnectionStatus = .disconnected {
        didSet { onStatusChange?(status) }
    }

    var onStatusChange: ((PrinterConnectionStatus) -> Void)?
    var onFieldsUpdate: (([FieldEntry], [String: Any]) -> Void)?

    /// Diagnostic-only: when true, also subscribes to `device/<serial>/request`
    /// (the topic normally used one-way, for *us* to publish commands *to*
    /// the printer) so we can passively observe whatever the official Bambu
    /// Handy/Studio app publishes there when the user triggers a feature
    /// through it — e.g. capturing the real `ams_filament_drying` payload
    /// instead of guessing field names. Never publishes anything itself.
    /// Driven by OA_SNIFF_REQUESTS=1 (see OBSAssistantsApp).
    var sniffRequestsTopic = false

    private var settings: AppSettings { AppSettings.shared }
    /// Incrementing counter for the drying command's `sequence_id`.
    /// ClusterM/open-bamboo-networking's protocol research (citing
    /// BambuStudio's own source — `DeviceManager.hpp`/`DevUtil.h`) documents
    /// the exact real rule: Studio seeds a process-wide counter at
    /// `STUDIO_START_SEQ_ID = 20000` and increments it for every
    /// Studio-originated command, and the firmware/plugin explicitly
    /// classifies a request as Studio's own via
    /// `DevUtil::is_studio_cmd(seq): seq >= 20000 && seq < 30000`. A prior
    /// attempt seeded this from a Unix timestamp (~1.7 billion) specifically
    /// to guarantee monotonicity — which is nowhere near that 20000-29999
    /// window, so it may have been silently treated as untrusted/foreign
    /// rather than merely "out of order". Reseeded here well above any
    /// sequence_id Bambu Studio has been observed using in this session
    /// (last capture: 20010) but still inside the valid window, so it's
    /// both monotonic *and* recognizable as a plausible Studio-shaped id.
    private static var dryingSequenceID = 25000
    private var usingFallback = false
    private var reconnectTimer: DispatchSourceTimer?
    private let reconnectQueue = DispatchQueue(label: "com.obsassistants.reconnect")
    /// Independent 60s safety-net timer — see `armWatchdog`'s doc comment.
    private var watchdogTimer: DispatchSourceTimer?
    /// Set by `start()`/`stop()` — tracks whether a live connection is
    /// actually wanted right now, so the watchdog below never fights an
    /// explicit "Desconectar" by reconnecting behind the user's back.
    private var shouldStayConnected = false

    init() {
        client.onStateChange = { [weak self] state in
            self?.handleClientState(state)
        }
        client.onMessage = { [weak self] topic, data in
            self?.handleMessage(topic: topic, data: data)
        }
    }

    func start() {
        guard settings.isConfigured else {
            status = .failed("Configure IP, serial e Access Code primeiro")
            return
        }
        shouldStayConnected = true
        reportStore.reset()
        usingFallback = false
        status = .connecting
        connectPrimary()
        armWatchdog()
    }

    func stop() {
        shouldStayConnected = false
        reconnectTimer?.cancel()
        reconnectTimer = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
        client.disconnect()
        status = .disconnected
    }

    // MARK: - Connection attempts

    private func connectPrimary() {
        client.connect(
            host: settings.printerIP,
            clientID: "OBSAssistants-\(UUID().uuidString.prefix(8))",
            username: "bblp",
            password: settings.accessCode,
            clientIdentity: nil
        )
    }

    private func connectFallback() {
        guard !settings.clientCertPath.isEmpty else {
            status = .failed("Auth rejeitada e nenhum certificado de fallback configurado (veja Settings > Certificado X.509)")
            return
        }
        guard let identity = Self.loadIdentity(p12Path: settings.clientCertPath, password: settings.clientCertPassword) else {
            status = .failed("Não foi possível carregar o certificado .p12 configurado")
            return
        }
        usingFallback = true
        status = .connecting
        client.connect(
            host: settings.printerIP,
            clientID: "OBSAssistants-\(UUID().uuidString.prefix(8))",
            username: "bblp",
            password: settings.accessCode,
            clientIdentity: identity
        )
    }

    private func handleClientState(_ state: MQTTClientState) {
        switch state {
        case .connected:
            status = usingFallback ? .connectedFallback : .connectedPrimary
            let topic = "device/\(settings.printerSerial)/report"
            client.subscribe(topic: topic)
            if sniffRequestsTopic {
                let requestTopic = "device/\(settings.printerSerial)/request"
                print("[Sniff] also subscribing to \(requestTopic) — will log anything published there by other MQTT clients (e.g. Bambu Handy/Studio)")
                client.subscribe(topic: requestTopic)
            }
            requestPushAll()
        case .failed(let reason):
            if !usingFallback {
                // Primary handshake rejected — try the X.509 fallback once.
                connectFallback()
            } else {
                status = .failed(reason)
                scheduleReconnect()
            }
        case .disconnected:
            if status != .disconnected {
                status = .disconnected
                scheduleReconnect()
            }
        default:
            break
        }
    }

    /// Reconnect delay after losing the connection — was a fixed 10s,
    /// which (root-caused 2026-09-10 via packet-level MQTT logging) turned
    /// a completely benign, recurring pattern into a very visible one: the
    /// printer's own local broker cleanly closes the TCP connection (clean
    /// FIN, no MQTT error) after a short burst of status reports (~7
    /// messages, ~9s) — happens *every single cycle*, indefinitely, and
    /// isn't caused by anything this app sends/doesn't send (confirmed:
    /// QoS 0 publishes throughout, so it isn't an unacked-message issue
    /// either). Reconnecting always works fine — the actual problem was
    /// just that a 10s gap every ~9s of connected time reads as "keeps
    /// losing the printer" over the course of a whole print, when it's
    /// really the printer cycling its own session on a schedule the
    /// official Bambu apps most likely just reconnect through invisibly.
    /// A short, fixed delay (not exponential backoff — deliberately, so a
    /// real print never needs a manual reconnect) keeps this near-invisible
    /// without hammering a connection attempt in a tight loop.
    private static let reconnectDelay: TimeInterval = 3

    private func scheduleReconnect() {
        reconnectTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: reconnectQueue)
        timer.schedule(deadline: .now() + Self.reconnectDelay)
        timer.setEventHandler { [weak self] in
            self?.start()
        }
        timer.resume()
        reconnectTimer = timer
    }

    /// Belt-and-suspenders on top of `scheduleReconnect` — requested after
    /// real, multi-hour print sessions needed manual reconnects more than
    /// this app's own disconnect-driven retry should ever allow. Runs
    /// independently for as long as a connection is wanted (`start()` was
    /// called, `stop()` wasn't): every 60s, if status isn't actually
    /// connected or mid-attempt, forces a fresh `start()` — catches
    /// anything `scheduleReconnect` might miss (a lost/cancelled timer, a
    /// `.connecting` state that never resolved, a timer left suspended
    /// across a Mac sleep/wake cycle) without waiting on that path at all.
    /// Keeps retrying forever by design — only a real network outage or the
    /// printer leaving the LAN should ever make this stop finding it again,
    /// never something the user has to notice and act on themselves.
    private func armWatchdog() {
        guard watchdogTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: reconnectQueue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, self.shouldStayConnected else { return }
            switch self.status {
            case .connectedPrimary, .connectedFallback, .connecting:
                return
            default:
                print("[Watchdog] status: \(self.status) — forcing reconnect")
                self.start()
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    /// Asks the printer for a full status dump rather than waiting for
    /// deltas to accumulate — see OpenBambuAPI/mqtt.md, "pushing.pushall".
    private func requestPushAll() {
        let topic = "device/\(settings.printerSerial)/request"
        client.publish(topic: topic, jsonObject: [
            "pushing": [
                "sequence_id": "0",
                "command": "pushall",
                "version": 1,
                "push_target": 1
            ]
        ])
    }

    // MARK: - Message handling

    private func handleMessage(topic: String, data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if sniffRequestsTopic, topic.hasSuffix("/request") {
            // A command published by *some* MQTT client (possibly the
            // official Bambu Handy/Studio app, possibly this very process a
            // moment ago) — log it verbatim and do NOT feed it into the
            // report store, which only expects /report-shaped payloads.
            print("[Sniff] observed publish on \(topic): \(json)")
            return
        }
        // Every top-level key we've observed from real printers (print,
        // system, info, ...) gets merged in as-is — nothing is filtered.
        reportStore.merge(json)
        let fields = reportStore.flattenedFields()
        onFieldsUpdate?(fields, reportStore.rawSnapshot)
    }

    // MARK: - AMS drying command

    /// **Confirmed against real hardware** — not by guessing, but by
    /// passively sniffing `device/<serial>/request` while a drying cycle
    /// was started from the *official* Bambu Handy app on the same LAN
    /// (see `sniffRequestsTopic`). That capture is the ground truth for
    /// every field name/type below; three earlier field-name hypotheses
    /// (generic `temp`/`duration`/`cooling_temp`+`rotate_tray:false`; then
    /// `dry_filament`/`dry_temperature`/`dry_duration` matching the
    /// `dry_setting` status object, with both Int and String `ams_id`) all
    /// failed against the real printer — the actual command turned out to
    /// need a `filament` field (missing from every guess) and integer
    /// `ams_id`/`rotate_tray` (not string/bool).
    ///
    /// There is still no request/response ACK in Bambu's local MQTT
    /// protocol — the printer either quietly starts (or ignores) the
    /// command — so this logs the exact payload sent, and AppState
    /// separately watches `print.ams.ams[N].dry_setting` in subsequent
    /// reports (a real field the printer itself reports back, e.g.
    /// `{"dry_temperature": -1, "dry_filament": "", "dry_duration": -1}`
    /// when nothing is running) to tell whether the command actually took.
    /// `mode: 0` stops an active cycle.
    ///
    /// `amsID` is the AMS *unit* index (0, 1, 2…) — the drying heater
    /// warms that whole unit's enclosed chamber, not an individual tray,
    /// so there's no per-tray target here even though humidity/filament
    /// type are tracked per tray elsewhere in this app. `humidity: 0` and
    /// `close_power_conflict: 0` are always sent as fixed values, matching
    /// the sniffed capture — no known reason for either to vary from the
    /// UI's perspective.
    ///
    /// `sequence_id` is sent as a **string** — every other command in this
    /// file already did this correctly (`"0"`); this one briefly regressed
    /// to a bare Int while chasing a different hypothesis (see
    /// `dryingSequenceID`'s doc comment for the real rule, sourced from
    /// BambuStudio's own code: a decimal string in Studio's own
    /// 20000-29999 range).
    ///
    /// `duration` is sent in **whole hours**, not minutes. An earlier
    /// version of this comment claimed minutes, based on a third-party
    /// Python library's own doc comment ("duration=120 # Dry for 2
    /// hours") — that turned out to describe *that library's own
    /// higher-level parameter*, not the raw wire field. Corrected after
    /// sniffing the real Bambu Studio UI directly: its duration picker
    /// only offers whole-hour steps, and captured real starts sent
    /// `"duration": 1` and `"duration": 2` for 1h/2h selections — small
    /// round numbers consistent with hours, not minutes.
    func sendAMSDryingCommand(amsID: Int, filamentType: String, tempC: Double, coolingTempC: Double, durationHours: Double, rotateTray: Bool, mode: Int) {
        guard status == .connectedPrimary || status == .connectedFallback else {
            print("[AMS Drying] ignored — not connected to the printer (status: \(status))")
            return
        }
        Self.dryingSequenceID += 1
        let topic = "device/\(settings.printerSerial)/request"
        let payload: [String: Any] = [
            "print": [
                "sequence_id": String(Self.dryingSequenceID),
                "command": "ams_filament_drying",
                "ams_id": amsID,
                "filament": filamentType,
                "temp": Int(tempC.rounded()),
                "cooling_temp": Int(coolingTempC.rounded()),
                "duration": Int(durationHours.rounded()),
                "humidity": 0,
                "mode": mode,
                "rotate_tray": rotateTray ? 1 : 0,
                // Reverted from an earlier "always 1" experiment (untested
                // hypothesis, never confirmed) back to 0/false — matches
                // both the original sniffed capture AND the fixed default
                // in ha-bambulab's AMS_FILAMENT_DRYING_TEMPLATE (see
                // https://github.com/greghesp/ha-bambulab/pull/2052, which
                // closed a real, independently-reported bug — issue #1997
                // — describing this exact symptom: "MQTT command sent, no
                // error, AMS never actually starts drying" on several
                // printer/AMS-2-Pro combinations, including one X2D).
                "close_power_conflict": 0
            ]
        ]
        print("[AMS Drying] publishing to \(topic): \(payload)")
        client.publish(topic: topic, jsonObject: payload)
    }

    /// `filamentType` defaults to empty — matches the confirmed-fixed
    /// community template for a stop command (see doc comment above);
    /// there's no evidence the printer needs/uses a real type to stop.
    func stopAMSDrying(amsID: Int, filamentType: String = "") {
        sendAMSDryingCommand(amsID: amsID, filamentType: filamentType, tempC: 0, coolingTempC: 0, durationHours: 0, rotateTray: false, mode: 0)
    }

    /// Test-only entry point: feeds a captured/sample MQTT report payload
    /// through the exact same merge+flatten pipeline as a live message,
    /// without needing a physical printer. Used by the app at launch when
    /// the OA_TEST_PAYLOAD environment variable points at a JSON file (see
    /// README "Testing without hardware").
    func injectTestPayload(_ json: [String: Any]) {
        reportStore.merge(json)
        let fields = reportStore.flattenedFields()
        onFieldsUpdate?(fields, reportStore.rawSnapshot)
    }

    // MARK: - PKCS#12 loading

    private static func loadIdentity(p12Path: String, password: String) -> SecIdentity? {
        let url = URL(fileURLWithPath: (p12Path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess, let items = rawItems as? [[String: Any]], let first = items.first else {
            return nil
        }
        guard let identity = first[kSecImportItemIdentity as String] else { return nil }
        return (identity as! SecIdentity)
    }
}
