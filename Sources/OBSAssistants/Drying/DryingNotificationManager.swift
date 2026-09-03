import Foundation
import UserNotifications

/// Native macOS notifications for AMS humidity alerts, including the
/// "Iniciar secagem agora" action button. Notification identifiers/userInfo
/// carry enough of the DryingAlert to reconstruct it when the action is
/// tapped (UNUserNotificationCenter delivers that asynchronously, possibly
/// after this process's in-memory alert object is long gone).
final class DryingNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DryingNotificationManager()

    private static let categoryID = "AMS_HUMIDITY_ALERT"
    private static let startDryingActionID = "START_DRYING_ACTION"

    /// Fired when the user taps "Iniciar secagem agora" on a notification.
    /// Always delivered on the main thread.
    var onStartDryingAction: ((_ amsID: Int, _ trayIndex: Int, _ filamentType: String, _ humidityPercent: Double) -> Void)?

    private var authorized = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        let startAction = UNNotificationAction(
            identifier: Self.startDryingActionID,
            title: "Iniciar secagem agora",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [startAction],
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

        // React the same way whether you tap the explicit "Iniciar secagem
        // agora" action button, or just click the notification body itself
        // (UNNotificationDefaultActionIdentifier) — that's the more natural
        // thing to click, and it did nothing before this, which looked
        // exactly like the notification being broken.
        guard response.actionIdentifier == Self.startDryingActionID
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            print("[Drying] ignoring notification response — not the start-drying action or a default tap (identifier: \(response.actionIdentifier))")
            return
        }

        let info = response.notification.request.content.userInfo
        guard let amsID = info["amsID"] as? Int,
              let trayIndex = info["trayIndex"] as? Int,
              let filamentType = info["filamentType"] as? String,
              let humidityPercent = info["humidityPercent"] as? Double else {
            print("[Drying] couldn't parse userInfo from notification: \(info)")
            return
        }

        guard onStartDryingAction != nil else {
            print("[Drying] onStartDryingAction handler isn't set yet — the tap arrived before AppState finished wiring it up")
            return
        }

        print("[Drying] opening confirmation for AMS \(amsID + 1), slot \(trayIndex + 1) (\(filamentType))")
        DispatchQueue.main.async {
            self.onStartDryingAction?(amsID, trayIndex, filamentType, humidityPercent)
        }
    }
}
