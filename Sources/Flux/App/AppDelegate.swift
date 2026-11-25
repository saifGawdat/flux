import AppKit
import SwiftUI
import FluxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil {
            // Launched as a bare executable (`swift run Flux`): behave like a regular app.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        Task { await AppModel.shared.launch() }
        WindowSnapshot.runIfRequested()
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

/// Developer aid: `FLUX_SNAPSHOT=/path/out.png` renders the themed download list (sky
/// background + real rows) to a PNG a few seconds after launch, then quits.
/// `FLUX_SNAPSHOT_DARK=1` renders dark mode. Uses ImageRenderer, so it needs no
/// screen-recording permission (AppKit-hosted controls like List chrome aren't drawn).
enum WindowSnapshot {
    @MainActor
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["FLUX_SNAPSHOT"] else { return }
        let dark = env["FLUX_SNAPSHOT_DARK"] == "1"
        if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Task {
            try? await Task.sleep(for: .seconds(3))
            let model = AppModel.shared
            let scene = VStack(alignment: .leading, spacing: 0) {
                ForEach(model.downloads) { item in
                    DownloadRow(item: item)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                    Divider().padding(.leading, 20)
                }
                Spacer()
            }
            .padding(.top, 20)
            .background { SkyBackground() }
            .frame(width: 900, height: 560)
            .environment(model)
            .tint(FluxTheme.accent)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}
