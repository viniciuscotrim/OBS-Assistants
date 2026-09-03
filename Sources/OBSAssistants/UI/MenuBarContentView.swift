import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The small menu-bar popover — printer connection, plus the compact
/// "Now Playing" section. Everything heavier on the printer side
/// (composites, AMS drying, HTTP server/appearance, field selection, and
/// the separate Bambu Studio slicing-info overlay) lives in two full-size
/// windows opened from here instead, since the single popover holding all
/// of it had grown too large to navigate comfortably. See
/// PrinterOverlayView / StudioOverlayView and their window controllers.
/// "Now Playing" stays inline since it's just as compact as it was as its
/// own standalone app's menu — see NowPlayingSectionView / NowPlayingState.
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
                overlayWindowButtons

                Divider()
                NowPlayingSectionView(nowPlaying: nowPlayingState)
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

    // MARK: Overlay windows

    private var overlayWindowButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Overlays")
            Text("Campos, secagem do AMS, aparência e URLs do OBS ficam em janelas separadas agora — abra a que quiser configurar.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                PrinterOverlayWindowController.shared.present(appState: appState)
            } label: {
                HStack {
                    Image(systemName: "printer.fill")
                    Text("Abrir Overlay Impressora")
                    Spacer()
                }
            }

            Button {
                StudioOverlayWindowController.shared.present(appState: appState)
            } label: {
                HStack {
                    Image(systemName: "square.3.layers.3d")
                    Text("Abrir Overlay Bambu Studio")
                    Spacer()
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("v1.0.0")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Sair") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
