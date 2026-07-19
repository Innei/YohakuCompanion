import AppKit
import SwiftUI

@MainActor
final class MomentComposerWindowManager: NSObject, NSWindowDelegate {
    static let shared = MomentComposerWindowManager()

    private var window: NSWindow?

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Publish This Moment"
            window.contentMinSize = NSSize(width: 560, height: 520)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.delegate = self
            window.contentViewController = NSHostingController(
                rootView: MomentComposerView(model: MomentComposerViewModel())
            )
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func closeWindow() {
        window?.performClose(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !YohakuCompanionService.shared.isPublishingMoment else {
            NSSound.beep()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window
        else { return }
        window = nil

        let hasVisibleWindow = NSApp.windows.contains {
            $0 !== closingWindow && $0.isVisible && $0.styleMask.contains(.titled)
        }
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
