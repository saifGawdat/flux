import AppKit
import SwiftUI
import FluxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Early, so a notification that launched Flux reaches its delegate.
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = AppModel.shared.notifier
    }

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

    /// A Spotlight result: show that download.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let id = SpotlightIndexer.downloadID(from: userActivity) else { return false }
        AppModel.shared.focus([id])
        AppModel.shared.bringForward()
        return true
    }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppModel.shared.openMainWindow?() }
        return true
    }

    // MARK: Dock menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let model = AppModel.shared
        guard model.manager != nil else { return nil }
        let menu = NSMenu()
        let running = model.activeCount
        if running > 0 {
            let status = NSMenuItem(title: "\(running) downloading · \(Format.speed(model.totalSpeed))", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
        }
        menu.addItem(item("Add Download…", #selector(addDownload)))
        if model.downloads.contains(where: { $0.record.status.canPause }) {
            menu.addItem(item("Pause All", #selector(pauseAll)))
        } else if model.downloads.contains(where: { $0.record.status == .paused }) {
            menu.addItem(item("Resume All", #selector(resumeAll)))
        }
        let limit = item("Limit Speed to \(Format.limit(model.settings.speedLimit))", #selector(toggleSpeedLimit))
        limit.state = model.settings.speedLimitEnabled ? .on : .off
        menu.addItem(limit)
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @MainActor @objc private func addDownload() { AppModel.shared.addFromAnywhere() }
    @MainActor @objc private func pauseAll() { AppModel.shared.pauseAll() }
    @MainActor @objc private func resumeAll() { AppModel.shared.resumeAll() }
    @MainActor @objc private func toggleSpeedLimit() { AppModel.shared.toggleGlobalSpeedLimit() }

    /// On normal quit, checkpoint active downloads before exiting so they resume next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = AppModel.shared.manager else { return .terminateNow }
        AppModel.shared.stopControlServer()
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
            renderOffscreen(to: path, width: 600, wait: Double(env["FLUX_SNAPSHOT_WAIT"] ?? "") ?? 15,
                            dark: env["FLUX_SNAPSHOT_DARK"] == "1") { AddDownloadSheet(initialText: link) }
            return
        }
        if let view = env["FLUX_SNAPSHOT_VIEW"], let path = env["FLUX_SNAPSHOT"] {
            // "organize": Settings › Organize; "history": the History list; "queue": the
            // queue editor (first queue); "import": the import sheet for FLUX_SNAPSHOT_FILE;
            // "clipboard": the copied-link prompt; "queues": the list of the first queue.
            // "system": Settings › System; "menubar": the menu bar window.
            let widths = ["history": 760.0, "queues": 760, "queue": 460, "import": 480, "clipboard": 340, "general": 540,
                          "system": 540, "menubar": 346, "statistics": 860, "automation": 540, "rule": 520]
            renderOffscreen(to: path, width: widths[view] ?? 540, wait: Double(env["FLUX_SNAPSHOT_WAIT"] ?? "") ?? 3,
                            dark: env["FLUX_SNAPSHOT_DARK"] == "1") {
                let model = AppModel.shared
                return Group {
                    switch view {
                    case "history":
                        HistoryView(search: "", selection: .constant([])).frame(height: 520)
                    case "queue":
                        QueueEditor(queue: model.settings.queues.first)
                    case "import":
                        let file = URL(fileURLWithPath: env["FLUX_SNAPSHOT_FILE"] ?? "/dev/null")
                        ImportSheet(request: ImportRequest(fileName: file.lastPathComponent,
                                                           entries: (try? LinkList.read(file)) ?? []))
                    case "clipboard":
                        ClipboardPrompt(links: [URL(string: "https://example.com/files/Flux-2.0.dmg")!],
                                        onDownload: {}, onOptions: {}, onClose: {}).padding(0)
                    case "queues":
                        let queue = model.settings.queues.first
                        DownloadList(items: model.current.filter { $0.record.queueID == queue?.id }, selection: .constant([]),
                                     emptyFilter: .all, isSearching: false, inQueue: true)
                            .safeAreaInset(edge: .top, spacing: 0) { if let queue { QueueHeaderBar(queue: queue) } }
                            .frame(height: 360)
                    case "general":
                        SettingsView()
                    case "system":
                        SystemSettings()
                    case "menubar":
                        MenuBarContent().background(.background)
                    case "statistics":
                        StatisticsView().frame(height: 720)
                    case "automation":
                        AutomationSettings()
                    case "rule":
                        RuleSnapshot()
                    default:
                        OrganizeSettings()
                    }
                }
            }
            return
        }
        if let index = env["FLUX_SNAPSHOT_INFO"].flatMap(Int.init), let path = env["FLUX_SNAPSHOT"] {
            let editLink = env["FLUX_SNAPSHOT_EDITLINK"] == "1"
            renderOffscreen(to: path, width: 560, wait: Double(env["FLUX_SNAPSHOT_WAIT"] ?? "") ?? 3,
                            dark: env["FLUX_SNAPSHOT_DARK"] == "1") {
                let model = AppModel.shared
                let id = model.downloads.indices.contains(index) ? model.downloads[index].id : UUID()
                return DownloadInfoSheet(request: InfoSheetRequest(download: id, editLink: editLink))
            }
            return
        }
        guard let path = env["FLUX_SNAPSHOT"] else { return }
        let dark = env["FLUX_SNAPSHOT_DARK"] == "1"
        if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Task {
            try? await Task.sleep(for: .seconds(3))
            let model = AppModel.shared
            for item in model.current { // ImageRenderer doesn't run .task: preload previews
                let r = item.record
                _ = await ThumbnailLoader.shared.image(
                    localFile: r.status == .completed && item.fileExists ? r.finalPath : nil,
                    remote: r.previewImageURLs, size: DownloadThumbnail.size)
            }
            let scene = VStack(alignment: .leading, spacing: 0) {
                ForEach(model.current) { item in
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

    /// `FLUX_SNAPSHOT_ADD=<link>`: the add sheet for that link; `FLUX_SNAPSHOT_INFO=<n>`:
    /// the Info sheet of the n-th download in the list (`FLUX_SNAPSHOT_EDITLINK=1` opens
    /// it on changing the link). Drawn in an off-screen window (AppKit controls render
    /// there, unlike ImageRenderer) after `FLUX_SNAPSHOT_WAIT` seconds.
    @MainActor
    private static func renderOffscreen<Content: View>(
        to path: String, width: CGFloat, wait: Double, dark: Bool, _ content: @escaping @MainActor () -> Content
    ) {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            NSApp.windows.forEach { $0.orderOut(nil) }
            let model = AppModel.shared
            let host = NSHostingView(rootView: content()
                .environment(model)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: 900),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(wait))
            let size = host.fittingSize
            window.setContentSize(NSSize(width: width, height: min(max(size.height, 300), 1400)))
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
