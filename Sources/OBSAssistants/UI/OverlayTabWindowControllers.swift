import AppKit
import SwiftUI

/// Owns the "Overlay Impressora" window — opened from the root menu-bar
/// popover's "Abrir Overlay Impressora" button. Plain AppKit (NSWindow +
/// NSHostingController), same pattern as DryConfirmationWindowController:
/// a menu-bar-only (LSUIElement) app has no Dock icon to click a window
/// back into view, so this activates and force-orders-front explicitly
/// rather than relying on default window-manager behavior.
@MainActor
final class PrinterOverlayWindowController {
    static let shared = PrinterOverlayWindowController()

    private var window: NSWindow?

    func present(appState: AppState) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let content = PrinterOverlayView().environmentObject(appState)
        let hosting = NSHostingController(rootView: content)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Overlay Impressora"
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
    }
}

/// Owns the "Overlay Bambu Studio" window — same pattern as
/// PrinterOverlayWindowController, a separate window/singleton so both can
/// be open side by side.
@MainActor
final class StudioOverlayWindowController {
    static let shared = StudioOverlayWindowController()

    private var window: NSWindow?

    func present(appState: AppState) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let content = StudioOverlayView().environmentObject(appState)
        let hosting = NSHostingController(rootView: content)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Overlay Bambu Studio"
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
    }
}

/// Owns the "Preview 3D" window — same pattern as
/// StudioOverlayWindowController, a separate window/singleton.
@MainActor
final class PrintPreviewOverlayWindowController {
    static let shared = PrintPreviewOverlayWindowController()

    private var window: NSWindow?

    func present(appState: AppState) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let content = PrintPreviewOverlayView().environmentObject(appState)
        let hosting = NSHostingController(rootView: content)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Preview 3D"
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
    }
}

/// Owns the "Overlay Now Playing" window — same pattern as the other two,
/// just takes a `NowPlayingState` (its own independent ObservableObject)
/// instead of the printer's `AppState`.
@MainActor
final class NowPlayingOverlayWindowController {
    static let shared = NowPlayingOverlayWindowController()

    private var window: NSWindow?

    func present(nowPlayingState: NowPlayingState) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let content = NowPlayingOverlayView(nowPlaying: nowPlayingState)
        let hosting = NSHostingController(rootView: content)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Overlay Now Playing"
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
    }
}
