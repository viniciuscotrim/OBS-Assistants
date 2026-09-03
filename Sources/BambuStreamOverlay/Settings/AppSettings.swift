import Foundation
import Combine

/// All user-configurable settings, persisted in UserDefaults (non-sensitive
/// fields) and the Keychain (LAN access code + client-cert password).
///
/// This is intentionally generic: nothing here is model-specific (X1/P1/A1/H2D
/// all speak the same local MQTT protocol — device/<serial>/report on 8883
/// with user "bblp" and the LAN "access code" as password). See
/// https://github.com/Doridian/OpenBambuAPI/blob/main/mqtt.md for the
/// reverse-engineered protocol reference used while building this.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Real users never set BSO_TEST_PAYLOAD/BSO_SCAN_TEST/BSO_ISOLATED_DEFAULTS
    /// — those only exist for developer testing (see README "Testing
    /// without hardware"). When any of them is set, settings (and the two
    /// Keychain secrets) persist under a throwaway namespace instead of the
    /// real one, so a test run can never overwrite an actual user's
    /// configured fields/order/theme/access code/etc.
    private static let isTestRun: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["BSO_TEST_PAYLOAD"] != nil
            || env["BSO_SCAN_TEST"] != nil
            || env["BSO_ISOLATED_DEFAULTS"] != nil
            || env["BSO_KEYCHAIN_TEST"] != nil
    }()

    private let defaults: UserDefaults = {
        if isTestRun, let suite = UserDefaults(suiteName: "com.bambustreamoverlay.app.testing") {
            return suite
        }
        return .standard
    }()

    /// Keychain account name, namespaced away from the real one during a
    /// test run (see `isTestRun`).
    private static func keychainAccount(_ base: String) -> String {
        isTestRun ? "\(base).testing" : base
    }

    // MARK: Printer connection
    @Published var printerIP: String {
        didSet { defaults.set(printerIP, forKey: Keys.printerIP) }
    }
    @Published var printerSerial: String {
        didSet { defaults.set(printerSerial, forKey: Keys.printerSerial) }
    }
    /// LAN "Access Code" shown on the printer's touchscreen (Settings > WLAN).
    /// Stored in the Keychain, not UserDefaults.
    @Published var accessCode: String {
        didSet { KeychainHelper.set(accessCode, account: Self.keychainAccount(Keys.accessCodeAccount)) }
    }

    // MARK: X.509 fallback (post-Jan/2025 firmware)
    /// Path to a PKCS#12 (.p12) client identity used as a mutual-TLS fallback
    /// when the plain bblp/access-code handshake is rejected. See
    /// BambuConnectionManager for how/why this is used, and the README for
    /// where to obtain your own copy — this app does not ship one.
    @Published var clientCertPath: String {
        didSet { defaults.set(clientCertPath, forKey: Keys.clientCertPath) }
    }
    @Published var clientCertPassword: String {
        didSet { KeychainHelper.set(clientCertPassword, account: Self.keychainAccount(Keys.clientCertPasswordAccount)) }
    }

    // MARK: HTTP server
    @Published var httpPort: Int {
        didSet { defaults.set(httpPort, forKey: Keys.httpPort) }
    }

    @Published var overlayTheme: String {
        didSet { defaults.set(overlayTheme, forKey: Keys.overlayTheme) }
    }
    /// Own theme for the Studio overlay — was shared with `overlayTheme`
    /// (the printer one) at first, on the assumption a consistent look
    /// across both was usually wanted; turned out to just be another case
    /// of "change it in one tab, the other tab silently changes too".
    /// Fully independent now, same as text/box scale and auto-fit.
    @Published var studioOverlayTheme: String {
        didSet { defaults.set(studioOverlayTheme, forKey: Keys.studioOverlayTheme) }
    }

    /// General text-size multiplier for overlay tiles (1.0 = the CSS
    /// defaults). Independent from the per-tile auto-fit in overlay.js,
    /// which additionally shrinks any individual label/value that still
    /// overflows its tile at this base size (e.g. a long filename) — this
    /// setting is "how big overall", auto-fit is "never overflow".
    @Published var overlayTextScale: Double {
        didSet { defaults.set(overlayTextScale, forKey: Keys.overlayTextScale) }
    }

    /// When on (default), a label/value that doesn't fit its tile at the
    /// current text scale is shrunk (CSS `scale()`) just enough to show it
    /// in full, instead of being cut off with "…". Explicit toggle, not
    /// just implied by the text-scale slider.
    @Published var overlayAutoFit: Bool {
        didSet { defaults.set(overlayAutoFit, forKey: Keys.overlayAutoFit) }
    }

    /// Independent of `overlayTextScale` — this resizes the tile boxes
    /// themselves (X = width, Y = height) without changing font size, e.g.
    /// to give more breathing room around small text or fit more/fewer
    /// tiles per row. 1.0 = the overlay's normal box size.
    @Published var overlayBoxWidthScale: Double {
        didSet { defaults.set(overlayBoxWidthScale, forKey: Keys.overlayBoxWidthScale) }
    }
    @Published var overlayBoxHeightScale: Double {
        didSet { defaults.set(overlayBoxHeightScale, forKey: Keys.overlayBoxHeightScale) }
    }

    /// Same 4 settings as above, but for the separate "Overlay Bambu
    /// Studio" source — deliberately **not** shared with the printer
    /// overlay's own theme/scale/box/auto-fit: they used to be, which
    /// meant adjusting a slider in one tab silently changed the other's
    /// OBS source too. Theme (`overlayTheme`) stays shared on purpose —
    /// wasn't part of that complaint, and keeping one consistent look
    /// across both sources is usually what you want anyway.
    @Published var studioOverlayTextScale: Double {
        didSet { defaults.set(studioOverlayTextScale, forKey: Keys.studioOverlayTextScale) }
    }
    @Published var studioOverlayAutoFit: Bool {
        didSet { defaults.set(studioOverlayAutoFit, forKey: Keys.studioOverlayAutoFit) }
    }
    @Published var studioOverlayBoxWidthScale: Double {
        didSet { defaults.set(studioOverlayBoxWidthScale, forKey: Keys.studioOverlayBoxWidthScale) }
    }
    @Published var studioOverlayBoxHeightScale: Double {
        didSet { defaults.set(studioOverlayBoxHeightScale, forKey: Keys.studioOverlayBoxHeightScale) }
    }

    /// Folder to watch for `.3mf` project files (the "Overlay Bambu
    /// Studio" tab always reads the *newest* one in here) — you point this
    /// at wherever you save/export sliced projects, e.g.
    /// "~/Desktop/Bambu Downloads". Empty means the feature is off. See
    /// BambuStudioProjectReader's doc comment for why this can't be
    /// auto-detected reliably.
    @Published var studioProjectFolderPath: String {
        didSet { defaults.set(studioProjectFolderPath, forKey: Keys.studioProjectFolderPath) }
    }

    // MARK: Field visibility + order (dynamic — keyed by flattened field path)
    /// The fields marked visible, **in the order they should appear in the
    /// overlay** — this is what lets you control which tile sits next to
    /// which, instead of an arbitrary/insertion order. Reorder via
    /// `moveField`.
    @Published var visibleFieldOrder: [String] {
        didSet { defaults.set(visibleFieldOrder, forKey: Keys.visibleFieldOrder) }
    }

    // MARK: Custom composite ("combinado") fields
    /// User-created/edited combined fields (e.g. "231/450") — see
    /// CustomComposite. Seeded with 4 examples on first launch; from then
    /// on this is entirely user data, managed from "Campos combinados" in
    /// the menu.
    @Published var customComposites: [CustomComposite] {
        didSet {
            if let data = try? JSONEncoder().encode(customComposites) {
                defaults.set(data, forKey: Keys.customComposites)
            }
        }
    }

    /// Same idea as `customComposites`, but combining fields from the
    /// Studio overlay's own pool (the `.3mf` project settings — layer
    /// height, walls, infill…) instead of the printer's MQTT fields. Kept
    /// as a separate list/array so each overlay's composites only ever
    /// reference that overlay's own fields — no cross-tab key confusion.
    @Published var studioComposites: [CustomComposite] {
        didSet {
            if let data = try? JSONEncoder().encode(studioComposites) {
                defaults.set(data, forKey: Keys.studioComposites)
            }
        }
    }

    // MARK: AMS drying
    /// Per-filament-type thresholds/settings — see DryingProfile.
    @Published var dryingProfiles: [DryingProfile] {
        didSet {
            if let data = try? JSONEncoder().encode(dryingProfiles) {
                defaults.set(data, forKey: Keys.dryingProfiles)
            }
        }
    }
    /// Off by default — deliberately opt-in. On: a slot over its type's
    /// humidity threshold starts drying automatically. Off: only the
    /// manual-action notification fires.
    @Published var autoDryEnabled: Bool {
        didSet { defaults.set(autoDryEnabled, forKey: Keys.autoDryEnabled) }
    }
    /// Off (default): the trigger/threshold is each profile's "max"
    /// (acceptable-but-not-great) humidity. On: the trigger is the more
    /// sensitive "ideal" humidity instead, and an auto-stop cycle (see
    /// `autoHumidityStopEnabled`) targets 1% under ideal rather than 1%
    /// under max.
    @Published var dryToIdealEnabled: Bool {
        didSet { defaults.set(dryToIdealEnabled, forKey: Keys.dryToIdealEnabled) }
    }
    /// Off (default): a cycle just runs for the profile's fixed
    /// `dryDurationHours` (the printer's own timer stops it). On: this app
    /// polls humidity every 5 minutes during an active cycle and sends the
    /// stop command itself once it reads 1% under the target (ideal or
    /// max, per `dryToIdealEnabled`) — the profile's duration field
    /// becomes a safety ceiling only (locked from editing in the UI, since
    /// it's no longer really "the" duration).
    @Published var autoHumidityStopEnabled: Bool {
        didSet { defaults.set(autoHumidityStopEnabled, forKey: Keys.autoHumidityStopEnabled) }
    }
    /// Default for the "girar bobina durante a secagem" toggle offered
    /// every time a cycle is started (confirmation window and automatic
    /// mode alike) — confirmed via a real sniffed cycle from the official
    /// Bambu app that this is a genuine `rotate_tray` field on the
    /// `ams_filament_drying` command, sent as 1/0. On by default (more even
    /// drying); editable per-cycle in the confirmation window regardless.
    @Published var rotateTrayDefaultEnabled: Bool {
        didSet { defaults.set(rotateTrayDefaultEnabled, forKey: Keys.rotateTrayDefaultEnabled) }
    }
    /// Last automatic-drying start time per AMS unit (keyed by its id as a
    /// string) — the safety cooldown in DryingController checks this
    /// before starting another automatic cycle on the same unit.
    private var autoDryLastStart: [String: Date] {
        didSet {
            let encoded = autoDryLastStart.mapValues { $0.timeIntervalSince1970 }
            defaults.set(encoded, forKey: Keys.autoDryLastStart)
        }
    }

    func profile(forFilamentType type: String) -> DryingProfile? {
        dryingProfiles.first { $0.filamentType.caseInsensitiveCompare(type) == .orderedSame }
    }

    func updateDryingProfile(_ profile: DryingProfile) {
        guard let index = dryingProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        dryingProfiles[index] = profile
    }

    func lastAutoDryStart(amsID: Int) -> Date? {
        autoDryLastStart[String(amsID)]
    }

    func recordAutoDryStart(amsID: Int) {
        autoDryLastStart[String(amsID)] = Date()
    }

    private enum Keys {
        static let printerIP = "printerIP"
        static let printerSerial = "printerSerial"
        static let accessCodeAccount = "accessCode"
        static let clientCertPath = "clientCertPath"
        static let clientCertPasswordAccount = "clientCertPassword"
        static let httpPort = "httpPort"
        static let overlayTheme = "overlayTheme"
        static let studioOverlayTheme = "studioOverlayTheme"
        static let overlayTextScale = "overlayTextScale"
        static let overlayBoxWidthScale = "overlayBoxWidthScale"
        static let overlayBoxHeightScale = "overlayBoxHeightScale"
        static let studioOverlayTextScale = "studioOverlayTextScale"
        static let studioOverlayAutoFit = "studioOverlayAutoFit"
        static let studioOverlayBoxWidthScale = "studioOverlayBoxWidthScale"
        static let studioOverlayBoxHeightScale = "studioOverlayBoxHeightScale"
        static let studioProjectFolderPath = "studioProjectFolderPath"
        static let overlayAutoFit = "overlayAutoFit"
        static let visibleFieldOrder = "visibleFieldOrder"
        static let customComposites = "customComposites"
        static let studioComposites = "studioComposites"
        static let dryingProfiles = "dryingProfiles"
        static let autoDryEnabled = "autoDryEnabled"
        static let dryToIdealEnabled = "dryToIdealEnabled"
        static let autoHumidityStopEnabled = "autoHumidityStopEnabled"
        static let rotateTrayDefaultEnabled = "rotateTrayDefaultEnabled"
        static let autoDryLastStart = "autoDryLastStart"
        /// Old key from before ordering existed — an unordered Set. Read
        /// once as a migration fallback so upgrading doesn't wipe out
        /// existing selections (order just starts arbitrary).
        static let legacyVisibleFieldKeys = "visibleFieldKeys"
    }

    private init() {
        printerIP = defaults.string(forKey: Keys.printerIP) ?? ""
        printerSerial = defaults.string(forKey: Keys.printerSerial) ?? ""
        // Diagnostic-only escape hatch: the Keychain read below has been
        // intermittently hanging/timing out on relaunch during testing
        // (see KeychainHelper's 3s timeout) — BSO_ACCESS_CODE_OVERRIDE lets
        // a manual test run skip that read entirely and use a value
        // supplied directly, so a flaky securityd doesn't block testing an
        // otherwise-unrelated MQTT payload change. Never used for the
        // user's normal/production launch path.
        if let override = ProcessInfo.processInfo.environment["BSO_ACCESS_CODE_OVERRIDE"] {
            accessCode = override
        } else {
            accessCode = KeychainHelper.get(account: Self.keychainAccount(Keys.accessCodeAccount)) ?? ""
        }
        clientCertPath = defaults.string(forKey: Keys.clientCertPath) ?? ""
        clientCertPassword = KeychainHelper.get(account: Self.keychainAccount(Keys.clientCertPasswordAccount)) ?? ""
        httpPort = defaults.object(forKey: Keys.httpPort) as? Int ?? 8090
        overlayTheme = defaults.string(forKey: Keys.overlayTheme) ?? "dark"
        studioOverlayTheme = defaults.string(forKey: Keys.studioOverlayTheme) ?? "dark"
        overlayTextScale = defaults.object(forKey: Keys.overlayTextScale) as? Double ?? 1.0
        overlayBoxWidthScale = defaults.object(forKey: Keys.overlayBoxWidthScale) as? Double ?? 1.0
        overlayBoxHeightScale = defaults.object(forKey: Keys.overlayBoxHeightScale) as? Double ?? 1.0
        studioOverlayTextScale = defaults.object(forKey: Keys.studioOverlayTextScale) as? Double ?? 1.0
        studioOverlayBoxWidthScale = defaults.object(forKey: Keys.studioOverlayBoxWidthScale) as? Double ?? 1.0
        studioOverlayBoxHeightScale = defaults.object(forKey: Keys.studioOverlayBoxHeightScale) as? Double ?? 1.0
        studioOverlayAutoFit = defaults.object(forKey: Keys.studioOverlayAutoFit) as? Bool ?? true
        studioProjectFolderPath = defaults.string(forKey: Keys.studioProjectFolderPath) ?? ""
        overlayAutoFit = defaults.object(forKey: Keys.overlayAutoFit) as? Bool ?? true
        visibleFieldOrder = defaults.stringArray(forKey: Keys.visibleFieldOrder)
            ?? defaults.stringArray(forKey: Keys.legacyVisibleFieldKeys)
            ?? []
        if let data = defaults.data(forKey: Keys.customComposites),
           let decoded = try? JSONDecoder().decode([CustomComposite].self, from: data) {
            customComposites = decoded
        } else {
            customComposites = CustomComposite.defaults
        }
        if let data = defaults.data(forKey: Keys.studioComposites),
           let decoded = try? JSONDecoder().decode([CustomComposite].self, from: data) {
            studioComposites = decoded
        } else {
            studioComposites = []
        }
        if let data = defaults.data(forKey: Keys.dryingProfiles),
           let decoded = try? JSONDecoder().decode([DryingProfile].self, from: data) {
            dryingProfiles = decoded
        } else {
            dryingProfiles = DryingProfile.defaults
        }
        autoDryEnabled = defaults.bool(forKey: Keys.autoDryEnabled)
        dryToIdealEnabled = defaults.bool(forKey: Keys.dryToIdealEnabled)
        autoHumidityStopEnabled = defaults.bool(forKey: Keys.autoHumidityStopEnabled)
        rotateTrayDefaultEnabled = defaults.object(forKey: Keys.rotateTrayDefaultEnabled) as? Bool ?? true
        if let raw = defaults.dictionary(forKey: Keys.autoDryLastStart) as? [String: Double] {
            autoDryLastStart = raw.mapValues { Date(timeIntervalSince1970: $0) }
        } else {
            autoDryLastStart = [:]
        }
    }

    func addComposite(_ composite: CustomComposite) {
        customComposites.append(composite)
    }

    func updateComposite(_ composite: CustomComposite) {
        guard let index = customComposites.firstIndex(where: { $0.id == composite.id }) else { return }
        customComposites[index] = composite
    }

    /// Also unselects it from the overlay if it was currently visible —
    /// otherwise a stale key would sit in visibleFieldOrder forever,
    /// resolving to nothing.
    func removeComposite(id: String) {
        customComposites.removeAll { $0.id == id }
        visibleFieldOrder.removeAll { $0 == id }
    }

    func addStudioComposite(_ composite: CustomComposite) {
        studioComposites.append(composite)
    }

    func updateStudioComposite(_ composite: CustomComposite) {
        guard let index = studioComposites.firstIndex(where: { $0.id == composite.id }) else { return }
        studioComposites[index] = composite
    }

    func removeStudioComposite(id: String) {
        studioComposites.removeAll { $0.id == id }
        visibleFieldOrder.removeAll { $0 == id }
    }

    /// Purely additive, idempotent seeding — appends any composite from
    /// `pack` whose `id` isn't already present in `customComposites`
    /// (whether it was there from `.defaults`, added by hand, or seeded by
    /// an earlier call to this same method), and leaves every existing
    /// composite completely untouched otherwise. Safe to call on every
    /// launch. Used to add the "Câmara"/"Mesa"/"Bico"/"Filamento"/
    /// "Secagem"/"Progresso" pack (`CustomComposite.printerInfoPack`)
    /// without disturbing anything already saved.
    func seedAdditionalComposites(_ pack: [CustomComposite]) {
        let existingIDs = Set(customComposites.map(\.id))
        let missing = pack.filter { !existingIDs.contains($0.id) }
        guard !missing.isEmpty else { return }
        customComposites.append(contentsOf: missing)
    }

    var visibleFieldKeys: Set<String> { Set(visibleFieldOrder) }

    func isFieldVisible(_ key: String) -> Bool {
        visibleFieldOrder.contains(key)
    }

    func setField(_ key: String, visible: Bool) {
        if visible {
            if !visibleFieldOrder.contains(key) {
                visibleFieldOrder.append(key)
            }
        } else {
            visibleFieldOrder.removeAll { $0 == key }
        }
    }

    /// Moves a visible field earlier (-1) or later (+1) in the overlay's
    /// left-to-right, top-to-bottom order. No-op at either end.
    func moveField(_ key: String, by offset: Int) {
        guard let index = visibleFieldOrder.firstIndex(of: key) else { return }
        let newIndex = index + offset
        guard newIndex >= 0, newIndex < visibleFieldOrder.count else { return }
        visibleFieldOrder.swapAt(index, newIndex)
    }

    var isConfigured: Bool {
        !printerIP.isEmpty && !printerSerial.isEmpty && !accessCode.isEmpty
    }

    /// Deliberately just the bare URL — no `?theme=`/`&textscale=` baked in.
    /// overlay.js polls `/status` and, whenever the URL doesn't explicitly
    /// pin a value, always uses whatever the app currently has set
    /// (theme, text scale, box width/height, auto-fit). Baking values in
    /// here used to mean the Browser Source needed re-copying every time
    /// you changed the theme/text-size picker in the app — one static link
    /// now covers every appearance setting, changeable live from the menu,
    /// forever.
    var obsURL: String {
        "http://127.0.0.1:\(httpPort)/overlay.html"
    }

    /// Same overlay page, pointed at the separate "Overlay Bambu Studio"
    /// data source (`?statusurl=`) instead of the printer's `/status` —
    /// same server, same port, no second listener. Add this as its own
    /// Browser Source in OBS if you want printer telemetry and slicing
    /// details as two independently-positioned overlays.
    var studioObsURL: String {
        "http://127.0.0.1:\(httpPort)/overlay.html?statusurl=/studio-status"
    }
}
