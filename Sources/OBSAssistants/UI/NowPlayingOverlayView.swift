import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Content of the "Overlay Now Playing" window — the Music.app overlay's
/// settings, in its own window (own port, own theme, own audio routing),
/// same pattern as PrinterOverlayView / StudioOverlayView. Kept out of the
/// root menu-bar popover on purpose: a bare, unlabeled theme picker sitting
/// right below the printer/Studio "Servidores" rows read as if it applied
/// to all three overlays, when it's always been its own independent
/// setting (see NowPlayingState.theme) — a dedicated window makes that
/// unambiguous.
struct NowPlayingOverlayView: View {
    @ObservedObject var nowPlaying: NowPlayingState
    @State private var portText: String = ""
    @State private var copiedFeedback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusSection

                Divider()
                serverSection

                Divider()
                themeSection

                Divider()
                audioSection

                if let error = nowPlaying.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                urlSection

                Divider()
                CreditsFooter()
            }
            .padding(20)
        }
        .frame(width: 460, height: 560)
        .onAppear { portText = String(nowPlaying.port) }
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Now Playing (Music.app)")
            if nowPlaying.nowPlaying.isPlaying {
                Label(nowPlaying.nowPlaying.title, systemImage: "play.fill")
                    .foregroundStyle(.green)
                Text(nowPlaying.nowPlaying.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if nowPlaying.nowPlaying.trackId != "none" {
                Label(nowPlaying.nowPlaying.title, systemImage: "pause.fill")
                    .foregroundStyle(.orange)
                Text(nowPlaying.nowPlaying.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Nenhuma faixa no Music.app")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Server

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Servidor")
            HStack {
                Circle()
                    .fill(nowPlaying.isServerRunning ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(nowPlaying.isServerRunning ? "Rodando" : "Parado")
                    .font(.system(size: 12))
                Spacer()
                Button(nowPlaying.isServerRunning ? "Parar" : "Iniciar") {
                    if nowPlaying.isServerRunning {
                        nowPlaying.stopServer()
                    } else {
                        nowPlaying.startServer()
                    }
                }
            }
            HStack {
                Text("Porta:")
                    .font(.system(size: 12))
                TextField("8080", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .disabled(nowPlaying.isServerRunning)
                    .onSubmit { applyPort() }
                Button("Aplicar") { applyPort() }
                    .disabled(nowPlaying.isServerRunning)
            }
        }
    }

    // MARK: Theme — deliberately its own, independent of the printer/Studio
    // overlays' themes (see the file doc comment).

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Tema do overlay")
            Text("Só desse overlay — independente do tema dos overlays de Impressora e Bambu Studio.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $nowPlaying.theme) {
                ForEach(NowPlayingTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: Audio — two independent toggles, see NowPlayingState's doc
    // comments on setBroadcasting/setLocalMuted for why.

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Áudio")

            Toggle(isOn: Binding(
                get: { nowPlaying.isBroadcasting },
                set: { nowPlaying.setBroadcasting($0) }
            )) {
                Text("Transmitir áudio do Music no overlay (OBS)")
                    .font(.system(size: 12))
            }
            .disabled(nowPlaying.isAudioRoutingBusy || !nowPlaying.isAudioCaptureSupported)

            Toggle(isOn: Binding(
                get: { nowPlaying.isLocalMuted },
                set: { nowPlaying.setLocalMuted($0) }
            )) {
                Text("Também silenciar no Mac (ouvir só pelo stream)")
                    .font(.system(size: 12))
            }
            .disabled(nowPlaying.isAudioRoutingBusy || !nowPlaying.isBroadcasting)

            Text(audioHelpText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var audioHelpText: String {
        guard nowPlaying.isAudioCaptureSupported else {
            return "Requer macOS 14.2 ou mais recente."
        }
        if nowPlaying.isBroadcasting && nowPlaying.isLocalMuted {
            return "Ativo: o Music.app está mudo no Mac; o áudio vai só pelo overlay (WebSocket) — um único Browser Source no OBS já traz vídeo e áudio."
        } else if nowPlaying.isBroadcasting {
            return "Ativo: você continua ouvindo o Music.app normalmente nos seus alto-falantes/fones, e o mesmo áudio também vai pelo overlay pro OBS."
        } else {
            return "Desligado: o overlay não envia áudio nenhum — ative pra o OBS capturar o som do Music.app direto pela Browser Source (com ou sem silenciar localmente)."
        }
    }

    // MARK: URL

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("URL do OBS")
            HStack {
                Button(copiedFeedback ? "Copiado! ✓" : "Copiar URL do OBS") {
                    nowPlaying.copyOBSURLToClipboard()
                    copiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedFeedback = false
                    }
                }
                .keyboardShortcut("c", modifiers: [.command])
            }
            Text(nowPlaying.obsURL)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func applyPort() {
        guard let value = Int(portText), value > 0, value <= 65535 else {
            nowPlaying.lastError = "Porta deve ser um número entre 1 e 65535."
            return
        }
        nowPlaying.port = value
        nowPlaying.lastError = nil
    }
}
