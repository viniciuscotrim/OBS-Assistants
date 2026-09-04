import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

/// Native macOS notifications for AMS humidity alerts, including the
/// "Abrir app da Bambu" action button.
///
/// This used to be "Iniciar secagem agora", opening this app's own
/// confirmation window and sending `ams_filament_drying` over local MQTT.
/// As of newer firmware (confirmed on an X2D — see
/// github.com/viniciuscotrim/OBS-Assistants/issues/2), the printer requires
/// that command to carry a cryptographic signature only Bambu Lab's own
/// software (Bambu Connect, tied to a cloud account) can produce — sent
/// without it, the printer accepts the MQTT publish with no error but
/// never actually starts drying. Bambu Lab's own documentation confirms
/// AMS control is deliberately gated behind their secure channel now, and
/// replicating that signature would mean routing around a security
/// control they built on purpose — not something this app does, even
/// with the user's own legitimate account. So instead of pretending to
/// act, the notification now sends you straight to the real thing: the
/// official Bambu app, where the command actually works.
final class DryingNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DryingNotificationManager()

    private static let categoryID = "AMS_HUMIDITY_ALERT"
    private static let openBambuAppActionID = "OPEN_BAMBU_APP_ACTION"
    /// Bambu Studio's bundle identifier — the Bambu app most likely to
    /// actually be installed on a Mac (Bambu Handy is phone-only). Opened
    /// via NSWorkspace if present; falls back to a plain alert (mentioning
    /// both Handy and Studio) if it isn't, rather than guessing at a URL
    /// scheme or App Store listing that might be wrong.
    private static let bambuStudioBundleID = "com.bambulab.bambu-studio"

    private var authorized = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        let openAction = UNNotificationAction(
            identifier: Self.openBambuAppActionID,
            title: "Abrir app da Bambu",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            self.authorized = granted
            if let error {
                print("[Drying] notification authorization error: \(error.localizedDescription)")
            } else {
                print("[Drying] notification authorization granted: \(granted)")
            }
        }
    }

    func sendAlert(_ alert: DryingAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [
            "amsID": alert.amsID,
            "trayIndex": alert.trayIndex,
            "filamentType": alert.filamentType,
            "humidityPercent": alert.humidityPercent
        ]
        let request = UNNotificationRequest(identifier: "ams-humidity-\(alert.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Drying] failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    func sendAutoStartedNotice(_ alert: DryingAlert, profile: DryingProfile) {
        let content = UNMutableNotificationContent()
        content.title = "Secagem automática iniciada — AMS \(alert.amsID + 1)"
        content.body = "Slot \(alert.trayIndex + 1) (\(alert.filamentType)) estava em \(Int(alert.humidityPercent))%. Rodando \(Int(profile.dryTemperatureC))°C por \(profile.dryDurationHours == profile.dryDurationHours.rounded() ? "\(Int(profile.dryDurationHours))h" : String(format: "%.1fh", profile.dryDurationHours))."
        let request = UNNotificationRequest(identifier: "ams-autodry-\(alert.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Drying] failed to post auto-dry notice: \(error.localizedDescription)")
            }
        }
    }

    /// Posted when humidity-based auto-stop (AppSettings.autoHumidityStopEnabled)
    /// reads the target humidity and sends the stop command on its own.
    func sendAutoStoppedNotice(amsID: Int, humidityPercent: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Secagem concluída — AMS \(amsID + 1)"
        content.body = "Umidade chegou em \(Int(humidityPercent))% — comando de parada enviado automaticamente."
        let request = UNNotificationRequest(identifier: "ams-autostop-\(amsID)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Drying] failed to post auto-stop notice: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show it even while the app is frontmost-ish (it never really is,
        // being a menu bar app, but this is the correct default anyway).
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        print("[Drying] notification response received: actionIdentifier=\(response.actionIdentifier)")

        // React the same way whether you tap the explicit "Abrir app da
        // Bambu" action button, or just click the notification body itself
        // (UNNotificationDefaultActionIdentifier) — that's the more natural
        // thing to click, and it did nothing before this, which looked
        // exactly like the notification being broken.
        guard response.actionIdentifier == Self.openBambuAppActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            print("[Drying] ignoring notification response — not the open-Bambu-app action or a default tap (identifier: \(response.actionIdentifier))")
            return
        }

        DispatchQueue.main.async {
            Self.openBambuApp()
        }
    }

    /// Opens Bambu Studio if it's installed (the Bambu app most likely to
    /// be on a Mac); otherwise shows a plain alert pointing at Bambu Handy
    /// (phone) or Bambu Studio (desktop) by name, rather than guessing at
    /// a URL scheme or download link that might be wrong. See the class
    /// doc comment for why this app doesn't try to send the command itself.
    static func openBambuApp() {
        #if canImport(AppKit)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bambuStudioBundleID) {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Abra o app da Bambu pra secar"
        alert.informativeText = "O OBS Assistants não consegue enviar o comando de secagem nesse modelo/firmware (a impressora exige um canal seguro só a Bambu Lab tem — veja a issue #2 no GitHub do projeto). Inicie a secagem pelo Bambu Handy (celular) ou pelo Bambu Studio."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        #endif
    }
}
