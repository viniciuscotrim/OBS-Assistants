import SwiftUI

/// Small view helpers shared across the root menu and both overlay-tab
/// windows (Impressora / Bambu Studio) — pulled out of MenuBarContentView
/// when the UI was split into separate windows, so all three files can use
/// them without duplicating the code three times.

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 80, alignment: .leading)
                .padding(.top, 3) // roughly centers on the content's first line, even when it grows below (e.g. FieldSearchPicker's results list)
            content
        }
    }
}

/// A tiny "label: [123]suffix" numeric field — used for the per-filament
/// humidity/temperature/duration thresholds, three to a row.
struct LabeledNumberField: View {
    let label: String
    let suffix: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 38)
                .multilineTextAlignment(.trailing)
            Text(suffix)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

func sectionLabel(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
}
