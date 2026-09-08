import Foundation

/// Reads slicing details (layer height, walls, infill, line width, nozzle
/// diameter) out of a `.3mf` project file Bambu Studio saved locally.
///
/// There is no reliable place Bambu Studio itself caches "the project file
/// for whatever's currently printing" on macOS — its own cache directory
/// only holds fonts/lockfiles, and its logs are encrypted, so this can't
/// confirm a path automatically. Instead this watches a **folder you point
/// it at** (Settings > Studio project folder) and always uses the most
/// recently modified `.3mf` in it — matching how Bambu Studio itself saves
/// a new file into the same export/download folder each time you slice.
///
/// A `.3mf` is a plain ZIP; the slicing parameters live in
/// `Metadata/project_settings.config`, a flat JSON object. Confirmed
/// against a real sliced project (2026-09-02) rather than guessed — see
/// the specific keys pulled out in `relevantKeys`.
enum BambuStudioProjectReader {
    /// The rendered plate preview Bambu Studio embeds alongside
    /// `project_settings.config` once a plate is sliced — the same image
    /// shown in Studio's own plate/slice summary. Confirmed against a real
    /// downloaded/sliced project (2026-09-08): a plain "Save Project"
    /// `.3mf` has no embedded G-code (so no live layer-by-layer toolpath is
    /// possible from this file alone — see the "Preview 3D" README
    /// section), but always has these pre-rendered PNGs.
    struct PlatePreview {
        let fileName: String
        let modifiedAt: Date
        let imageData: Data
        /// Which member this came from — `plate_1.png` (lit iso-view
        /// render, the usual "expected result" shot) preferred, falling
        /// back to `top_1.png` then `pick_1.png` if that one's missing.
        let sourceMember: String
    }

    /// Finds the newest `.3mf` in `folderPath` and returns its plate-1
    /// preview image, trying each candidate member in order. Only ever
    /// plate 1 — good enough for the common single-plate print; a
    /// multi-plate project just shows the first plate's preview. Returns
    /// nil if the folder's empty/unreadable or none of the candidates are
    /// present (e.g. a non-Bambu-Studio `.3mf`).
    static func readNewestPlatePreview(inFolder folderPath: String) -> PlatePreview? {
        guard let fileURL = newestProjectFile(inFolder: folderPath) else { return nil }
        let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let candidates = ["Metadata/plate_1.png", "Metadata/top_1.png", "Metadata/pick_1.png"]
        for member in candidates {
            if let data = extractMember(from: fileURL, member: member) {
                return PlatePreview(fileName: fileURL.lastPathComponent, modifiedAt: modifiedAt, imageData: data, sourceMember: member)
            }
        }
        return nil
    }

    struct ProjectInfo {
        let fileName: String
        let modifiedAt: Date
        let fields: [FieldEntry]
    }

    /// Finds the newest `.3mf` in `folderPath` and extracts **every** key
    /// in its `project_settings.config` — a real project has ~470 of them
    /// (confirmed on 2026-09-02), everything from `layer_height` down to
    /// per-material speed/acceleration overrides — searchable the same way
    /// the printer's 500+ MQTT fields already are, rather than a fixed
    /// curated subset. Returns nil if the folder is empty/unreadable, or
    /// the newest file has no readable `project_settings.config` (e.g. not
    /// actually a Bambu Studio 3MF).
    static func readNewestProject(inFolder folderPath: String) -> ProjectInfo? {
        let expanded = (folderPath as NSString).expandingTildeInPath
        let folderURL = URL(fileURLWithPath: expanded, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let threeMFs = contents.filter { $0.pathExtension.lowercased() == "3mf" }
        guard let newest = threeMFs.max(by: { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l < r
        }) else { return nil }

        let modifiedAt = (try? newest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()

        guard let configData = extractConfigMember(from: newest) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else { return nil }

        let fields = json.keys.sorted().compactMap { key -> FieldEntry? in
            guard let raw = json[key] else { return nil }
            let value = Self.displayString(for: raw)
            return FieldEntry(key: "studio.\(key)", label: Self.humanize(key), value: value)
        }
        return ProjectInfo(fileName: newest.lastPathComponent, modifiedAt: modifiedAt, fields: fields)
    }

    /// "sparse_infill_density" -> "Sparse Infill Density" — same spirit as
    /// PrinterReport's humanize, simplified for this file's flat,
    /// dot-free, bracket-free snake_case keys.
    private static func humanize(_ key: String) -> String {
        key.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// A `.3mf` is a plain ZIP archive — shells out to the system `unzip`
    /// (`-p` streams one member to stdout) rather than hand-rolling a ZIP
    /// reader for one file lookup.
    private static func extractConfigMember(from fileURL: URL) -> Data? {
        extractMember(from: fileURL, member: "Metadata/project_settings.config")
    }

    /// General-purpose "read one member out of this .3mf's ZIP" — same
    /// `unzip -p` shell-out `extractConfigMember` uses, just parameterized
    /// on the member path. Used by `GCodeToolpathParser` to pull out
    /// `Metadata/plate_N.gcode` (the sliced toolpath Bambu Studio embeds
    /// alongside `project_settings.config` once you've sliced) — same file,
    /// same folder-watch, no separate connection to the printer needed.
    static func extractMember(from fileURL: URL, member: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", fileURL.path, member]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard "unzip -p" noise on stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    /// Lists every member name in the .3mf's ZIP (`unzip -l`, names only) —
    /// diagnostic use (see `OA_INSPECT_3MF`) to confirm real member names
    /// (e.g. which plate's gcode is embedded) against an actual sliced
    /// project instead of assuming Bambu Studio's naming convention.
    static func listMembers(of fileURL: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", fileURL.path] // -Z1: zipinfo, names only
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Newest `.3mf` in `folderPath`, or nil — same "always the most
    /// recently modified one" rule `readNewestProject` uses, factored out
    /// so the toolpath path can reuse it without re-reading project_settings.
    static func newestProjectFile(inFolder folderPath: String) -> URL? {
        let expanded = (folderPath as NSString).expandingTildeInPath
        let folderURL = URL(fileURLWithPath: expanded, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let threeMFs = contents.filter { $0.pathExtension.lowercased() == "3mf" }
        return threeMFs.max(by: { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l < r
        })
    }

    /// Many config values are arrays internally — one entry per
    /// extruder/filament-slot/quality-preset override, e.g.
    /// `nozzle_diameter: ["0.4"]`, `bridge_speed: ["50","50","50","50",
    /// "200","200"]`, `filament_max_volumetric_speed` with 24 entries (one
    /// per AMS slot). None of that internal shape is what you see or edit
    /// in Bambu Studio's own field for something like "Outer Wall Speed" —
    /// that's a single number, always the array's first real entry. So:
    /// take index 0 (skipping a leading placeholder "nil" if present) and
    /// nothing else — matches what Studio itself shows/lets you edit,
    /// rather than exposing this app's internal multi-slot representation.
    private static func displayString(for raw: Any) -> String {
        if let array = raw as? [Any] {
            let meaningful = array.map { "\($0)" }.filter { $0 != "nil" && !$0.isEmpty }
            return meaningful.first ?? ""
        }
        return "\(raw)"
    }
}
