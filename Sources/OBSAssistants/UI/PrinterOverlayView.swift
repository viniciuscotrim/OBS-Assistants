import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Content of the "Overlay Impressora" window — everything that used to
/// live in the single big menu-bar popover except the connection fields
/// (those stayed in the small root menu): custom composite fields, AMS
/// drying, the HTTP server/appearance settings, and raw field selection.
/// Split out so the root popover stays small — see MenuBarContentView.
struct PrinterOverlayView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = AppSettings.shared

    @State private var fieldFilter = ""
    @State private var categoryFilter: FieldCategory?
    @State private var copiedFeedback = false

    @State private var showDryingSection = true
    @State private var manualAMSNumber = 1
    @State private var manualFilamentType = ""
    @State private var showCompositesSection = true
    @State private var isEditingComposite = false
    @State private var editingCompositeID: String?
    @State private var draftLabel = ""
    /// One entry per source field — starts at 2 for a new composite, but
    /// you can add/remove freely via the editor's "+"/trash controls.
    @State private var draftFields: [String] = ["", ""]
    @State private var draftTemplate = "{0}/{1}"

    private let themes = ["dark", "twitch", "transparent"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                dryingSection

                Divider()
                serverSection

                Divider()
                compositesSection

                Divider()
                fieldsSection
            }
            .padding(16)
        }
        .frame(width: 480, height: 640)
    }

    // MARK: Custom composite ("combinado") fields

    private var compositesSection: some View {
        DisclosureGroup(isExpanded: $showCompositesSection) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Combine quantos campos quiser num só valor — ex: \"{0}/{1}\" com Camada Atual e Camada Total vira \"231/450\". Use \"+ Adicionar campo\" pra combinar mais de 2.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(settings.customComposites) { composite in
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
            .padding(.top, 6)
        } label: {
            sectionLabel("Campos combinados (\(settings.customComposites.count))")
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
                settings.removeComposite(id: composite.id)
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

    /// Renders the composite's template against current live values (when
    /// available) so the row shows something like "231/450" rather than
    /// the raw "{0}/{1}" — falls back to the template text itself if the
    /// source fields aren't currently reporting.
    private func compositePreview(_ composite: CustomComposite) -> String {
        let byKey = Dictionary(uniqueKeysWithValues: appState.fields.map { ($0.key, $0.value) })
        return composite.build(from: byKey)?.value ?? composite.template
    }

    private var compositeEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledField(label: "Nome") {
                TextField("ex: Temp. Bico", text: $draftLabel)
                    .textFieldStyle(.roundedBorder)
            }

            ForEach(draftFields.indices, id: \.self) { index in
                LabeledField(label: "Campo \(index + 1)") {
                    HStack(alignment: .top, spacing: 4) {
                        FieldSearchPicker(selectedKey: $draftFields[index], availableFields: appState.fields)
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
            .padding(.leading, 84) // aligns under the fields, past the label column

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
        let byKey = Dictionary(uniqueKeysWithValues: appState.fields.map { ($0.key, $0.value) })
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
        let id = editingCompositeID ?? "composite.custom.\(UUID().uuidString)"
        let composite = CustomComposite(id: id, label: draftLabel, sourceKeys: draftFields, template: draftTemplate)
        if editingCompositeID != nil {
            settings.updateComposite(composite)
        } else {
            settings.addComposite(composite)
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

    // MARK: AMS drying

    private var dryingSection: some View {
        DisclosureGroup(isExpanded: $showDryingSection) {
            VStack(alignment: .leading, spacing: 10) {
                manualDryingControl

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("Status atual")
                    let loadedSlots = appState.amsSlots.filter { $0.hasFilamentLoaded }
                    if loadedSlots.isEmpty {
                        Text("Nenhum filamento carregado detectado ainda — conecte à impressora ou carregue um spool.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(loadedSlots) { slot in
                            amsSlotRow(slot)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Secagem automática", isOn: $settings.autoDryEnabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    Text(settings.autoDryEnabled
                         ? "Ligado: um slot acima do limite do tipo dele inicia a secagem sozinho, sem confirmar (exceto quando há mais de um tipo de filamento no mesmo AMS — nesse caso sempre pede confirmação). Cooldown de segurança evita reiniciar em loop."
                         : "Desligado: você só recebe uma notificação com a opção de iniciar manualmente.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Secar até umidade ideal", isOn: $settings.dryToIdealEnabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    Text(settings.dryToIdealEnabled
                         ? "Ligado: dispara já ao passar da umidade IDEAL de cada tipo (mais sensível), não só do máximo aceitável."
                         : "Desligado: só dispara ao passar da umidade MÁXIMA aceitável — ficar entre ideal e máximo não precisa secar.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Parar automaticamente por umidade", isOn: $settings.autoHumidityStopEnabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    Text(settings.autoHumidityStopEnabled
                         ? "Ligado: checa a umidade a cada 5 min durante a secagem e manda o comando de parar sozinho ao chegar 1% abaixo do alvo (ideal ou máximo, conforme acima). A duração configurada vira só um teto de segurança — trava a edição dela abaixo."
                         : "Desligado: a secagem roda pela duração configurada e para no tempo, sem monitorar a umidade.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Girar bobina durante a secagem (padrão)", isOn: $settings.rotateTrayDefaultEnabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    Text("Valor inicial da opção \"girar bobina\" toda vez que uma secagem começa (confirmação manual ou automática) — sempre pode ser mudado por ciclo na janela de confirmação.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Comando de secagem confirmado por captura real de tráfego MQTT (não documentado oficialmente pela Bambu) — teste manual primeiro (temp baixa, tempo curto) e confirme no app oficial antes de confiar no automático.")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Limites por tipo de filamento")
                    ForEach($settings.dryingProfiles) { $profile in
                        dryingProfileRow($profile)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            sectionLabel("Secagem do AMS")
        }
    }

    /// Always-available manual start/stop — doesn't depend on
    /// `appState.amsSlots` being populated (no live data, not connected,
    /// or the printer just hasn't reported humidity for that unit yet),
    /// since that's exactly when you'd want to test the command by hand or
    /// stop a cycle that's already running.
    private var manualDryingControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Controle manual")
            HStack {
                Text("AMS")
                    .font(.system(size: 11))
                Stepper(value: $manualAMSNumber, in: 1...4) {
                    Text("\(manualAMSNumber)")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 14)
                }
                Picker("", selection: $manualFilamentType) {
                    Text("Filamento…").tag("")
                    ForEach(settings.dryingProfiles) { profile in
                        Text(profile.filamentType).tag(profile.filamentType)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            HStack {
                Button("Iniciar secagem…") {
                    appState.presentManualDryConfirmation(amsID: manualAMSNumber - 1, filamentType: manualFilamentType)
                }
                .disabled(manualFilamentType.isEmpty)
                Button("Parar secagem") {
                    appState.stopDrying(amsID: manualAMSNumber - 1)
                }
            }
            Text("Funciona mesmo sem leitura de umidade chegando — útil pra testar o comando na mão ou parar um ciclo que já está rodando.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func amsSlotRow(_ slot: AMSSlotStatus) -> some View {
        let profile = settings.profile(forFilamentType: slot.filamentTypeDisplay)
        let threshold = profile.map { settings.dryToIdealEnabled ? $0.idealHumidityPercent : $0.maxHumidityPercent }
        let exceeded = slot.humidityPercent.flatMap { h in threshold.map { h > $0 } } ?? false
        let isDrying = slot.activeDrying?.isActive ?? false

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("AMS \(slot.amsID + 1) · Slot \(slot.trayIndex + 1) · \(slot.filamentTypeDisplay)")
                        .font(.system(size: 11, weight: .medium))
                    if let h = slot.humidityPercent {
                        Text("\(Int(h))% de umidade" + (exceeded ? " — acima do \(settings.dryToIdealEnabled ? "ideal" : "limite")" : ""))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(exceeded ? .orange : .secondary)
                    } else if let idx = slot.humidityIndex {
                        Text("Índice \(idx)/5 (esse AMS não manda % real — não dá pra comparar com o limite configurado)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Sem leitura de umidade nesse AMS")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("Secar") { appState.presentDryConfirmation(forSlot: slot) }
                    .font(.system(size: 10))
                Button("Parar") { appState.stopDrying(amsID: slot.amsID) }
                    .font(.system(size: 10))
            }

            // Everything below is the printer's *own* report of the cycle
            // (ams[N].dry_setting + dry_time + temp) — not what the app
            // asked for, what the printer actually confirms is happening.
            // The MQTT command itself has no ack, so this is the only real
            // way to know it took effect.
            if isDrying, let dry = slot.activeDrying {
                dryingStatusDetail(slot: slot, dry: dry, targetHumidity: threshold)
            } else if let dry = slot.activeDrying, dry.filamentType.isEmpty && dry.targetTemperatureC < 0 {
                Text("Parada — a impressora não reporta nenhum ciclo ativo nesse AMS agora.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isDrying ? Color.green.opacity(0.12) : (exceeded ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.06))))
    }

    private func dryingStatusDetail(slot: AMSSlotStatus, dry: AMSDryStatus, targetHumidity: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("🔥 Secando: \(dry.filamentType)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)

            HStack(spacing: 10) {
                statPair(
                    label: "Umidade",
                    value: slot.humidityPercent.map { "\(Int($0))%" } ?? "—",
                    target: targetHumidity.map { "alvo \(Int($0))%" }
                )
                statPair(
                    label: "Câmara",
                    value: slot.chamberTemperatureC.map { String(format: "%.0f°C", $0) } ?? "—",
                    target: "alvo \(Int(dry.targetTemperatureC))°C"
                )
            }
            statPair(
                label: "Tempo",
                value: formattedHours(dry.elapsedHours),
                target: "de \(formattedHours(dry.targetDurationHours)) programadas"
            )
            Text("(tempo decorrido: \(Int(dry.elapsedMinutesRaw)) — unidade exata não confirmada pela Bambu; confira contra o relógio no seu primeiro teste)")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.green.opacity(0.08)))
    }

    private func statPair(label: String, value: String, target: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            HStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                if let target {
                    Text(target)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formattedHours(_ hours: Double) -> String {
        hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    private func dryingProfileRow(_ profile: Binding<DryingProfile>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(profile.wrappedValue.filamentType)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 40, alignment: .leading)
                LabeledNumberField(label: "Ideal", suffix: "%", value: profile.idealHumidityPercent)
                LabeledNumberField(label: "Máx", suffix: "%", value: profile.maxHumidityPercent)
            }
            HStack {
                Spacer().frame(width: 40)
                LabeledNumberField(label: "Temp", suffix: "°C", value: profile.dryTemperatureC)
                LabeledNumberField(label: "Resfr.", suffix: "°C", value: profile.coolingTemperatureC)
                LabeledNumberField(label: "Duração", suffix: "h", value: profile.dryDurationHours)
                    .disabled(settings.autoHumidityStopEnabled)
                    .opacity(settings.autoHumidityStopEnabled ? 0.5 : 1)
            }
            if profile.wrappedValue.isTemperatureOutOfRecommendedRange {
                Text("Temperatura fora da faixa recomendada (45–65°C).")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            if !profile.wrappedValue.isIdealBelowMax {
                Text("Ideal deveria ser menor que o máximo.")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: HTTP server / aparência

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Servidor HTTP local")

            HStack {
                Text("Porta")
                    .font(.system(size: 11))
                TextField("8090", value: $settings.httpPort, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)

                Button(appState.serverRunning ? "Parar" : "Iniciar") {
                    appState.serverRunning ? appState.stopServer() : appState.startServer()
                }

                Circle()
                    .fill(appState.serverRunning ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
            }

            HStack {
                Text("Tema")
                    .font(.system(size: 11))
                Picker("", selection: $settings.overlayTheme) {
                    ForEach(themes, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)

                Button(copiedFeedback ? "Copiado!" : "Copiar URL do OBS (Impressora)") {
                    copyOBSURL()
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Tamanho do texto")
                        .font(.system(size: 11))
                    Slider(value: $settings.overlayTextScale, in: 0.6...1.6, step: 0.1)
                        .frame(width: 140)
                    Text("\(Int((settings.overlayTextScale * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                Text("Ajusta o tamanho geral dos cards no overlay.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Tamanho da caixa (X)")
                        .font(.system(size: 11))
                    Slider(value: $settings.overlayBoxWidthScale, in: 0.5...2.5, step: 0.1)
                        .frame(width: 140)
                    Text("\(Int((settings.overlayBoxWidthScale * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                HStack {
                    Text("Tamanho da caixa (Y)")
                        .font(.system(size: 11))
                    Slider(value: $settings.overlayBoxHeightScale, in: 0.5...2.5, step: 0.1)
                        .frame(width: 140)
                    Text("\(Int((settings.overlayBoxHeightScale * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                Text("Redimensiona a caixa em si (largura/altura), independente do tamanho do texto. Só deste overlay — o Bambu Studio tem seus próprios sliders.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Encolher texto automaticamente pra caber no card", isOn: $settings.overlayAutoFit)
                    .font(.system(size: 11))
                    .toggleStyle(.checkbox)
                Text(settings.overlayAutoFit
                     ? "Ligado: um valor comprido (ex: nome de arquivo) encolhe até caber inteiro, em vez de cortar com \"…\"."
                     : "Desligado: valores compridos são cortados com \"…\" em vez de encolher.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyOBSURL() {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(settings.obsURL, forType: .string)
        #endif
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedFeedback = false }
    }

    // MARK: Fields

    /// Fields currently shown, in the user's chosen order — this is exactly
    /// what /status lists (and what the overlay renders), so the ◀ ▶
    /// buttons in the UI match what actually moves in OBS.
    private var selectedFields: [FieldEntry] {
        let byKey = Dictionary(uniqueKeysWithValues: appState.fields.map { ($0.key, $0) })
        return settings.visibleFieldOrder.compactMap { byKey[$0] }
    }

    private var searchResults: [FieldEntry] {
        guard !fieldFilter.isEmpty || categoryFilter != nil else { return [] }
        var matches = appState.fields
        if let category = categoryFilter {
            matches = matches.filter { FieldCategory.classify(key: $0.key) == category }
        }
        if !fieldFilter.isEmpty {
            let q = fieldFilter.lowercased()
            matches = matches.filter { $0.key.lowercased().contains(q) || $0.label.lowercased().contains(q) }
        }
        return Array(matches.prefix(60))
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            selectedFieldsBlock

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    sectionLabel("Adicionar campos")
                    Spacer()
                    Text("\(appState.fields.count) disponíveis")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    if let last = appState.lastUpdate {
                        Text("· atualizado \(last, style: .relative)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }

                if appState.fields.isEmpty {
                    Text("Conecte à impressora para ver os campos disponíveis aqui.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField("Buscar (ex: ams, temp, percent, chamber)…", text: $fieldFilter)
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

                    categoryFilterRow

                    if fieldFilter.isEmpty && categoryFilter == nil {
                        Text("Digite pra buscar, ou toque uma categoria acima — os já marcados aparecem em \"Selecionados\" acima.")
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
                            Text(fieldFilter.isEmpty
                                 ? "Nenhum campo nessa categoria ainda."
                                 : "Nenhum campo bate com \"\(fieldFilter)\".")
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

    /// Quick category filters — this is what fixes fields of the same kind
    /// (e.g. every temperature) being scattered far apart in a flat,
    /// insertion-order list of 500+ keys: tap "Temperaturas" and only those
    /// show up, instead of hunting/typing for each one individually.
    private var categoryFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FieldCategory.allCases, id: \.self) { category in
                    let isSelected = categoryFilter == category
                    Button {
                        categoryFilter = isSelected ? nil : category
                    } label: {
                        Text(category.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(isSelected ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.12))
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 22)
    }

    private var selectedFieldsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Selecionados no overlay (\(selectedFields.count))")

            if selectedFields.isEmpty {
                Text("Nenhum campo selecionado ainda — busque abaixo pra adicionar (ex: \"percent\", \"temper\", \"ams\").")
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
}
