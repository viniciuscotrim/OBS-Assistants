import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Content of the "Preview 3D" window — the 4th overlay: a static render of
/// the sliced plate (`Metadata/plate_1.png`, the same image Bambu Studio
/// itself shows), read from the **same** watched folder as the "Overlay
/// Bambu Studio" source (see `settings.studioProjectFolderPath`) — no
/// separate folder to configure here. See PrintPreviewHTTPServer's and
/// BambuStudioProjectReader's doc comments for why this is a static
/// "expected result" shot rather than a live layer-by-layer animation (no
/// G-code embedded in a plain "Save Project" `.3mf`).
struct PrintPreviewOverlayView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = AppSettings.shared

    @State private var copiedFeedback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusSection

                Divider()
                serverSection

                Divider()
                CreditsFooter()
            }
            .padding(16)
        }
        .frame(width: 440, height: 380)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Prévia do resultado")
            Text("Mostra o render que o próprio Bambu Studio já gera pro plate ao fatiar — a mesma pasta configurada no Overlay Bambu Studio (\"\(folderDisplay)\"). Sem pasta configurada lá, esse overlay também fica sem imagem.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Circle()
                    .fill(appState.previewImageSourceFile.isEmpty ? Color.gray : Color.green)
                    .frame(width: 7, height: 7)
                if appState.previewImageSourceFile.isEmpty {
                    Text(settings.studioProjectFolderPath.isEmpty
                         ? "Nenhuma pasta configurada ainda."
                         : "Nenhuma prévia encontrada nessa pasta.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(appState.previewImageSourceFile)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let readAt = appState.previewImageReadAt {
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

            if settings.studioProjectFolderPath.isEmpty {
                Button("Abrir Overlay Bambu Studio (pra configurar a pasta)") {
                    StudioOverlayWindowController.shared.present(appState: appState)
                }
                .font(.system(size: 10))
            }
        }
    }

    private var folderDisplay: String {
        settings.studioProjectFolderPath.isEmpty ? "nenhuma" : settings.studioProjectFolderPath
    }

    // MARK: HTTP server — own independent listener/port; starts stopped,
    // same as the other three overlays.

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Servidor HTTP local")

            HStack {
                Text("Porta")
                    .font(.system(size: 11))
                TextField("8092", value: $settings.previewHttpPort, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)

                Button(appState.previewServerRunning ? "Parar" : "Iniciar") {
                    appState.previewServerRunning ? appState.stopPreviewServer() : appState.startPreviewServer()
                }

                Circle()
                    .fill(appState.previewServerRunning ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
            }

            Button(copiedFeedback ? "Copiado!" : "Copiar URL do OBS (Preview 3D)") {
                copyOBSURL()
            }
            .font(.system(size: 11))
        }
    }

    private func copyOBSURL() {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(settings.previewObsURL, forType: .string)
        #endif
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedFeedback = false }
    }
}
