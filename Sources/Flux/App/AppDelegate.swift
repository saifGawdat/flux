import AppKit
import FluxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil {
            // Launched as a bare executable (`swift run Flux`): behave like a regular app.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        Task { await AppModel.shared.launch() }
    }

    /// Closing the window keeps Flux (and its downloads) running; reopen from the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// On normal quit, checkpoint active downloads before exiting so they resume next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = AppModel.shared.manager else { return .terminateNow }
        Task {
            await manager.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
