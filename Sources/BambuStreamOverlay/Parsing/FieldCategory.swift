import Foundation

/// Best-effort category for a field, derived from its raw key — used to
/// group the "add fields" search UI (so e.g. every temperature reading
/// clusters together instead of being scattered across an alphabetical/
/// insertion-order list of 500+ keys) and to label groups in the overlay
/// itself. Purely heuristic — there's no schema, so this is pattern
/// matching on common Bambu field-name fragments, not an exhaustive model.
enum FieldCategory: String, CaseIterable {
    case progress = "Progresso"
    case temperature = "Temperaturas"
    case ams = "AMS / Filamento"
    case fans = "Ventilação"
    case network = "Rede"
    case alerts = "Alertas"
    case combined = "Combinados"
    case other = "Outros"

    static func classify(key: String) -> FieldCategory {
        if key.hasPrefix("composite.") { return .combined }
        let k = key.lowercased()
        if k.contains("ams") || k.contains("tray") || k.contains("filament") { return .ams }
        if k.contains("temper") || k.contains("chamber") { return .temperature }
        if k.contains("fan") || k.contains("spd_lvl") || k.contains("speed") { return .fans }
        if k.contains("wifi") || k.contains("signal") || k.contains("ip") || k.contains("mac") { return .network }
        if k.contains("hms") || k.contains("error") || k.contains("fail") || k.contains("warn") { return .alerts }
        if k.contains("percent") || k.contains("layer") || k.contains("remaining_time")
            || k.contains("stage") || k.contains("gcode_state") || k.contains("print_type")
            || k.contains("subtask") || k.contains("mc_") { return .progress }
        return .other
    }
}

/// A field synthesized by combining two raw fields into one human-friendly
/// value — e.g. layer_num + total_layer_num -> "231/450" — instead of two
/// tiles you have to mentally pair up yourself. User-created and
/// user-editable (see AppSettings.customComposites and the "Campos
/// combinados" section in the menu) — nothing here is hardcoded app
/// behavior, it's just data the user's own composites are made of. Offered
/// as an ordinary selectable field (its `id` doubles as the field key,
/// prefixed "composite.custom." at creation), so it flows through the
/// exact same visibility/ordering/overlay pipeline as any raw field, with
/// no special-casing downstream.
struct CustomComposite: Identifiable, Codable, Equatable {
    /// Doubles as the field key — stable for the composite's lifetime
    /// (generated once at creation), so it keeps working if you rename the
    /// label or change which fields/template it uses later.
    let id: String
    var label: String
    /// One or more source field keys, in the order `{0}`, `{1}`, `{2}`… (as
    /// many as you add) refer to them in `template`. Originally fixed at
    /// exactly two; the editor now lets you add as many as you want via the
    /// "+" button, so any count ≥ 1 is valid here.
    var sourceKeys: [String]
    /// Free-form text with `{0}`, `{1}`, `{2}`… standing in for the source
    /// values in order — e.g. "{0}/{1}", "{0}° / {1}°", "{0}h{1}m{2}s".
    var template: String

    /// Builds the composite FieldEntry if every source field is present in
    /// the current field set (some models/firmware may lack one of them —
    /// in that case the composite just isn't offered, rather than showing a
    /// broken partially-filled value).
    func build(from valuesByKey: [String: String]) -> FieldEntry? {
        guard !sourceKeys.isEmpty else { return nil }
        var value = template
        for (index, key) in sourceKeys.enumerated() {
            guard let v = valuesByKey[key] else { return nil }
            value = value.replacingOccurrences(of: "{\(index)}", with: v)
        }
        return FieldEntry(key: id, label: label, value: value)
    }

    /// Seeded into AppSettings on first launch (and preserved as-is on
    /// upgrade for anyone who already had these selected) — plain data,
    /// editable/deletable from the app exactly like anything you create
    /// yourself.
    static let defaults: [CustomComposite] = [
        CustomComposite(
            id: "composite.layer_progress",
            label: "Progresso de Camada (atual/total)",
            sourceKeys: ["print.layer_num", "print.total_layer_num"],
            template: "{0}/{1}"
        ),
        CustomComposite(
            id: "composite.nozzle_temp",
            label: "Temp. Bico (atual/alvo)",
            sourceKeys: ["print.nozzle_temper", "print.nozzle_target_temper"],
            template: "{0}° / {1}°"
        ),
        CustomComposite(
            id: "composite.bed_temp",
            label: "Temp. Mesa (atual/alvo)",
            sourceKeys: ["print.bed_temper", "print.bed_target_temper"],
            template: "{0}° / {1}°"
        ),
        CustomComposite(
            id: "composite.progress_eta",
            label: "Progresso + Tempo Restante",
            sourceKeys: ["print.mc_percent", "print.mc_remaining_time"],
            template: "{0}% · {1}min restantes"
        )
    ]

    /// Requested pack of printer-info combos (chamber/bed/nozzle/filament/
    /// drying/progress) — added alongside `defaults` without touching them,
    /// via `AppSettings.seedAdditionalComposites`, which only inserts an
    /// entry here if its id isn't already present (so re-running this on
    /// every launch never duplicates or resets one you've since edited).
    ///
    /// Field provenance, verified against a live X2D `/status` dump
    /// (2026-09-02) rather than guessed:
    /// - Chamber: no door-open/closed *sensor* field was found anywhere in
    ///   the raw report (checked `stat`, `home_flag`, `hms` — none decode
    ///   to a clean open/closed bit on this firmware) — "Fechada" here is
    ///   literal fixed text (the user's own wording, quoted, i.e. a label,
    ///   not a live value), paired with the one real chamber temperature
    ///   field that does exist: `device.ctc.info.temp` ("ctc" = chamber
    ///   temperature control).
    /// - Bed "type": no friendly plate-name string exists either; the
    ///   closest real field is the plate profile id `device.plate.cur_id`
    ///   (e.g. "P0101") — an internal id, not a pretty name, but it's what
    ///   the firmware actually reports.
    /// - Nozzle: the simple top-level `nozzle_type`/`nozzle_diameter`/
    ///   `nozzle_temper`/`nozzle_target_temper` fields (already relied on
    ///   by `composite.nozzle_temp` above) — not the newer nested
    ///   `device.nozzle.info[]` dual-nozzle array, which would need picking
    ///   one of the two nozzles arbitrarily.
    /// - Filament/drying: AMS unit 0's first tray (`ams.ams[0].tray[0]`)
    ///   and unit-level drying fields (`ams.ams[0].dry_setting`/`dry_time`/
    ///   `humidity_raw`/`temp`) — matches `ams.tray_now` (0) at capture
    ///   time, and is the same "AMS unit 0" assumption the rest of this
    ///   app already makes throughout the drying feature. If you use a
    ///   different AMS unit or tray day-to-day, edit the field picks here
    ///   (search "ams.ams[1]" etc. in "Adicionar campos" to find the
    ///   equivalent keys for another unit/slot).
    static let printerInfoPack: [CustomComposite] = [
        CustomComposite(
            id: "composite.chamber_info",
            label: "Câmara",
            sourceKeys: ["print.device.ctc.info.temp"],
            template: "Fechada · {0}°C"
        ),
        CustomComposite(
            id: "composite.bed_info",
            label: "Mesa",
            sourceKeys: ["print.device.plate.cur_id", "print.bed_temper", "print.bed_target_temper"],
            template: "{0} · {1}°C/{2}°C"
        ),
        CustomComposite(
            id: "composite.nozzle_full_info",
            label: "Bico",
            sourceKeys: ["print.nozzle_type", "print.nozzle_diameter", "print.nozzle_temper", "print.nozzle_target_temper"],
            template: "{0} {1}mm · {2}°C/{3}°C"
        ),
        CustomComposite(
            id: "composite.filament_info",
            label: "Filamento",
            sourceKeys: [
                "print.ams.ams[0].tray[0].tray_type",
                "print.ams.ams[0].tray[0].tray_diameter",
                "print.ams.ams[0].tray[0].tray_color"
            ],
            template: "{0} · {1}mm · #{2}"
        ),
        CustomComposite(
            id: "composite.drying_info",
            label: "Secagem",
            sourceKeys: [
                "print.ams.ams[0].temp",
                "print.ams.ams[0].dry_setting.dry_temperature",
                "print.ams.ams[0].dry_time",
                "print.ams.ams[0].humidity_raw"
            ],
            template: "{0}°C/{1}°C · {2}min restantes · {3}% umidade"
        ),
        CustomComposite(
            id: "composite.progress_full",
            label: "Progresso",
            sourceKeys: ["print.layer_num", "print.total_layer_num", "print.mc_percent", "print.mc_remaining_time"],
            template: "{0}/{1} · {2}% · {3}min restantes"
        )
    ]

    /// Every composite (from `composites`) whose source fields are all
    /// present right now, given the current flattened field list.
    static func available(_ composites: [CustomComposite], from fields: [FieldEntry]) -> [FieldEntry] {
        var byKey: [String: String] = [:]
        byKey.reserveCapacity(fields.count)
        for f in fields { byKey[f.key] = f.value }
        return composites.compactMap { $0.build(from: byKey) }
    }
}
