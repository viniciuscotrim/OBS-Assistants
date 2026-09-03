import SwiftUI

struct FieldRow: View {
    let field: FieldEntry
    let isVisible: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { isVisible }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                    .font(.system(size: 12, weight: .medium))
                Text(field.key)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Text(field.value.isEmpty ? "—" : field.value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
