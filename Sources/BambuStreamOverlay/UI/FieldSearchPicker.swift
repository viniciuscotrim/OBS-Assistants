import SwiftUI

/// Search-to-select a single field — same interaction as the main "Adicionar
/// campos" search (type to filter, each result shows its label/key/current
/// value), but for picking exactly one field into a binding instead of
/// toggling visibility. Used by the custom composite ("combinado") editor's
/// "Campo 1"/"Campo 2" pickers, which used to be a flat dropdown menu of
/// 500+ entries — not something you can scan by name alone when you also
/// want to see which field currently holds the value you're after.
struct FieldSearchPicker: View {
    @Binding var selectedKey: String
    let availableFields: [FieldEntry]
    var placeholder: String = "Buscar campo…"

    @State private var searchText = ""
    @State private var isSearching = false

    private var selectedField: FieldEntry? {
        availableFields.first { $0.key == selectedKey }
    }

    private var results: [FieldEntry] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return Array(
            availableFields
                .filter { $0.key.lowercased().contains(q) || $0.label.lowercased().contains(q) }
                .prefix(30)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let field = selectedField, !isSearching {
                selectedRow(field)
            } else {
                searchBox
                if !results.isEmpty {
                    resultsList
                } else if !searchText.isEmpty {
                    Text("Nenhum campo bate com \"\(searchText)\".")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func selectedRow(_ field: FieldEntry) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(field.label)
                    .font(.system(size: 11, weight: .medium))
                Text(field.key)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Text(field.value.isEmpty ? "—" : field.value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 90, alignment: .trailing)
            Button {
                isSearching = true
                searchText = ""
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Trocar campo")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(results) { field in
                    Button {
                        selectedKey = field.key
                        isSearching = false
                        searchText = ""
                    } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(field.label)
                                    .font(.system(size: 11))
                                Text(field.key)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 6)
                            Text(field.value.isEmpty ? "—" : field.value)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 80, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.3)
                }
            }
        }
        .frame(maxHeight: 140)
    }
}
