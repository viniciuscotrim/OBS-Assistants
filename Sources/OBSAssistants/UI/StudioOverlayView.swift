import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Content of the "Overlay Bambu Studio" window — a separate overlay
/// source (own URL, own independent HTTP server/port — see
/// LocalHTTPServer's doc comment) showing slicing details (layer height,
/// walls, infill…)
/// read from a local `.3mf`, since the printer's own MQTT report never
/// includes them — see BambuStudioProjectReader's doc comment for why.
///
/// Mirrors PrinterOverlayView's search + combined-fields UX (same
/// FieldSearchPicker/FieldRow/FlowLayout components), just pointed at
/// `appState.studioFields` (~470 slicing keys) and `settings.studioComposites`
/// instead of the printer's MQTT fields — see AppState.recomputeStudioFields.
struct StudioOverlayView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = AppSettings.shared

    @State private var copiedFeedback = false
    @State private var fieldFilter = ""

    @State private var isEditingComposite = false
    @State private var editingCompositeID: String?
    @State private var draftLabel = ""
    @State private var draftFields: [String] = ["", ""]
    @State private var draftTemplate = "{0}/{1}"

    private let themes = ["dark", "twitch", "transparent"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                projectFolderSection

                Divider()
                compositesSection

                Divider()
                fieldsSection

                Divider()
                serverSection

                Divider()
                appearanceSection
            }
            .padding(16)
        }
        .frame(width: 480, height: 680)
    }

    // MARK: HTTP server — own independent listener/port from the printer
    // overlay's (see LocalHTTPServer's doc comment); starts stopped, same
    // as the other two overlays.

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Servidor HTTP local")

            HStack {
                Text("Porta")
                    .font(.system(size: 11))
                TextField("8091", value: $settings.studioHttpPort, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)

                Button(appState.studioServerRunning ? "Parar" : "Iniciar") {
                    appState.studioServerRunning ? appState.stopStudioServer() : appState.startStudioServer()
                }

                Circle()
                    .fill(appState.studioServerRunning ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
            }
        }
    }

    // MARK: Project folder

    private var projectFolderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Pasta de projetos do Bambu Studio")
            Text("Sempre lê o .3mf mais recente dessa pasta — aponte pra onde você salva/exporta seus projetos fatiados. Atualiza sozinho quando uma nova impressão começa na impressora.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("~/Desktop/Bambu Downloads", text: $settings.studioProjectFolderPath)
                    .textFieldStyle(.roundedBorder)
                Button("Escolher…") { pickFolder() }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(appState.studioFields.isEmpty ? Color.gray : Color.green)
                    .frame(width: 7, height: 7)
                if appState.studioFields.isEmpty {
                    Text(settings.studioProjectFolderPath.isEmpty
                         ? "Nenhuma pasta configurada ainda."
                         : "Nenhum .3mf legível encontrado nessa pasta.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(appState.studioProjectFileName)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let readAt = appState.studioProjectReadAt {
                            Text("lido \(readAt, style: .relative) atrás")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                Button {
                    appState.refreshStudioProject()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reler agora")
            }
        }
    }

    private func pickFolder() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Selecione a pasta dos seus projetos .3mf"
        if panel.runModal() == .OK, let url = panel.url {
            settings.studioProjectFolderPath = url.path
        }
        #endif
    }

    // MARK: Custom composite ("combinado") fields — mirrors PrinterOverlayView

    private var compositesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Campos combinados (\(settings.studioComposites.count))")
            Text("Combine quantos campos de fatiamento quiser num só valor — ex: \"{0}mm / {1} paredes\".")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(settings.studioComposites) { composite in
                compositeRow(composite)
            }

            if isEditingComposite {
                compositeEditor
            } else {
                Button("+ Novo combinado") {
                    startNewComposite()
                }
                .font(.system(size: 11))
            }
        }
    }

    private func compositeRow(_ composite: CustomComposite) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(composite.label.isEmpty ? "(sem nome)" : composite.label)
                    .font(.system(size: 11, weight: .medium))
                Text(compositePreview(composite))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                startEditingComposite(composite)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            Button {
                settings.removeStudioComposite(id: composite.id)
                if editingCompositeID == composite.id { resetCompositeDraft() }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func compositePreview(_ composite: CustomComposite) -> String {
        let byKey = Dictionary(uniqueKeysWithValues: appState.studioFields.map { ($0.key, $0.value) })
        return composite.build(from: byKey)?.value ?? composite.template
    }

    private var compositeEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledField(label: "Nome") {
                TextField("ex: Paredes/Preenchimento", text: $draftLabel)
                    .textFieldStyle(.roundedBorder)
            }

            ForEach(draftFields.indices, id: \.self) { index in
                LabeledField(label: "Campo \(index + 1)") {
                    HStack(alignment: .top, spacing: 4) {
                        FieldSearchPicker(selectedKey: $draftFields[index], availableFields: appState.studioFields)
                        if draftFields.count > 1 {
                            Button {
                                draftFields.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .padding(.top, 4)
                            .help("Remover campo \(index + 1)")
                        }
                    }
                }
            }
            Button {
                draftFields.append("")
            } label: {
                Label("Adicionar campo", systemImage: "plus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.leading, 84)

            LabeledField(label: "Modelo") {
                TextField(templatePlaceholder, text: $draftTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
            Text("\(placeholderList) viram o valor de cada campo acima, na ordem. Prévia: \(draftPreview)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Salvar") { saveComposite() }
                    .disabled(!isDraftValid)
                Button("Cancelar") { resetCompositeDraft() }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    private var placeholderList: String {
        draftFields.indices.map { "{\($0)}" }.joined(separator: ", ")
    }

    private var templatePlaceholder: String {
        draftFields.indices.map { "{\($0)}" }.joined(separator: "/")
    }

    private var draftPreview: String {
        guard !draftFields.isEmpty, draftFields.allSatisfy({ !$0.isEmpty }) else { return "—" }
        let byKey = Dictionary(uniqueKeysWithValues: appState.studioFields.map { ($0.key, $0.value) })
        var value = draftTemplate
        for (index, key) in draftFields.enumerated() {
            value = value.replacingOccurrences(of: "{\(index)}", with: byKey[key] ?? "?")
        }
        return value
    }

    private var isDraftValid: Bool {
        !draftLabel.trimmingCharacters(in: .whitespaces).isEmpty
            && !draftFields.isEmpty
            && draftFields.allSatisfy { !$0.isEmpty }
            && !draftTemplate.isEmpty
    }

    private func startNewComposite() {
        editingCompositeID = nil
        draftLabel = ""
        draftFields = ["", ""]
        draftTemplate = "{0}/{1}"
        isEditingComposite = true
    }

    private func startEditingComposite(_ composite: CustomComposite) {
        editingCompositeID = composite.id
        draftLabel = composite.label
        draftFields = composite.sourceKeys.isEmpty ? [""] : composite.sourceKeys
        draftTemplate = composite.template
        isEditingComposite = true
    }

    private func saveComposite() {
        let id = editingCompositeID ?? "studio.composite.custom.\(UUID().uuidString)"
        let composite = CustomComposite(id: id, label: draftLabel, sourceKeys: draftFields, template: draftTemplate)
        if editingCompositeID != nil {
            settings.updateStudioComposite(composite)
        } else {
            settings.addStudioComposite(composite)
        }
        resetCompositeDraft()
    }

    private func resetCompositeDraft() {
        isEditingComposite = false
        editingCompositeID = nil
        draftLabel = ""
        draftFields = ["", ""]
        draftTemplate = "{0}/{1}"
    }

    // MARK: Fields

    private var selectedFields: [FieldEntry] {
        let byKey = Dictionary(uniqueKeysWithValues: appState.studioFields.map { ($0.key, $0) })
        return settings.visibleFieldOrder.compactMap { byKey[$0] }
    }

    private var searchResults: [FieldEntry] {
        guard !fieldFilter.isEmpty else { return [] }
        let q = fieldFilter.lowercased()
        return Array(
            appState.studioFields
                .filter { $0.key.lowercased().contains(q) || $0.label.lowercased().contains(q) }
                .prefix(60)
        )
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            selectedFieldsBlock

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    sectionLabel("Adicionar campos")
                    Spacer()
                    Text("\(appState.studioFields.count) disponíveis")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                if appState.studioFields.isEmpty {
                    Text("Configure a pasta acima pra ver os campos disponíveis (altura de camada, paredes, preenchimento…).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField("Buscar (ex: layer, wall, infill, speed)…", text: $fieldFilter)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                        if !fieldFilter.isEmpty {
                            Button {
                                fieldFilter = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))

                    if fieldFilter.isEmpty {
                        Text("Digite pra buscar — são ~\(appState.studioFields.count) campos, tudo que o .3mf tem (layer_height, wall_loops, sparse_infill_density, velocidades, temperaturas por material…). Os já marcados aparecem em \"Selecionados\" acima.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(searchResults) { field in
                                    FieldRow(
                                        field: field,
                                        isVisible: settings.isFieldVisible(field.key),
                                        onToggle: { appState.setFieldVisible(field.key, visible: $0) }
                                    )
                                    Divider().opacity(0.3)
                                }
                            }
                        }
                        .frame(maxHeight: 220)

                        if searchResults.isEmpty {
                            Text("Nenhum campo bate com \"\(fieldFilter)\".")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 4)
                        } else if searchResults.count == 60 {
                            Text("Mostrando os primeiros 60 resultados — refine a busca pra ver mais específico.")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var selectedFieldsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Selecionados no overlay (\(selectedFields.count))")

            if selectedFields.isEmpty {
                Text("Nenhum campo selecionado ainda — busque abaixo pra adicionar (ex: \"layer_height\", \"wall_loops\", \"infill\").")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Use ◀ ▶ pra decidir a ordem (é o que fica lado a lado no OBS).")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)

                let density = ChipDensity(itemCount: selectedFields.count)
                FlowLayout(spacing: density.flowSpacing) {
                    ForEach(Array(selectedFields.enumerated()), id: \.element.id) { index, field in
                        FieldChip(
                            label: field.label,
                            value: field.value,
                            density: density,
                            canMoveBack: index > 0,
                            canMoveForward: index < selectedFields.count - 1,
                            onMoveBack: { appState.moveFieldUp(field.key) },
                            onMoveForward: { appState.moveFieldDown(field.key) },
                            onRemove: { appState.setFieldVisible(field.key, visible: false) }
                        )
                    }
                }
                if density != .roomy {
                    Text(density == .tiny
                         ? "Muitos campos selecionados — mostrando compacto, sem valor ao vivo nos chips."
                         : "Vários campos selecionados — chips reduzidos pra caber.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Aparência / URL

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Overlay")

            HStack {
                Text("Tema")
                    .font(.system(size: 11))
                Picker("", selection: $settings.studioOverlayTheme) {
                    ForEach(themes, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)

                Button(copiedFeedback ? "Copiado!" : "Copiar URL do OBS (Bambu Studio)") {
                    copyOBSURL()
                }
            }
            Text("Tema, tamanho de texto/caixa e auto-fit são todos independentes do Overlay Impressora.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            HStack {
                Text("Tamanho do texto")
                    .font(.system(size: 11))
                Slider(value: $settings.studioOverlayTextScale, in: 0.6...1.6, step: 0.1)
                    .frame(width: 140)
                Text("\(Int((settings.studioOverlayTextScale * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            HStack {
                Text("Tamanho da caixa (X)")
                    .font(.system(size: 11))
                Slider(value: $settings.studioOverlayBoxWidthScale, in: 0.5...2.5, step: 0.1)
                    .frame(width: 140)
                Text("\(Int((settings.studioOverlayBoxWidthScale * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            HStack {
                Text("Tamanho da caixa (Y)")
                    .font(.system(size: 11))
                Slider(value: $settings.studioOverlayBoxHeightScale, in: 0.5...2.5, step: 0.1)
                    .frame(width: 140)
                Text("\(Int((settings.studioOverlayBoxHeightScale * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            Toggle("Encolher texto automaticamente pra caber no card", isOn: $settings.studioOverlayAutoFit)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)
        }
    }

    private func copyOBSURL() {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(settings.studioObsURL, forType: .string)
        #endif
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedFeedback = false }
    }
}
