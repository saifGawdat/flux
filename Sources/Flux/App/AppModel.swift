import AppKit
import FluxCore
import Foundation
import Observation
import UserNotifications

/// Main-actor view state for one download. Rows observe only their own item.
@MainActor @Observable
final class DownloadItemModel: Identifiable {
    let id: UUID
    private(set) var record: DownloadRecord
    private(set) var bytesPerSecond: Double = 0
    private(set) var activeConnections = 0
    private(set) var detail: String?

    init(_ item: DownloadManager.Item) {
        id = item.id
        record = item.record
        apply(item)
    }

    func apply(_ item: DownloadManager.Item) {
        if record != item.record { record = item.record }
        if bytesPerSecond != item.bytesPerSecond { bytesPerSecond = item.bytesPerSecond }
        if activeConnections != item.activeConnections { activeConnections = item.activeConnections }
        if detail != item.detail { detail = item.detail }
    }

    var secondsRemaining: Double? {
        guard record.status == .downloading, bytesPerSecond > 1, let total = record.totalBytes else { return nil }
        return Double(max(0, total - record.receivedBytes)) / bytesPerSecond
    }

    var fileExists: Bool {
        record.finalPath.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// What Quick Look shows: the finished file, else what extracting it produced.
    var previewFile: URL? {
        guard record.status == .completed else { return nil }
        return [record.finalPath, record.extractedPath].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct AddSheetRequest: Identifiable {
    let id = UUID()
    var text: String
}

/// Links read from a file, waiting for the user to confirm the import.
struct ImportRequest: Identifiable {
    let id = UUID()
    var fileName: String
    var entries: [LinkListEntry]
}

/// Creates (queue nil) or edits a named queue.
struct QueueEditorRequest: Identifiable {
    let id = UUID()
    var queue: DownloadQueue?
}

/// Shows downloads in the window (from Spotlight, a notification, the menu bar).
struct FocusRequest: Equatable {
    let id = UUID()
    var downloads: Set<UUID>
}

/// Opens the Info sheet for one download, optionally straight into changing its link.
struct InfoSheetRequest: Identifiable {
    let id = UUID()
    var download: UUID
    var editLink = false
}

/// Bridges the `DownloadManager` actor to SwiftUI. Holds no business logic: every user
/// action becomes a manager intent, and all state flows back through manager events.
@MainActor @Observable
final class AppModel {
    enum Phase {
        case loading
        case ready
        case failed(String)
    }

    static let shared = AppModel()

    private(set) var phase: Phase = .loading
    private(set) var downloads: [DownloadItemModel] = []
    private(set) var settings = FluxSettings()
    private(set) var mediaTools = MediaTools.none
    private(set) var toolVersions: [String: String] = [:]
    var addSheet: AddSheetRequest?
    var infoSheet: InfoSheetRequest?
    var importSheet: ImportRequest?
    var queueEditor: QueueEditorRequest?
    /// Where the `flux` command line connects; nil when not accepting commands.
    private(set) var controlSocket: URL?
    var errorMessage: String?
    /// Downloads the window should select; cleared once shown.
    var focusRequest: FocusRequest?
    /// Quick Look: the file shown and the files the panel can page through.
    var quickLookURL: URL?
    private(set) var quickLookURLs: [URL] = []
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// Global shortcuts the system refused because another app holds them.
    private(set) var unavailableShortcuts: Set<GlobalShortcutAction> = []
    let loginItem = LoginItem()

    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private var milestones = MilestoneTracker()
    @ObservationIgnored private let dock = DockProgress()
    @ObservationIgnored private let spotlight = SpotlightIndexer()
    @ObservationIgnored private var spotlightSync = SpotlightSync()
    @ObservationIgnored private var spotlightChanges: [SpotlightSync.Change] = []
    /// Spotlight work runs in order: a rebuild must not overtake later updates.
    @ObservationIgnored private var spotlightTask: Task<Void, Never>?
    @ObservationIgnored private var spotlightEnabled = false
    @ObservationIgnored private var refreshScheduled = false

    @ObservationIgnored private(set) var manager: DownloadManager?
    @ObservationIgnored private var index: [UUID: DownloadItemModel] = [:]
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private var controlServer: ControlServer?
    /// Opens (or brings back) the main window; set by the window's views.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private(set) lazy var clipboard = ClipboardWatcher(model: self)

    private init() {
        notifier.onResponse = { [weak self] in self?.respond(to: $0) }
        GlobalHotKeys.shared.perform = { [weak self] in self?.run($0) }
    }

    // MARK: Lifecycle

    func launch() async {
        guard !didLaunch else { return }
        didLaunch = true
        do {
            // Developer aid: FLUX_DATABASE runs a throwaway instance beside the real one.
            let override = ProcessInfo.processInfo.environment["FLUX_DATABASE"].map { URL(fileURLWithPath: $0) }
            let database = try FluxDatabase(url: override ?? FluxDatabase.defaultURL)
            let manager = try await DownloadManager(database: database)
            self.manager = manager
            let events = await manager.events()
            Task { [weak self] in
                for await event in events { self?.handle(event) }
            }
            await manager.start()
            phase = .ready
            startControlServer(manager, separateDatabase: override != nil)
            clipboard.update(enabled: settings.watchClipboard)
            Task { await notifier.refreshAuthorization(); notifierChanged() }
            await loadMediaTools(from: manager)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func handle(_ event: DownloadManager.Event) {
        switch event {
        case .reset(let items, let settings):
            self.settings = settings
            index = Dictionary(uniqueKeysWithValues: items.map { ($0.id, DownloadItemModel($0)) })
            downloads = items.compactMap { index[$0.id] }
            milestones.baseline(items.map(\.record))
            spotlightEnabled = false // rebuilt by applySystemSettings
            applySystemSettings()
        case .updated(let item):
            let news = milestones.observe(item.record) { [index] in index[$0]?.record }
            if !news.isEmpty { notifier.post(news, settings: settings) }
            if spotlightEnabled, let change = spotlightSync.update(item.record, fileExists: Self.fileExists) {
                spotlightChanges.append(change)
            }
            if let model = index[item.id] {
                model.apply(item)
            } else {
                let model = DownloadItemModel(item)
                index[item.id] = model
                let position = downloads.firstIndex { DownloadRecord.listOrder(item.record, $0.record) } ?? downloads.endIndex
                downloads.insert(model, at: position)
            }
        case .removed(let ids):
            let set = Set(ids)
            for id in ids { index[id] = nil }
            downloads.removeAll { set.contains($0.id) }
            milestones.forget(ids)
            spotlightChanges += spotlightSync.remove(ids).map { .delete($0) }
        case .settingsChanged(let settings):
            self.settings = settings
            clipboard.update(enabled: settings.watchClipboard)
            applySystemSettings()
        }
        scheduleRefresh()
    }

    // MARK: Menu bar, Dock, Spotlight, shortcuts

    nonisolated private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Dock and Spotlight follow the list at most twice a second, not on every update.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            refreshScheduled = false
            updateDockBadge()
            dock.update(settings.showDockProgress ? OverallProgress.fraction(of: downloads.lazy.map(\.record)) : nil)
            flushSpotlight()
        }
    }

    private func applySystemSettings() {
        GlobalHotKeys.shared.register(settings.globalShortcuts)
        unavailableShortcuts = GlobalHotKeys.shared.unavailable
        if settings.indexInSpotlight != spotlightEnabled {
            spotlightEnabled = settings.indexInSpotlight
            spotlightChanges = []
            if spotlightEnabled {
                let entries = spotlightSync.rebuild(downloads.map(\.record), fileExists: Self.fileExists)
                enqueueSpotlight { [spotlight] in await spotlight.replaceAll(with: entries) }
            } else {
                spotlightSync.clear()
                enqueueSpotlight { [spotlight] in await spotlight.removeAll() }
            }
        }
        scheduleRefresh()
    }

    private func flushSpotlight() {
        guard !spotlightChanges.isEmpty else { return }
        let changes = spotlightChanges
        spotlightChanges = []
        enqueueSpotlight { [spotlight] in await spotlight.apply(changes) }
    }

    private func enqueueSpotlight(_ work: @escaping @Sendable () async -> Void) {
        guard spotlight.isAvailable else { return }
        let previous = spotlightTask
        spotlightTask = Task {
            await previous?.value
            await work()
        }
    }

    /// Re-lists every finished download in Spotlight (Settings › System).
    var spotlightCount: Int { spotlightSync.count }

    func notifierChanged() {
        notificationStatus = notifier.authorization
    }

    private func respond(to response: Notifier.Response) {
        switch response {
        case .show(let ids):
            // A playlist notification names the group: show all of its downloads.
            let members = Set(downloads.filter { $0.record.group.map { ids.contains($0.id) } ?? false }.map(\.id))
            focus(members.isEmpty ? Set(ids) : members)
            bringForward()
        case .open(let id):
            if let item = index[id], item.fileExists { open(item) } else { focus([id]); bringForward() }
        case .reveal(let id):
            if let item = index[id] { reveal(item) }
        case .retry(let ids):
            resume(Set(ids))
        }
    }

    private func run(_ action: GlobalShortcutAction) {
        switch action {
        case .addDownload:
            addFromAnywhere()
        case .showFlux:
            let windowShown = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if NSApp.isActive && windowShown { NSApp.hide(nil) } else { bringForward() }
        case .pauseResumeAll:
            if downloads.contains(where: { $0.record.status.canPause }) { pauseAll() } else { resumeAll() }
        }
    }

    /// Flux in front with its window open.
    func bringForward() {
        NSApp.activate()
        openMainWindow?()
    }

    /// The Add Download sheet over the Flux window, from the menu bar or a shortcut.
    func addFromAnywhere() {
        bringForward()
        guard addSheet == nil, manager != nil else { return }
        presentAddSheet()
    }

    /// Selects these downloads in the window (switching to History if needed).
    func focus(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        focusRequest = FocusRequest(downloads: ids)
    }

    /// Space / ⌘Y: previews the selected finished files, or closes the preview.
    func quickLook(_ ids: Set<UUID>) {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        let urls = downloads.filter { ids.contains($0.id) }.compactMap(\.previewFile)
        guard let first = urls.first else { return }
        quickLookURLs = urls
        quickLookURL = first
    }

    func canQuickLook(_ ids: Set<UUID>) -> Bool {
        downloads.contains { ids.contains($0.id) && $0.previewFile != nil }
    }

    // MARK: Command line

    /// Lets the `flux` tool drive this app. A developer instance on another database only
    /// listens when given its own socket (`FLUX_SOCKET`), so it never takes the real one.
    private func startControlServer(_ manager: DownloadManager, separateDatabase: Bool) {
        if separateDatabase, ProcessInfo.processInfo.environment["FLUX_SOCKET"] == nil { return }
        let server = ControlServer()
        let handler = ControlHandler(manager: manager)
        do {
            try server.start { await handler.handle($0) }
            controlServer = server
            controlSocket = server.socketURL
        } catch {
            // Flux works without it; only the command line is unavailable.
            NSLog("Flux: command line unavailable: \(error.localizedDescription)")
        }
    }

    func stopControlServer() {
        controlServer?.stop()
        controlServer = nil
        controlSocket = nil
    }

    // MARK: Derived state

    func item(_ id: UUID) -> DownloadItemModel? { index[id] }

    /// The Downloads list: everything not yet cleared into History.
    var current: [DownloadItemModel] { downloads.filter { !$0.record.isArchived } }
    /// Cleared downloads, newest first.
    var history: [DownloadItemModel] {
        downloads.filter(\.record.isArchived)
            .sorted { ($0.record.completedAt ?? $0.record.createdAt) > ($1.record.completedAt ?? $1.record.createdAt) }
    }

    var activeCount: Int { downloads.lazy.filter { $0.record.status.isActive }.count }
    var queuedCount: Int { downloads.lazy.filter { $0.record.status == .queued }.count }
    var totalSpeed: Double { downloads.reduce(0) { $0 + $1.bytesPerSecond } }

    private var lastBadge: String?
    private func updateDockBadge() {
        let pending = activeCount + queuedCount
        let badge = pending > 0 ? String(pending) : nil
        guard badge != lastBadge else { return }
        lastBadge = badge
        NSApp?.dockTile.badgeLabel = badge
    }

    // MARK: Intents

    func presentAddSheet(prefill: String? = nil) {
        let clipboardLinks = LinkExtractor.urls(in: NSPasteboard.general.string(forType: .string) ?? "")
        addSheet = AddSheetRequest(text: prefill ?? clipboardLinks.map(\.absoluteString).joined(separator: "\n"))
    }

    func add(
        _ urls: [URL], directory: URL? = nil, connections: Int? = nil, priority: DownloadPriority = .normal,
        startImmediately: Bool = true, mediaFormat: MediaFormat? = nil
    ) {
        let requests = urls.map {
            DownloadManager.NewDownload(
                url: $0, directory: directory, connections: connections,
                priority: priority, startImmediately: startImmediately, mediaFormat: mediaFormat)
        }
        perform { try await $0.add(requests) }
    }

    /// Adds prepared downloads (a playlist's videos, a gallery's images).
    func add(_ requests: [DownloadManager.NewDownload]) {
        guard !requests.isEmpty else { return }
        perform { try await $0.add(requests) }
    }

    func pause(_ ids: Set<UUID>) { perform { try await $0.pause(ids) } }
    func resume(_ ids: Set<UUID>) { perform { try await $0.resume(ids) } }
    func cancel(_ ids: Set<UUID>) { perform { try await $0.cancel(ids) } }
    func remove(_ ids: Set<UUID>, trashFiles: Bool) { perform { try await $0.remove(ids, trashFiles: trashFiles) } }
    func setPriority(_ priority: DownloadPriority, for ids: Set<UUID>) { perform { await $0.setPriority(priority, for: ids) } }
    func pauseAll() { pause(Set(downloads.filter { $0.record.status.canPause }.map(\.id))) }
    func resumeAll() { resume(Set(downloads.filter { $0.record.status == .paused }.map(\.id))) }
    func retryFailed() { resume(Set(downloads.filter { $0.record.status == .failed }.map(\.id))) }
    var failedCount: Int { downloads.lazy.filter { $0.record.status == .failed }.count }

    /// Downloads that belong to one playlist or gallery, in playlist order.
    func members(of group: UUID) -> [DownloadItemModel] {
        downloads.filter { $0.record.group?.id == group && !$0.record.isArchived }
    }

    // MARK: Queues

    func queue(_ id: UUID?) -> DownloadQueue? {
        id.flatMap { id in settings.queues.first { $0.id == id } }
    }

    func startQueue(_ id: UUID) { perform { await $0.startQueue(id) } }
    func stopQueue(_ id: UUID) { perform { await $0.stopQueue(id) } }
    func move(_ ids: Set<UUID>, toQueue queue: UUID?) { perform { await $0.move(ids, toQueue: queue) } }

    /// Adds or replaces a queue (matched by ID).
    func saveQueue(_ queue: DownloadQueue) {
        updateSettings { settings in
            if let index = settings.queues.firstIndex(where: { $0.id == queue.id }) {
                settings.queues[index] = queue
            } else {
                settings.queues.append(queue)
            }
        }
    }

    /// Deletes a queue; its downloads move to the main queue.
    func deleteQueue(_ id: UUID) {
        updateSettings { $0.queues.removeAll { $0.id == id } }
    }

    /// "Waiting for “Night” · starts tomorrow at 02:00".
    func waitingText(for queueID: UUID?) -> String? {
        guard let queue = queue(queueID) else { return nil }
        if queue.isRunning { return "Queued in “\(queue.name)”" }
        var text = "Waiting for “\(queue.name)”"
        if let next = queue.schedule?.next(after: Date()), next.change == .start {
            text += " · starts \(Format.when(next.date))"
        }
        return text
    }

    // MARK: Import & export

    /// Reads a list of links and shows the import sheet.
    func importLinks(from url: URL) {
        do {
            let entries = try LinkList.read(url)
            importSheet = ImportRequest(fileName: url.lastPathComponent, entries: entries)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importLinks(_ entries: [LinkListEntry], queue: UUID?, startImmediately: Bool) {
        add(entries.map { entry in
            DownloadManager.NewDownload(
                url: entry.url, directory: entry.directory, fileName: entry.fileName,
                startImmediately: startImmediately, referer: entry.referer,
                mirrors: entry.mirrors, checksum: entry.checksum, queue: queue)
        })
    }

    /// Writes the Downloads list (and History, if asked) to a file.
    func export(to url: URL, format: LinkListFormat, includeHistory: Bool) {
        let records = downloads.filter { includeHistory || !$0.record.isArchived }.map(\.record)
        do {
            try LinkList.export(records, format: format).write(to: url, options: .atomic)
        } catch {
            errorMessage = "Couldn’t save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func archive(_ ids: Set<UUID>) { perform { await $0.archive(ids) } }
    func clearHistory() { perform { try await $0.clearHistory() } }
    func extract(_ id: UUID) { perform { try await $0.extract(id) } }

    /// Adds a fresh download of the same link (from History or a finished row).
    func downloadAgain(_ ids: Set<UUID>) {
        let requests = downloads.filter { ids.contains($0.id) }.map { item in
            DownloadManager.NewDownload(
                url: item.record.url, kind: item.record.kind, mediaFormat: item.record.mediaFormat,
                title: item.record.title, referer: item.record.referer, mirrors: item.record.mirrors,
                checksum: item.record.checksum)
        }
        add(requests)
    }

    /// A finished, still existing download of this link, if any.
    func existingDownload(of url: URL) -> DownloadItemModel? {
        downloads.first { $0.record.url == url && $0.record.status == .completed && $0.fileExists }
    }

    func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: Engine settings per download

    func showInfo(_ id: UUID, editLink: Bool = false) {
        infoSheet = InfoSheetRequest(download: id, editLink: editLink)
    }

    func setSpeedLimit(_ bytesPerSecond: Int64?, for ids: Set<UUID>) {
        perform { await $0.setSpeedLimit(bytesPerSecond, for: ids) }
    }

    /// Continues a download from a new link (e.g. after the old one expired).
    func updateLink(_ id: UUID, to url: URL) {
        perform { try await $0.updateLink(id, to: url) }
    }

    func setMirrors(_ mirrors: [URL], for id: UUID) {
        perform { try await $0.setMirrors(mirrors, for: id) }
    }

    /// For a finished download, checks the file now and returns whether it matches.
    func setChecksum(_ checksum: Checksum?, for id: UUID) async throws -> Bool? {
        guard let manager else { return nil }
        return try await manager.setChecksum(checksum, for: id)
    }

    /// Global limit on or off, keeping the chosen amount.
    func setGlobalSpeedLimit(enabled: Bool, amount: Int64? = nil) {
        updateSettings {
            $0.speedLimitEnabled = enabled
            if let amount { $0.speedLimit = amount }
        }
    }

    func toggleGlobalSpeedLimit() { setGlobalSpeedLimit(enabled: !settings.speedLimitEnabled) }

    /// Moves finished downloads from the list into History.
    func clearCompleted() {
        archive(Set(current.filter { $0.record.status == .completed }.map(\.id)))
    }

    func updateSettings(_ change: (inout FluxSettings) -> Void) {
        var newSettings = settings
        change(&newSettings)
        settings = newSettings
        let committed = newSettings
        perform { try await $0.updateSettings(committed) }
    }

    // MARK: Media tools

    /// Re-scans for yt-dlp and ffmpeg, e.g. after installing them with Homebrew.
    func refreshMediaTools() {
        guard let manager else { return }
        Task {
            await manager.refreshMediaTools()
            await loadMediaTools(from: manager)
        }
    }

    private func loadMediaTools(from manager: DownloadManager) async {
        let tools = await manager.mediaTools
        mediaTools = tools
        var versions: [String: String] = [:]
        for case let tool? in [tools.ytdlp, tools.ffmpeg, tools.galleryDL] {
            versions[tool.lastPathComponent] = await MediaTools.version(of: tool)
        }
        toolVersions = versions
    }

    /// Finds what's behind one link: a video (with sizes per format), a playlist, images.
    func inspect(_ url: URL) async -> LinkInspection {
        await LinkInspector.inspect(url, tools: mediaTools)
    }

    static let installCommand = "brew install yt-dlp ffmpeg gallery-dl"

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
    }

    private func perform(_ operation: @escaping @Sendable (DownloadManager) async throws -> Void) {
        guard let manager else { return }
        Task {
            do {
                try await operation(manager)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Finder

    func open(_ item: DownloadItemModel) {
        guard let path = item.record.finalPath, item.fileExists else { return }
        NSWorkspace.shared.open(path)
    }

    func reveal(_ item: DownloadItemModel) {
        if let path = item.record.finalPath, item.fileExists {
            NSWorkspace.shared.activateFileViewerSelecting([path])
        } else if let extracted = item.record.extractedPath, FileManager.default.fileExists(atPath: extracted.path) {
            NSWorkspace.shared.activateFileViewerSelecting([extracted])
        } else if let part = item.record.partFileURL, FileManager.default.fileExists(atPath: part.path) {
            NSWorkspace.shared.activateFileViewerSelecting([part])
        } else {
            NSWorkspace.shared.open(item.record.directory)
        }
    }

    func revealFolder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func copyLinks(_ ids: Set<UUID>) {
        let links = downloads.filter { ids.contains($0.id) }.map(\.record.url.absoluteString)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        clipboard.ignoreCurrentContents()
    }
}
