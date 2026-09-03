import Foundation

/// One leaf value out of the printer's MQTT report, flattened to a dotted
/// path (objects) / bracketed index (arrays) so that *any* field the
/// printer sends — regardless of model/firmware — shows up automatically,
/// with no hardcoded schema. e.g.:
///   "print.mc_percent"                 -> "42"
///   "print.ams.ams[0].tray[2].tray_color" -> "F4E409FF"
///   "print.nozzle_temper"              -> "219.4"
struct FieldEntry: Identifiable, Codable, Equatable {
    var id: String { key }
    let key: String
    let label: String
    var value: String
}

/// Accumulates the merged, flattened view of everything the printer has
/// reported so far. Bambu printers (especially P1-series) send *delta*
/// reports — only keys that changed since the last message — so we do a
/// recursive merge into a running snapshot rather than replacing it, and
/// then flatten the full snapshot on every update. Field order is
/// "first seen" so the UI list doesn't reshuffle as updates come in.
final class PrinterReportStore {
    private(set) var rawSnapshot: [String: Any] = [:]
    private var orderedKeys: [String] = []
    private var orderIndex: [String: Int] = [:]

    /// Merge a newly-received JSON object (already decoded, typically the
    /// contents of payload["print"]) into the running snapshot.
    func merge(_ incoming: [String: Any]) {
        rawSnapshot = Self.deepMerge(rawSnapshot, incoming)
    }

    func reset() {
        rawSnapshot = [:]
        orderedKeys = []
        orderIndex = [:]
    }

    /// Flatten the current snapshot into a stably-ordered field list.
    func flattenedFields() -> [FieldEntry] {
        var flat: [String: String] = [:]
        Self.flatten(prefix: "", value: rawSnapshot, into: &flat)

        for key in flat.keys where orderIndex[key] == nil {
            orderIndex[key] = orderedKeys.count
            orderedKeys.append(key)
        }

        return orderedKeys.compactMap { key in
            guard let value = flat[key] else { return nil }
            return FieldEntry(key: key, label: Self.humanize(key), value: value)
        }
    }

    // MARK: - Flatten

    private static func flatten(prefix: String, value: Any, into out: inout [String: String]) {
        switch value {
        case let dict as [String: Any]:
            for (k, v) in dict {
                let path = prefix.isEmpty ? k : "\(prefix).\(k)"
                flatten(prefix: path, value: v, into: &out)
            }
        case let array as [Any]:
            if array.isEmpty {
                out[prefix] = "[]"
            }
            for (i, v) in array.enumerated() {
                let path = "\(prefix)[\(i)]"
                flatten(prefix: path, value: v, into: &out)
            }
        case let n as NSNumber:
            // Distinguish real bools from 0/1 NSNumbers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                out[prefix] = n.boolValue ? "true" : "false"
            } else {
                out[prefix] = n.stringValue
            }
        case let s as String:
            out[prefix] = s
        case is NSNull:
            out[prefix] = ""
        default:
            out[prefix] = "\(value)"
        }
    }

    /// Recursive JSON-merge-patch style merge: dictionaries merge key by
    /// key. Arrays of objects that carry an "id" (AMS units, trays, ...)
    /// merge element-by-element matched on that id, instead of the whole
    /// array just replacing the old one — Bambu doesn't always resend every
    /// field for an object in every update (e.g. an AMS unit's
    /// `humidity_raw` has been observed present in some messages and
    /// absent in others for the same unit), and naively replacing the
    /// array would silently drop already-known fields the moment one
    /// update omits them. Any other array (plain values, or objects
    /// without an "id") is still replaced wholesale, same as before.
    private static func deepMerge(_ base: [String: Any], _ incoming: [String: Any]) -> [String: Any] {
        var result = base
        for (key, newValue) in incoming {
            if let newDict = newValue as? [String: Any], let oldDict = result[key] as? [String: Any] {
                result[key] = deepMerge(oldDict, newDict)
            } else if let newArray = newValue as? [Any], let oldArray = result[key] as? [Any],
                      let merged = mergeArrayByID(old: oldArray, incoming: newArray) {
                result[key] = merged
            } else {
                result[key] = newValue
            }
        }
        return result
    }

    /// Merges two arrays element-by-element when every element in both is a
    /// `[String: Any]` dictionary with a matching "id" field (String or
    /// number, compared as strings). Returns nil (meaning "just replace
    /// wholesale") if either array doesn't fit that shape — e.g. arrays of
    /// plain numbers/strings, which really are meant to be replaced
    /// outright.
    private static func mergeArrayByID(old: [Any], incoming: [Any]) -> [Any]? {
        func idString(_ any: Any) -> String? {
            guard let dict = any as? [String: Any], let idValue = dict["id"] else { return nil }
            if let s = idValue as? String { return s }
            if let n = idValue as? NSNumber { return n.stringValue }
            return nil
        }

        var oldByID: [String: [String: Any]] = [:]
        var oldOrder: [String] = []
        for element in old {
            guard let id = idString(element), let dict = element as? [String: Any] else { return nil }
            oldByID[id] = dict
            oldOrder.append(id)
        }

        var mergedByID = oldByID
        var order = oldOrder
        for element in incoming {
            guard let id = idString(element), let dict = element as? [String: Any] else { return nil }
            if let existing = mergedByID[id] {
                mergedByID[id] = deepMerge(existing, dict)
            } else {
                mergedByID[id] = dict
                order.append(id)
            }
        }

        return order.compactMap { mergedByID[$0] }
    }

    /// Turns "print.ams.ams[0].tray[2].tray_color" into
    /// "Print · Ams · Ams 0 · Tray 2 · Tray Color" for a friendlier label,
    /// while `key` (used for the checkbox / persistence identity, and shown
    /// as caption text) keeps the exact raw path.
    private static func humanize(_ key: String) -> String {
        let withSpaces = key
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: ".", with: " . ")
            .replacingOccurrences(of: "_", with: " ")
        let parts = withSpaces.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }
        let titled = parts.map { part -> String in
            part.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return titled.joined(separator: " · ")
    }
}
