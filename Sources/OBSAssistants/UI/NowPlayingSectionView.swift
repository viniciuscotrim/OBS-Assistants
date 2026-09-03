import SwiftUI

/// "Now Playing" section of the root menu-bar popover — status, server
/// start/stop, port, overlay theme, "Music só no streaming" audio routing,
/// and the OBS Browser Source URL. Compact enough (same shape as the
/// standalone StreamNowPlaying app's own menu) to live inline here rather
/// than in its own full-size window, unlike the printer overlay's heavier
/// settings — see MenuBarContentView's doc comment.
struct NowPlayingSectionView: View {
    @ObservedObject var nowPlaying: NowPlayingState
    @State private var portText: String = ""
    @State private var copiedFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Now Playing (Music.app)")

            statusRow

            HStack {
                Circle()
                    .fill(nowPlaying.isServerRunning ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(nowPlaying.isServerRunning ? "Servidor rodando" : "Servidor parado")
                    .font(.system(size: 11))
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
                    .font(.system(size: 11))
                TextField("8080", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .disabled(nowPlaying.isServerRunning)
                    .onSubmit { applyPort() }
                Button("Aplicar") { applyPort() }
                    .disabled(nowPlaying.isServerRunning)
            }

            Picker("", selection: $nowPlaying.theme) {
                ForEach(NowPlayingTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            audioRoutingRow

            if let error = nowPlaying.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(copiedFeedback ? "Copiado! ✓" : "Copiar URL do OBS") {
                    nowPlaying.copyOBSURLToClipboard()
                    copiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedFeedback = false
                    }
                }
            }
            Text(nowPlaying.obsURL)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .onAppear { portText = String(nowPlaying.port) }
    }

    private var statusRow: some View {
        Group {
            if nowPlaying.nowPlaying.isPlaying {
                Label(nowPlaying.nowPlaying.title, systemImage: "play.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else if nowPlaying.nowPlaying.trackId != "none" {
                Label(nowPlaying.nowPlaying.title, systemImage: "pause.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                Text("Nenhuma faixa no Music.app")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
    }

    private var audioRoutingRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { nowPlaying.isStreamingOnlyEnabled },
                set: { nowPlaying.setStreamingOnly($0) }
            )) {
                Text("Music só no streaming (não nos alto-falantes)")
                    .font(.system(size: 11))
            }
            .disabled(nowPlaying.isAudioRoutingBusy || !nowPlaying.isAudioCaptureSupported)

            if !nowPlaying.isAudioCaptureSupported {
                Text("Requer macOS 14.2 ou mais recente.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
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
