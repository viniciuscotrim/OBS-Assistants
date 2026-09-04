import Foundation

/// What triggered a drying alert/decision for one AMS unit.
enum DryingAlertKind {
    /// A single known filament type over its threshold (ideal or max,
    /// depending on `AppSettings.dryToIdealEnabled`).
    case thresholdExceeded(profile: DryingProfile)
    /// A tray whose filament type isn't identified — we deliberately don't
    /// guess a threshold and instead ask you to confirm the type.
    case unknownFilamentType
    /// More than one *different* known filament type shares this AMS
    /// unit's single heated chamber. Always requires your explicit
    /// confirmation, regardless of automatic mode — `safeTempC` is the
    /// lowest drying temperature among every type present (not just the
    /// ones over threshold), so confirming never overheats the more
    /// heat-sensitive material sitting right next to the one that
    /// triggered this.
    case mixedFilamentTypes(types: [String], safeTempC: Double)
}

/// Everything needed to show a notification/confirmation for one AMS unit
/// — humidity is unit-level (one shared chamber/sensor), filament type is
/// per-tray, so this names the specific tray that triggered it while the
/// resulting drying command (if any) targets the whole unit.
struct DryingAlert: Identifiable {
    let id = UUID()
    let amsID: Int
    let trayIndex: Int
    let filamentType: String
    let humidityPercent: Double
    let kind: DryingAlertKind

    var title: String {
        switch kind {
        case .thresholdExceeded:
            return "AMS \(amsID + 1), slot \(trayIndex + 1) (\(filamentType)) — \(Int(humidityPercent))% de umidade"
        case .unknownFilamentType:
            return "AMS \(amsID + 1), slot \(trayIndex + 1) — \(Int(humidityPercent))% de umidade, filamento não identificado"
        case .mixedFilamentTypes(let types, _):
            return "AMS \(amsID + 1) tem \(types.count) filamentos diferentes (\(types.joined(separator: ", "))) — \(Int(humidityPercent))%"
        }
    }

    var body: String {
        switch kind {
        case .thresholdExceeded(let profile):
            return "Acima do recomendado para \(filamentType) (\(Int(profile.maxHumidityPercent))%). Sugestão: \(Int(profile.dryTemperatureC))°C por \(formattedHours(profile.dryDurationHours))."
        case .unknownFilamentType:
            return "Confirme o tipo de filamento pra aplicar o limite certo de umidade."
        case .mixedFilamentTypes(let types, let safeTempC):
            return "Recomendado manter só 1 tipo por AMS. Secar mesmo assim usa \(Int(safeTempC))°C (o limite mais baixo entre \(types.joined(separator: "/"))) pra não derreter nenhum dos dois. Confirme pra continuar."
        }
    }

    /// The profile to pre-fill a confirmation with. For mixed types, a
    /// synthetic profile carrying the capped safe temperature (label isn't
    /// meant to match any real profile — the confirmation view treats this
    /// case specially and doesn't force picking one real type from it).
    var suggestedProfile: DryingProfile? {
        switch kind {
        case .thresholdExceeded(let profile):
            return profile
        case .unknownFilamentType:
            return nil
        case .mixedFilamentTypes(let types, let safeTempC):
            return DryingProfile(filamentType: types.joined(separator: "/"), idealHumidityPercent: 0, maxHumidityPercent: 0, dryTemperatureC: safeTempC, dryDurationHours: 6)
        }
    }

    /// Only an unidentified filament truly *needs* you to pick a type in
    /// the confirmation window before it can proceed — mixed-type already
    /// has a safe, computed temperature and doesn't need a single label.
    var requiresFilamentTypeSelection: Bool {
        if case .unknownFilamentType = kind { return true }
        return false
    }

    private func formattedHours(_ hours: Double) -> String {
        hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }
}

/// One AMS unit's active drying cycle, tracked only when
/// `AppSettings.autoHumidityStopEnabled` is on — polls the unit's humidity
/// every 5 minutes and sends the stop command itself once it reads at or
/// under `targetHumidityPercent`, instead of relying purely on the
/// duration originally sent to the printer.
private struct DryingSession {
    let amsID: Int
    let filamentType: String
    let targetHumidityPercent: Double
    let startedAt: Date
    var lastCheckedAt: Date
}

/// Watches AMS humidity/filament-type readings against the per-type
/// thresholds in AppSettings, and decides what to do about a slot that's
/// over threshold: notify (manual mode) or actually start drying (auto
/// mode, with a cooldown so a still-humid reading right after starting a
/// cycle doesn't restart it in a loop). Also owns the optional
/// humidity-based auto-stop monitoring loop.
///
/// **Automatic mode (auto-start and humidity-based auto-stop) is
/// currently disabled at the code level — see `automationSupported`
/// below — regardless of what `AppSettings.autoDryEnabled` /
/// `autoHumidityStopEnabled` happen to be persisted as.** Confirmed on a
/// real X2D (github.com/viniciuscotrim/OBS-Assistants/issues/2): newer
/// firmware requires `ams_filament_drying` to carry a cryptographic
/// signature only Bambu Lab's own software can produce — sent without it,
/// the printer accepts the MQTT publish with no error but never actually
/// starts/stops drying. An *automatic*, unattended command that silently
/// does nothing is worse than no automation at all — it would look like
/// it worked. The corresponding toggles are also disabled in the UI (see
/// PrinterOverlayView/DryConfirmationView) so they can't be turned on in
/// the first place; this is the belt-and-suspenders code-level guard in
/// case a persisted value from before this change is still `true`.
final class DryingController {
    /// See the class doc comment — hard-disables automatic start/stop
    /// regardless of the persisted settings, until Bambu Lab exposes an
    /// official, sanctioned way for third-party software to sign this
    /// command (or ships a firmware/API path that doesn't require it).
    private static let automationSupported = false
    /// A baseline used only to decide whether an *unidentified* filament's
    /// slot is worth bothering you about at all — real per-type thresholds
    /// never apply to an unknown type (see DryingAlertKind.unknownFilamentType).
    /// Chosen as roughly the lowest "probably fine" ceiling across the
    /// default profiles, so it under-alerts rather than over-alerts.
    private static let unknownTypeAttentionThreshold: Double = 20

    /// Minimum gap after a cycle's own duration before another *automatic*
    /// cycle can start on the same AMS unit — the safety cooldown from the
    /// spec, so a slot that's still reading high right as a cycle ends
    /// doesn't immediately restart it.
    private static let cooldownPadding: TimeInterval = 30 * 60

    /// How often the humidity-based auto-stop loop re-checks an active
    /// cycle's unit.
    private static let humidityPollInterval: TimeInterval = 5 * 60

    /// Absolute backstop regardless of settings, in case a sensor never
    /// reports a value under target — humidity-based auto-stop still stops
    /// eventually rather than running forever.
    private static let maxSessionDuration: TimeInterval = 16 * 3600

    private let settings: AppSettings
    private let sendDryingCommand: (_ amsID: Int, _ filamentType: String, _ tempC: Double, _ coolingTempC: Double, _ durationHours: Double, _ rotateTray: Bool, _ mode: Int) -> Void

    /// AMS units currently past their alert condition — so a report every
    /// few seconds doesn't re-fire a notification/auto-cycle every single
    /// time while humidity stays elevated. Cleared once a unit reads back
    /// under threshold, so a later re-crossing alerts again.
    private var activeAlerts: Set<Int> = []
    private var activeSessions: [Int: DryingSession] = [:]

    var onManualAlert: ((DryingAlert) -> Void)?
    var onAutoDryStarted: ((DryingAlert, DryingProfile) -> Void)?
    var onAutoDryStopped: ((_ amsID: Int, _ humidityPercent: Double) -> Void)?

    init(
        settings: AppSettings,
        sendDryingCommand: @escaping (_ amsID: Int, _ filamentType: String, _ tempC: Double, _ coolingTempC: Double, _ durationHours: Double, _ rotateTray: Bool, _ mode: Int) -> Void
    ) {
        self.settings = settings
        self.sendDryingCommand = sendDryingCommand
    }

    func evaluate(slots: [AMSSlotStatus]) {
        let byUnit = Dictionary(grouping: slots, by: { $0.amsID })
        checkActiveSessions(byUnit: byUnit)

        var unitsStillAlerting: Set<Int> = []

        for (amsID, unitSlots) in byUnit {
            guard let alert = worstAlert(amsID: amsID, unitSlots: unitSlots) else { continue }
            unitsStillAlerting.insert(amsID)

            guard !activeAlerts.contains(amsID) else { continue } // already notified/acted on this crossing
            activeAlerts.insert(amsID)

            // Mixed filament types never auto-start silently, no matter
            // what automatic mode says — always route through the
            // notify-then-confirm path.
            let canActAutomatically: Bool
            if case .mixedFilamentTypes = alert.kind { canActAutomatically = false } else { canActAutomatically = true }

            if Self.automationSupported, settings.autoDryEnabled, canActAutomatically, let profile = alert.suggestedProfile {
                if isCooldownElapsed(amsID: amsID, profile: profile) {
                    startDrying(amsID: amsID, profile: profile, rotateTray: settings.rotateTrayDefaultEnabled, alert: alert)
                } else {
                    // Auto mode wants to act but is cooling down — still
                    // surface it manually so it isn't silently dropped.
                    onManualAlert?(alert)
                }
            } else {
                onManualAlert?(alert)
            }
        }

        // A unit that's no longer in this report's alerting set has
        // recovered (or its AMS/slots disappeared) — clear it so the next
        // time it crosses the threshold, it alerts again instead of
        // staying silently suppressed forever.
        activeAlerts = activeAlerts.intersection(unitsStillAlerting)
    }

    /// Shared by both the automatic path above and AppState's
    /// manual-confirmation path — actually sends the command and, if
    /// enabled, registers the humidity-polling session.
    func startDrying(amsID: Int, profile: DryingProfile, rotateTray: Bool, alert: DryingAlert?) {
        sendDryingCommand(amsID, profile.filamentType, profile.dryTemperatureC, profile.coolingTemperatureC, profile.dryDurationHours, rotateTray, 1)
        settings.recordAutoDryStart(amsID: amsID)
        if let alert {
            onAutoDryStarted?(alert, profile)
        }
        if Self.automationSupported, settings.autoHumidityStopEnabled {
            let target = (settings.dryToIdealEnabled ? profile.idealHumidityPercent : profile.maxHumidityPercent) - 1
            activeSessions[amsID] = DryingSession(amsID: amsID, filamentType: profile.filamentType, targetHumidityPercent: max(0, target), startedAt: Date(), lastCheckedAt: Date())
        }
    }

    /// One AMS unit can have multiple trays loaded with different
    /// materials sharing one humidity reading.
    ///  1. An unidentified filament takes priority — can't be dried safely
    ///     without knowing what it is.
    ///  2. More than one *distinct* known type sharing the chamber is
    ///     always a mixed-type alert, using the lowest drying temperature
    ///     across every type present (not just the one(s) over threshold)
    ///     as the safe cap.
    ///  3. Otherwise, the single known type, if it's over its threshold
    ///     (ideal or max, per `dryToIdealEnabled`).
    private func worstAlert(amsID: Int, unitSlots allSlots: [AMSSlotStatus]) -> DryingAlert? {
        // Empty slots (nothing physically loaded) aren't "unidentified" —
        // there's nothing there to dry or confirm a type for. Filtering
        // these out first is what stops an empty slot from triggering the
        // same "confirm the filament type" alert as a loaded-but-unread one.
        let unitSlots = allSlots.filter { $0.hasFilamentLoaded }
        guard let humidity = unitSlots.first(where: { $0.humidityPercent != nil })?.humidityPercent else {
            return nil // no % reading for this unit (older AMS without a real RH sensor) — nothing to compare
        }

        if let unidentified = unitSlots.first(where: { !$0.isFilamentTypeKnown }), humidity > Self.unknownTypeAttentionThreshold {
            return DryingAlert(amsID: amsID, trayIndex: unidentified.trayIndex, filamentType: "?", humidityPercent: humidity, kind: .unknownFilamentType)
        }

        let knownSlots = unitSlots.filter { $0.isFilamentTypeKnown }
        let distinctTypes = Array(Set(knownSlots.map { $0.filamentTypeDisplay })).sorted()
        guard !distinctTypes.isEmpty else { return nil }

        let profilesByType: [String: DryingProfile] = distinctTypes.reduce(into: [:]) { dict, type in
            if let p = settings.profile(forFilamentType: type) { dict[type] = p }
        }

        func triggerThreshold(_ profile: DryingProfile) -> Double {
            settings.dryToIdealEnabled ? profile.idealHumidityPercent : profile.maxHumidityPercent
        }

        let anyExceeded = profilesByType.values.contains { humidity > triggerThreshold($0) }
        guard anyExceeded else { return nil }

        if distinctTypes.count > 1 {
            let safeTemp = profilesByType.values.map(\.dryTemperatureC).min() ?? profilesByType.values.first?.dryTemperatureC ?? 45
            let firstSlot = knownSlots.first { profilesByType[$0.filamentTypeDisplay] != nil } ?? knownSlots[0]
            return DryingAlert(amsID: amsID, trayIndex: firstSlot.trayIndex, filamentType: distinctTypes.joined(separator: "/"), humidityPercent: humidity, kind: .mixedFilamentTypes(types: distinctTypes, safeTempC: safeTemp))
        }

        // Exactly one distinct type present and over its threshold.
        guard let onlySlot = knownSlots.first, let profile = profilesByType[onlySlot.filamentTypeDisplay] else { return nil }
        return DryingAlert(amsID: amsID, trayIndex: onlySlot.trayIndex, filamentType: onlySlot.filamentTypeDisplay, humidityPercent: humidity, kind: .thresholdExceeded(profile: profile))
    }

    private func isCooldownElapsed(amsID: Int, profile: DryingProfile) -> Bool {
        guard let last = settings.lastAutoDryStart(amsID: amsID) else { return true }
        let readyAt = last.addingTimeInterval(profile.dryDurationHours * 3600 + Self.cooldownPadding)
        return Date() >= readyAt
    }

    // MARK: - Humidity-based auto-stop monitoring

    private func checkActiveSessions(byUnit: [Int: [AMSSlotStatus]]) {
        guard !activeSessions.isEmpty else { return }
        let now = Date()

        for (amsID, session) in activeSessions {
            let elapsed = now.timeIntervalSince(session.lastCheckedAt)
            let totalElapsed = now.timeIntervalSince(session.startedAt)

            guard elapsed >= Self.humidityPollInterval || totalElapsed >= Self.maxSessionDuration else { continue }

            let humidity = byUnit[amsID]?.first(where: { $0.humidityPercent != nil })?.humidityPercent

            if let humidity, humidity <= session.targetHumidityPercent {
                sendDryingCommand(amsID, session.filamentType, 0, 0, 0, false, 0)
                activeSessions.removeValue(forKey: amsID)
                onAutoDryStopped?(amsID, humidity)
            } else if totalElapsed >= Self.maxSessionDuration {
                // Safety backstop — stop regardless of the last reading so
                // a stuck/absent sensor can't keep a cycle running forever.
                sendDryingCommand(amsID, session.filamentType, 0, 0, 0, false, 0)
                activeSessions.removeValue(forKey: amsID)
                onAutoDryStopped?(amsID, humidity ?? session.targetHumidityPercent)
            } else {
                activeSessions[amsID]?.lastCheckedAt = now
            }
        }
    }
}
