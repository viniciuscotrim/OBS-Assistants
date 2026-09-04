import SwiftUI

/// Content of the confirmation window that opens when you tap "Iniciar
/// secagem agora" on a humidity alert notification — temp/duration are
/// pre-filled from the suggested profile but editable before you actually
/// send anything to the printer.
struct DryConfirmationView: View {
    let alert: DryingAlert
    @ObservedObject var settings: AppSettings
    let onConfirm: (_ filamentType: String, _ tempC: Double, _ coolingTempC: Double, _ durationHours: Double, _ rotateTray: Bool) -> Void
    let onCancel: () -> Void

    @State private var filamentType: String
    @State private var tempC: Double
    @State private var coolingTempC: Double
    @State private var durationHours: Double
    @State private var rotateTray: Bool

    init(
        alert: DryingAlert,
        settings: AppSettings,
        onConfirm: @escaping (_ filamentType: String, _ tempC: Double, _ coolingTempC: Double, _ durationHours: Double, _ rotateTray: Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.alert = alert
        self.settings = settings
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        // Mixed-type alerts pre-fill temp/duration (the capped safe temp)
        // but deliberately don't force a single type label — see
        // DryingAlert.requiresFilamentTypeSelection.
        let isMixed: Bool = { if case .mixedFilamentTypes = alert.kind { return true } else { return false } }()
        _filamentType = State(initialValue: isMixed ? "" : (alert.suggestedProfile?.filamentType ?? ""))
        _tempC = State(initialValue: alert.suggestedProfile?.dryTemperatureC ?? 45)
        _coolingTempC = State(initialValue: alert.suggestedProfile?.coolingTemperatureC ?? max(0, (alert.suggestedProfile?.dryTemperatureC ?? 45) - 5))
        _durationHours = State(initialValue: alert.suggestedProfile?.dryDurationHours ?? 8)
        _rotateTray = State(initialValue: settings.rotateTrayDefaultEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Iniciar secagem")
                .font(.system(size: 15, weight: .semibold))

            Text("AMS \(alert.amsID + 1), slot \(alert.trayIndex + 1) — \(Int(alert.humidityPercent))% de umidade")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            switch alert.kind {
            case .unknownFilamentType:
                Text("O tipo de filamento não foi identificado automaticamente. Confirme antes de secar, pra usar a temperatura certa.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .mixedFilamentTypes(let types, let safeTempC):
                Text("⚠️ \(types.count) filamentos diferentes nesse AMS (\(types.joined(separator: ", "))). Recomendado manter só 1 tipo por unidade. Temperatura travada em \(Int(safeTempC))°C — o limite mais baixo entre eles, pra não derreter nenhum.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .thresholdExceeded:
                EmptyView()
            }

            Divider()

            if !isMixedAlert {
                LabeledField(label: "Filamento") {
                    Picker("", selection: $filamentType) {
                        Text("Escolher…").tag("")
                        ForEach(settings.dryingProfiles) { profile in
                            Text(profile.filamentType).tag(profile.filamentType)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: filamentType) { newType in
                        if let profile = settings.profile(forFilamentType: newType) {
                            tempC = profile.dryTemperatureC
                            coolingTempC = profile.coolingTemperatureC
                            durationHours = profile.dryDurationHours
                        }
                    }
                }
            }

            LabeledField(label: "Temperatura") {
                HStack {
                    Slider(value: $tempC, in: 30...70, step: 1)
                        .disabled(isMixedAlert) // capped by design — see banner above
                    Text("\(Int(tempC))°C")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }
            }
            if !DryingProfile.temperatureWarningRange.contains(tempC) {
                Text("Fora da faixa recomendada (45–65°C).")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            LabeledField(label: "Resfriamento") {
                HStack {
                    Slider(value: $coolingTempC, in: 0...tempC, step: 1)
                    Text("\(Int(coolingTempC))°C")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }
            }
            Text("Temperatura que a câmara mantém depois da fase de aquecimento, antes de finalizar o ciclo.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledField(label: "Duração") {
                HStack {
                    Slider(value: $durationHours, in: 1...16, step: 0.5)
                        .disabled(settings.autoHumidityStopEnabled)
                    Text(durationHours == durationHours.rounded() ? "\(Int(durationHours))h" : String(format: "%.1fh", durationHours))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }
            }
            if settings.autoHumidityStopEnabled {
                Text("Parada automática por umidade está ligada — a duração acima é só um teto de segurança; a secagem para sozinha quando a leitura chegar no alvo (checada a cada 5 min).")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Girar bobina durante a secagem", isOn: $rotateTray)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Text("Movimenta o filamento periodicamente pra secar mais por igual.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Toggle("Secagem automática (sempre, daqui pra frente)", isOn: $settings.autoDryEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(true)
                Toggle("Secar até umidade ideal (senão, aceita até o máximo)", isOn: $settings.dryToIdealEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(true)
                Toggle("Parar sozinho quando a umidade chegar no alvo", isOn: $settings.autoHumidityStopEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(true)
                Text("Travado por enquanto — confirmamos que o comando não faz efeito nesse modelo/firmware sem uma assinatura que só o app oficial da Bambu gera. Detalhes: issue #2 no GitHub do projeto.")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Comando não-oficial (engenharia reversa da comunidade) — pode não fazer efeito dependendo do modelo/firmware. Confirme no app Bambu Handy/Studio que a secagem realmente começou; se não começar, use o app oficial diretamente.")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancelar", action: onCancel)
                Button("Iniciar secagem") {
                    onConfirm(filamentType, tempC, coolingTempC, durationHours, rotateTray)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(alert.requiresFilamentTypeSelection && filamentType.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private var isMixedAlert: Bool {
        if case .mixedFilamentTypes = alert.kind { return true }
        return false
    }
}

