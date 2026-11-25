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
        if ProcessInfo.processInfo.environment["FLUX_FULLSCREEN"] == "1" { // developer aid
            Task {
                try? await Task.sleep(for: .seconds(1))
                NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.toggleFullScreen(nil)
            }
        }
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
        if let link = env["FLUX_SNAPSHOT_ADD"], let path = env["FLUX_SNAPSHOT"] {
            renderAddSheet(link: link, to: path, wait: Double(env["FLUX_SNAPSHOT_WAIT"] ?? "") ?? 15,
                           dark: env["FLUX_SNAPSHOT_DARK"] == "1")
            return
        }
        guard let path = env["FLUX_SNAPSHOT"] else { return }
        let dark = env["FLUX_SNAPSHOT_DARK"] == "1"
        if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Task {
            try? await Task.sleep(for: .seconds(3))
            let model = AppModel.shared
            for item in model.downloads { // ImageRenderer doesn't run .task: preload previews
                let r = item.record
                _ = await ThumbnailLoader.shared.image(
                    localFile: r.status == .completed && item.fileExists ? r.finalPath : nil,
                    remote: r.previewImageURLs, size: DownloadThumbnail.size)
            }
            let scene = VStack(alignment: .leading, spacing: 0) {
                ForEach(model.downloads) { item in
                    if let group = item.record.group, model.members(of: group.id).first?.id == item.id {
                        GroupHeaderRow(group: group, members: model.members(of: group.id),
                                       isCollapsed: false, onToggle: {}, onSelect: {})
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                        Divider().padding(.leading, 20)
                    }
                    DownloadRow(item: item)
                        .padding(.leading, item.record.group == nil ? 20 : 42)
                        .padding(.trailing, 20)
                        .padding(.vertical, 6)
                    Divider().padding(.leading, 20)
                }
                Spacer()
            }
            .padding(.top, 20)
            .background { SkyBackground() }
            .frame(width: 900, height: Double(env["FLUX_SNAPSHOT_HEIGHT"] ?? "") ?? 560)
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

    /// `FLUX_SNAPSHOT_ADD=<link>`: the add sheet for that link, drawn in an off-screen
    /// window (AppKit controls render there, unlike ImageRenderer) once the link is inspected.
    @MainActor
    private static func renderAddSheet(link: String, to path: String, wait: Double, dark: Bool) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            NSApp.windows.forEach { $0.orderOut(nil) }
            let model = AppModel.shared
            let host = NSHostingView(rootView: AddDownloadSheet(initialText: link)
                .environment(model)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 900),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(wait))
            let size = host.fittingSize
            window.setContentSize(NSSize(width: 600, height: min(max(size.height, 300), 1400)))
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .seconds(1.5))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}
