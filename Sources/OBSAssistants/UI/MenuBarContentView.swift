import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The small menu-bar popover — stays simple on purpose: printer
/// connection (MQTT) and the X.509 fallback, same as always, plus one
/// "Servidores" section listing all four overlays (Impressora, Bambu
/// Studio, Preview 3D, Now Playing) as a status dot + Start/Stop + a
/// settings (gear) button each. Every per-overlay setting (fields, AMS
/// drying, theme/appearance, port, audio routing…) lives in that overlay's
/// own full-size window, opened via its gear button — see
/// PrinterOverlayView / StudioOverlayView / PrintPreviewOverlayView /
/// NowPlayingOverlayView and their window controllers. All four servers
/// start stopped; the user starts only the one(s) they're actually using in
/// OBS right now — see ServerRow.
struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var nowPlayingState: NowPlayingState
    @ObservedObject private var settings = AppSettings.shared

    @State private var showCertSection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                connectionSection

                Divider()
                certFallbackSection

                Divider()
                serversSection
            }
            .padding(16)

            Divider()
            footer
                .padding(16)
        }
        .frame(width: 380)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("OBS Assistants")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(appState.connectionStatus.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .connectedPrimary, .connectedFallback: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Impressora (MQTT)")

            if !appState.discoveredPrinters.isEmpty {
                discoveredPrintersList
            } else {
                noPrintersFoundHint
            }

            LabeledField(label: "IP") {
                TextField("192.168.1.50", text: $settings.printerIP)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField(label: "Serial") {
                TextField("00M00A000000000", text: $settings.printerSerial)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField(label: "Access Code") {
                SecureField("Código LAN", text: $settings.accessCode)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button(isConnected ? "Desconectar" : "Conectar") {
                    isConnected ? appState.disconnectPrinter() : appState.connectPrinter()
                }
                .disabled(!settings.isConfigured && !isConnected)

                if case .failed(let reason) = appState.connectionStatus {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
            }
        }
    }

    private var noPrintersFoundHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.isScanningNetwork {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Buscando impressoras na rede…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Nenhuma impressora encontrada na rede ainda.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("A busca por broadcast (SSDP) pode não funcionar em alguns roteadores/mesh; o app já tenta um scan ativo da rede automaticamente. Se mesmo assim nada aparecer, digite IP/serial manualmente.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Buscar de novo") { appState.scanNetwork() }
                        .font(.system(size: 10))
                    Button("Ajustes > Privacidade > Rede Local") { openLocalNetworkSettings() }
                        .font(.system(size: 10))
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func openLocalNetworkSettings() {
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private var discoveredPrintersList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Encontradas na rede — clique pra preencher IP/serial")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    appState.scanNetwork()
                } label: {
                    if appState.isScanningNetwork {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(appState.isScanningNetwork)
            }

            ForEach(appState.discoveredPrinters) { printer in
                Button {
                    appState.useDiscoveredPrinter(printer)
                } label: {
                    HStack {
                        Image(systemName: "printer.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(printer.name)
                                .font(.system(size: 11, weight: .medium))
                            Text("\(printer.ip) · \(printer.model.isEmpty ? printer.serial : printer.model)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if settings.printerSerial == printer.serial {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
        .padding(.bottom, 4)
    }

    private var isConnected: Bool {
        appState.connectionStatus == .connectedPrimary
            || appState.connectionStatus == .connectedFallback
            || appState.connectionStatus == .connecting
    }

    // MARK: X.509 fallback

    private var certFallbackSection: some View {
        DisclosureGroup(isExpanded: $showCertSection) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Usado automaticamente se a impressora rejeitar o login padrão (firmware pós-jan/2025). Veja o README para como obter um .p12. Referência: OpenBambuAPI (github.com/Doridian/OpenBambuAPI).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    TextField("Caminho do .p12", text: $settings.clientCertPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Escolher…") { pickCertFile() }
                }
                LabeledField(label: "Senha do .p12") {
                    SecureField("", text: $settings.clientCertPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.top, 6)
        } label: {
            sectionLabel("Certificado X.509 (fallback)")
        }
    }

    private func pickCertFile() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Selecione o certificado .p12"
        if panel.runModal() == .OK, let url = panel.url {
            settings.clientCertPath = url.path
        }
        #endif
    }

    // MARK: Servers — one row per overlay: status, Start/Stop, a settings
    // (gear) button that opens that overlay's own window (fields, AMS
    // drying, theme/appearance — see PrinterOverlayView / StudioOverlayView
    // / PrintPreviewOverlayView / NowPlayingOverlayView), and its OBS URL as
    // click-to-copy text. All four start stopped — you start only the
    // one(s) you're actually using in OBS right now.

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Servidores")
            Text("Cada overlay tem seu próprio servidor local, parado até você iniciar. A engrenagem abre as configurações de cada um.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ServerRow(
                title: "Impressora",
                isRunning: appState.serverRunning,
                obsURL: settings.obsURL,
                onToggle: {
                    appState.serverRunning ? appState.stopServer() : appState.startServer()
                },
                onOpenSettings: {
                    PrinterOverlayWindowController.shared.present(appState: appState)
                }
            )

            ServerRow(
                title: "Bambu Studio",
                isRunning: appState.studioServerRunning,
                obsURL: settings.studioObsURL,
                onToggle: {
                    appState.studioServerRunning ? appState.stopStudioServer() : appState.startStudioServer()
                },
                onOpenSettings: {
                    StudioOverlayWindowController.shared.present(appState: appState)
                }
            )

            ServerRow(
                title: "Preview 3D",
                isRunning: appState.previewServerRunning,
                obsURL: settings.previewObsURL,
                onToggle: {
                    appState.previewServerRunning ? appState.stopPreviewServer() : appState.startPreviewServer()
                },
                onOpenSettings: {
                    PrintPreviewOverlayWindowController.shared.present(appState: appState)
                }
            )

            ServerRow(
                title: nowPlayingRowTitle,
                isRunning: nowPlayingState.isServerRunning,
                obsURL: nowPlayingState.obsURL,
                onToggle: {
                    nowPlayingState.isServerRunning ? nowPlayingState.stopServer() : nowPlayingState.startServer()
                },
                onOpenSettings: {
                    NowPlayingOverlayWindowController.shared.present(nowPlayingState: nowPlayingState)
                }
            )
        }
    }

    /// The music server's row shows the track currently playing instead of
    /// a generic label, per request — falls back to "Now Playing" when
    /// nothing's playing in Music.app.
    private var nowPlayingRowTitle: String {
        nowPlayingState.nowPlaying.trackId != "none" ? nowPlayingState.nowPlaying.title : "Now Playing"
    }

    // MARK: Footer

    /// Read straight from the bundle's own Info.plist instead of a
    /// hardcoded literal — was stuck at "v1.0.0" through every version bump
    /// since (1.0.1, 1.1.0, 1.2.0…) since nothing kept it in sync by hand.
    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "v\(version)"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(appVersionLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Sair") {
                    NSApplication.shared.terminate(nil)
                }
            }
            CreditsFooter()
        }
    }
}
