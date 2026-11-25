import AppKit
import FluxCore
import Foundation
import Observation

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
}

struct AddSheetRequest: Identifiable {
    let id = UUID()
    var text: String
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
    var errorMessage: String?

    @ObservationIgnored private(set) var manager: DownloadManager?
    @ObservationIgnored private var index: [UUID: DownloadItemModel] = [:]
    @ObservationIgnored private var didLaunch = false

    private init() {}

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
        case .updated(let item):
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
        case .settingsChanged(let settings):
            self.settings = settings
        }
        updateDockBadge()
    }

    // MARK: Derived state

    func item(_ id: UUID) -> DownloadItemModel? { index[id] }

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
        downloads.filter { $0.record.group?.id == group }
    }

    func clearCompleted() {
        remove(Set(downloads.filter { $0.record.status == .completed }.map(\.id)), trashFiles: false)
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
    }
}
