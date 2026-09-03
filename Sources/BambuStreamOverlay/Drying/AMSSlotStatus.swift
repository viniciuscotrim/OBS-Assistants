import Foundation

/// One AMS tray's parsed status, extracted from the printer's flattened
/// MQTT report — humidity and filament type, ready for threshold
/// comparison instead of raw string keys.
struct AMSSlotStatus: Identifiable, Equatable {
    /// e.g. "0-2" (AMS unit 0, tray 2) — stable across reports, used for
    /// cooldown tracking and to key the confirmation UI.
    var id: String { "\(amsID)-\(trayIndex)" }
    let amsID: Int
    let trayIndex: Int
    /// Percent relative humidity, when the AMS reports an actual
    /// measurement (`humidity_raw` — this is what AMS 2 Pro's real RH
    /// sensor sends). This is the only value ever compared against the
    /// percent thresholds in DryingProfile.
    let humidityPercent: Double?
    /// The coarse 1–5 "how damp" index every AMS (including ones without a
    /// real RH sensor) reports as `humidity`. Not a percentage and not
    /// linear, so it's never compared against a percent threshold — shown
    /// as-is in the UI (e.g. "Índice 2/5") when `humidityPercent` isn't
    /// available, so at least *something* shows instead of nothing.
    let humidityIndex: Int?
    /// Raw `tray_type` string (PLA, PETG, ABS, ...), or nil when the AMS
    /// hasn't identified anything in that slot (RFID not read yet).
    let filamentType: String?
    let trayColor: String?
    /// False for a slot with nothing physically loaded — the printer's
    /// object for an empty slot is a bare `{"id": ..., "state": ...}` with
    /// no `tray_type` key at all (not even an empty string), unlike a
    /// loaded spool whose RFID just hasn't been read yet, which still
    /// reports `tray_type: ""` among a full set of other tray fields. This
    /// distinguishes "nothing to dry here" from "there's filament here but
    /// we don't know what it is" — conflating the two used to make an
    /// empty slot trigger the same "confirm the filament type" alert as an
    /// unidentified one.
    let hasFilamentLoaded: Bool
    /// The printer's own ground truth for whether a drying cycle is
    /// actually active on this tray's AMS unit — from
    /// `ams[N].dry_setting`, which reports `dry_temperature: -1`,
    /// `dry_filament: ""`, `dry_duration: -1` when nothing is running.
    /// This is what confirms (or disproves) that `ams_filament_drying`
    /// actually took effect, since the command itself gets no ack over
    /// MQTT — the UI shows this instead of just trusting the command was
    /// sent.
    let activeDrying: AMSDryStatus?
    /// The AMS unit's own internal temperature right now (`ams[N].temp`)
    /// — not a target, the actual measured chamber temperature.
    let chamberTemperatureC: Double?

    var filamentTypeDisplay: String { filamentType?.isEmpty == false ? filamentType! : "?" }
    var isFilamentTypeKnown: Bool { filamentType?.isEmpty == false }
    /// True only for a real percent reading — this, not `humidityIndex`,
    /// is what threshold comparisons require.
    var hasUsableHumidityReading: Bool { humidityPercent != nil }
}

/// The printer's own report of an AMS unit's current drying cycle (or lack
/// of one), from `ams[N].dry_setting` (target) plus the sibling `dry_time`
/// field (elapsed) — both are the printer's ground truth, not anything
/// this app assumed or requested.
struct AMSDryStatus: Equatable {
    let filamentType: String
    let targetTemperatureC: Double
    let targetDurationHours: Double
    /// Elapsed time since the cycle started, straight from `ams[N].dry_time`.
    /// Unit is unconfirmed (the firmware doesn't document this field) —
    /// treated as minutes, the common convention for this kind of counter;
    /// shown alongside the raw number so it's checkable against the real
    /// elapsed wall-clock time during your first manual test.
    let elapsedMinutesRaw: Double
    var isActive: Bool { targetTemperatureC >= 0 && targetDurationHours >= 0 && !filamentType.isEmpty }
    var elapsedHours: Double { elapsedMinutesRaw / 60 }
}

enum AMSSlotParser {
    /// Scans the raw (unflattened) MQTT snapshot for every `print.ams.ams[N].tray[M]`
    /// entry and extracts what's needed for drying decisions — kept
    /// separate from the generic flatten used for overlay fields since this
    /// needs structured per-slot access (humidity paired with the right
    /// tray), not a flat key/value list.
    static func parse(rawSnapshot: [String: Any]) -> [AMSSlotStatus] {
        guard let print = rawSnapshot["print"] as? [String: Any],
              let amsRoot = print["ams"] as? [String: Any],
              let amsList = amsRoot["ams"] as? [[String: Any]] else {
            return []
        }

        var results: [AMSSlotStatus] = []
        for amsUnit in amsList {
            guard let amsIDString = amsUnit["id"] as? String, let amsID = Int(amsIDString) else { continue }
            let humidityPercent = numericValue(amsUnit["humidity_raw"])
            let humidityIndex = numericValue(amsUnit["humidity"]).map { Int($0) }
            let chamberTemp = numericValue(amsUnit["temp"])
            let dryStatus: AMSDryStatus?
            if let drySetting = amsUnit["dry_setting"] as? [String: Any] {
                dryStatus = AMSDryStatus(
                    filamentType: (drySetting["dry_filament"] as? String) ?? "",
                    targetTemperatureC: numericValue(drySetting["dry_temperature"]) ?? -1,
                    targetDurationHours: numericValue(drySetting["dry_duration"]) ?? -1,
                    elapsedMinutesRaw: numericValue(amsUnit["dry_time"]) ?? 0
                )
            } else {
                dryStatus = nil
            }
            guard let trays = amsUnit["tray"] as? [[String: Any]] else { continue }
            for tray in trays {
                guard let trayIDString = tray["id"] as? String, let trayIndex = Int(trayIDString) else { continue }
                let type = (tray["tray_type"] as? String)?.trimmingCharacters(in: .whitespaces)
                let color = tray["tray_color"] as? String
                // The *key* being present at all (even as "") is what
                // means "there's a spool here" — a genuinely empty slot's
                // object doesn't have a tray_type key to begin with.
                let hasFilamentLoaded = tray["tray_type"] != nil
                results.append(AMSSlotStatus(
                    amsID: amsID,
                    trayIndex: trayIndex,
                    humidityPercent: humidityPercent,
                    humidityIndex: humidityIndex,
                    filamentType: type,
                    trayColor: color,
                    hasFilamentLoaded: hasFilamentLoaded,
                    activeDrying: dryStatus,
                    chamberTemperatureC: chamberTemp
                ))
            }
        }
        return results
    }

    private static func numericValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
