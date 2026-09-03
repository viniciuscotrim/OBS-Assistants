import Foundation

/// Per-filament-type drying settings — one row per material in the
/// "Secagem do AMS" section of the menu. Seeded with commonly-cited
/// starting points (in the spirit of Bambu's published Filament Drying
/// Guide) but 100% editable/persisted; nothing here is authoritative,
/// it's just a sane default to tweak.
struct DryingProfile: Identifiable, Codable, Equatable {
    /// The filament type string as it appears in `tray_type` (PLA, PETG,
    /// ABS, ...) — doubles as the stable identity for persistence.
    var id: String { filamentType }
    var filamentType: String
    /// Percent RH this material is happiest below — the trigger threshold
    /// when "Secar Ideal" is on, and (minus 1%) the stop target for
    /// humidity-based auto-stop. Should be lower than `maxHumidityPercent`.
    var idealHumidityPercent: Double
    /// Percent RH this material can tolerate before it's a real problem —
    /// the trigger threshold when "Secar Ideal" is off (the default).
    var maxHumidityPercent: Double
    /// °C. The AMS 2 Pro's drying heater tops out well under most external
    /// dryers; keep this sane — UI warns above 65.
    var dryTemperatureC: Double
    /// Used as the printer-side safety ceiling on every cycle (in case the
    /// live humidity-based stop, if enabled, never fires) — and as the
    /// actual fixed cycle length when humidity-based auto-stop is off.
    var dryDurationHours: Double
    /// °C the chamber holds at once the active heating phase finishes —
    /// the `cooling_temp` field the printer's own MQTT command expects
    /// (confirmed by sniffing a real cycle started from the official Bambu
    /// app: PETG at 65°C drying used 60°C here). Defaults a few degrees
    /// under `dryTemperatureC` for profiles that predate this field.
    var coolingTemperatureC: Double

    static let temperatureWarningRange: ClosedRange<Double> = 45...65

    var isTemperatureOutOfRecommendedRange: Bool {
        !Self.temperatureWarningRange.contains(dryTemperatureC)
    }

    var isIdealBelowMax: Bool {
        idealHumidityPercent < maxHumidityPercent
    }

    init(filamentType: String, idealHumidityPercent: Double, maxHumidityPercent: Double, dryTemperatureC: Double, dryDurationHours: Double, coolingTemperatureC: Double? = nil) {
        self.filamentType = filamentType
        self.idealHumidityPercent = idealHumidityPercent
        self.maxHumidityPercent = maxHumidityPercent
        self.dryTemperatureC = dryTemperatureC
        self.dryDurationHours = dryDurationHours
        self.coolingTemperatureC = coolingTemperatureC ?? max(0, dryTemperatureC - 5)
    }

    /// Migration for profiles persisted before "ideal humidity"/"cooling
    /// temperature" existed: those keys just won't be in older JSON, so
    /// decode them as optional and fall back to sane derived values — never
    /// fail to decode an existing user's saved profiles over adding a field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filamentType = try container.decode(String.self, forKey: .filamentType)
        maxHumidityPercent = try container.decode(Double.self, forKey: .maxHumidityPercent)
        dryTemperatureC = try container.decode(Double.self, forKey: .dryTemperatureC)
        dryDurationHours = try container.decode(Double.self, forKey: .dryDurationHours)
        idealHumidityPercent = try container.decodeIfPresent(Double.self, forKey: .idealHumidityPercent)
            ?? max(0, maxHumidityPercent - 5)
        coolingTemperatureC = try container.decodeIfPresent(Double.self, forKey: .coolingTemperatureC)
            ?? max(0, dryTemperatureC - 5)
    }

    /// Starting points only — edit freely in the app. Rough figures
    /// commonly cited for AMS-scale drying (short cycles in an enclosed,
    /// gently-heated chamber, not a dedicated high-temp external dryer).
    static let defaults: [DryingProfile] = [
        DryingProfile(filamentType: "PLA", idealHumidityPercent: 12, maxHumidityPercent: 20, dryTemperatureC: 45, dryDurationHours: 8),
        DryingProfile(filamentType: "PETG", idealHumidityPercent: 12, maxHumidityPercent: 20, dryTemperatureC: 65, dryDurationHours: 8),
        DryingProfile(filamentType: "ABS", idealHumidityPercent: 8, maxHumidityPercent: 15, dryTemperatureC: 55, dryDurationHours: 4),
        DryingProfile(filamentType: "ASA", idealHumidityPercent: 8, maxHumidityPercent: 15, dryTemperatureC: 55, dryDurationHours: 4),
        DryingProfile(filamentType: "TPU", idealHumidityPercent: 12, maxHumidityPercent: 20, dryTemperatureC: 45, dryDurationHours: 6),
        DryingProfile(filamentType: "PC", idealHumidityPercent: 6, maxHumidityPercent: 10, dryTemperatureC: 65, dryDurationHours: 10),
        DryingProfile(filamentType: "PA", idealHumidityPercent: 6, maxHumidityPercent: 10, dryTemperatureC: 65, dryDurationHours: 12),
        DryingProfile(filamentType: "PVA", idealHumidityPercent: 6, maxHumidityPercent: 10, dryTemperatureC: 45, dryDurationHours: 8)
    ]
}
