import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Small view helpers shared across the root menu and both overlay-tab
/// windows (Impressora / Bambu Studio) — pulled out of MenuBarContentView
/// when the UI was split into separate windows, so all three files can use
/// them without duplicating the code three times.

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 80, alignment: .leading)
                .padding(.top, 3) // roughly centers on the content's first line, even when it grows below (e.g. FieldSearchPicker's results list)
            content
        }
    }
}

/// A tiny "label: [123]suffix" numeric field — used for the per-filament
/// humidity/temperature/duration thresholds, three to a row.
struct LabeledNumberField: View {
    let label: String
    let suffix: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 38)
                .multilineTextAlignment(.trailing)
            Text(suffix)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

func sectionLabel(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
}

/// One row in the root menu's "Servidores" section — status dot, title,
/// Start/Stop, and a settings (gear) button that opens that overlay's own
/// window, plus its OBS URL as click-to-copy text right below (no separate
/// "Copiar URL" button — see `CopyableOBSURLText`).
struct ServerRow: View {
    let title: String
    let isRunning: Bool
    let obsURL: String
    let onToggle: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isRunning ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Button(isRunning ? "Parar" : "Iniciar", action: onToggle)
                    .font(.system(size: 11))
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Configurações do overlay")
            }
            CopyableOBSURLText(url: obsURL)
        }
    }
}

/// The OBS Browser Source URL, shown as plain text that copies itself to
/// the clipboard on a single click — replaces a separate "Copiar URL"
/// button next to every server row.
struct CopyableOBSURLText: View {
    let url: String
    @State private var copied = false

    var body: some View {
        Text(copied ? "Copiado! ✓" : url)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(copied ? .green : .accentColor)
            .lineLimit(1)
            .truncationMode(.middle)
            .contentShape(Rectangle())
            .help("Clique para copiar a URL do OBS")
            .onTapGesture {
                #if canImport(AppKit)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url, forType: .string)
                #endif
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
    }
}
