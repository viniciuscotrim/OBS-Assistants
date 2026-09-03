import AppKit
import SwiftUI

/// Owns the confirmation window that pops up when you tap "Iniciar secagem
/// agora" on a notification. Plain AppKit (NSWindow + NSHostingView)
/// instead of a SwiftUI `Window` scene: this needs to be opened
/// programmatically from a UNUserNotificationCenter delegate callback,
/// which isn't a SwiftUI view context — AppKit gives direct, simple control
/// over show/order-front from anywhere, no environment-action plumbing.
@MainActor
final class DryConfirmationWindowController {
    static let shared = DryConfirmationWindowController()

    private var window: NSWindow?

    func present(
        alert: DryingAlert,
        settings: AppSettings,
        onConfirm: @escaping (_ filamentType: String, _ tempC: Double, _ coolingTempC: Double, _ durationHours: Double, _ rotateTray: Bool) -> Void
    ) {
        let content = DryConfirmationView(
            alert: alert,
            settings: settings,
            onConfirm: { [weak self] filamentType, tempC, coolingTempC, durationHours, rotateTray in
                onConfirm(filamentType, tempC, coolingTempC, durationHours, rotateTray)
                self?.close()
            },
            onCancel: { [weak self] in self?.close() }
        )

        let hosting = NSHostingController(rootView: content)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Secagem do AMS"
        newWindow.styleMask = [.titled, .closable]
        newWindow.isReleasedWhenClosed = false
        newWindow.level = .floating // outrank whatever else is on screen (OBS, browser, ...) instead of opening silently behind it
        newWindow.center()
        window = newWindow

        // A menu-bar-only (LSUIElement/.accessory) app has no Dock icon to
        // click to bring this window forward, and its default activation
        // policy is weaker than a regular app's — activate explicitly and
        // force-order-front so the window doesn't open hidden behind
        // whatever else is on screen, which would look exactly like
        // nothing happened.
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
        print("[Drying] confirmation window presented for AMS \(alert.amsID + 1), slot \(alert.trayIndex + 1)")
    }

    func close() {
        window?.close()
        window = nil
    }
}
