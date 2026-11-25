import Foundation

/// User preferences, persisted in the `settings` table.
public struct FluxSettings: Codable, Sendable, Equatable {
    public static let connectionChoices = [1, 2, 4, 8, 16, 32]
    public static let concurrentRange = 1...10

    public var downloadDirectory: URL
    public var maxConcurrentDownloads: Int
    public var connectionsPerDownload: Int
    public var resumeOnLaunch: Bool
    public var defaultMediaFormat: MediaFormat
    /// Global speed cap shared by all downloads, when `speedLimitEnabled`.
    public var speedLimitEnabled: Bool
    /// Bytes per second. Kept while the limit is off so turning it back on restores it.
    public var speedLimit: Int64

    /// The global limit in effect, in bytes per second; nil when unlimited.
    public var effectiveSpeedLimit: Int64? { speedLimitEnabled ? speedLimit : nil }

    /// Choices offered in menus (bytes per second). Decimal units, like the speeds Flux shows.
    public static let speedLimitPresets: [Int64] = [
        100_000, 250_000, 500_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000, 25_000_000,
    ]
    public static let minimumSpeedLimit: Int64 = 10_000

    /// Finished downloads go into Documents, Images, Videos, … inside the download folder.
    public var sortIntoCategoryFolders: Bool
    /// Checked in order when a download finishes; the first match decides the folder.
    public var rules: [DownloadRule]
    public var extractArchives: Bool
    /// After a successful extraction, move the archive itself to the Trash.
    public var trashArchivesAfterExtracting: Bool
    public var duplicateAction: DuplicateAction
    /// Named queues, in sidebar order. The main queue isn't listed.
    public var queues: [DownloadQueue]
    /// Offer to download links the user copies (always asks first).
    public var watchClipboard: Bool
    /// Flux's icon in the menu bar, with running downloads and quick actions.
    public var showInMenuBar: Bool
    /// A notification when a download (or a whole playlist) finishes.
    public var notifyWhenFinished: Bool
    /// A notification when a download fails.
    public var notifyOnFailure: Bool
    /// A progress bar on the Dock icon while downloads run.
    public var showDockProgress: Bool
    /// Finished downloads can be found with Spotlight.
    public var indexInSpotlight: Bool
    /// System-wide shortcuts; an action without an entry has none.
    public var globalShortcuts: [GlobalShortcutAction: KeyCombo]
    /// Commands rules can run; each runs only as approved.
    public var commands: [AutomationCommand]
    /// Days of per-minute traffic kept for Statistics.
    public static let trafficRetentionDays = 90

    public enum DuplicateAction: String, Codable, Sendable, CaseIterable {
        /// Keep the new copy and mark it as a duplicate.
        case keepBoth
        /// Move the new copy to the Trash; the existing file stays.
        case trashNew
    }

    public static var defaultDownloadDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }

    public init(
        downloadDirectory: URL = FluxSettings.defaultDownloadDirectory,
        maxConcurrentDownloads: Int = 3,
        connectionsPerDownload: Int = 8,
        resumeOnLaunch: Bool = true,
        defaultMediaFormat: MediaFormat = .best,
        speedLimitEnabled: Bool = false,
        speedLimit: Int64 = 1_000_000,
        sortIntoCategoryFolders: Bool = false,
        rules: [DownloadRule] = [],
        extractArchives: Bool = false,
        trashArchivesAfterExtracting: Bool = false,
        duplicateAction: DuplicateAction = .keepBoth,
        queues: [DownloadQueue] = [],
        watchClipboard: Bool = false,
        showInMenuBar: Bool = true,
        notifyWhenFinished: Bool = true,
        notifyOnFailure: Bool = true,
        showDockProgress: Bool = true,
        indexInSpotlight: Bool = true,
        globalShortcuts: [GlobalShortcutAction: KeyCombo] = GlobalShortcutAction.defaults,
        commands: [AutomationCommand] = []
    ) {
        self.downloadDirectory = downloadDirectory
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.connectionsPerDownload = connectionsPerDownload
        self.resumeOnLaunch = resumeOnLaunch
        self.defaultMediaFormat = defaultMediaFormat
        self.speedLimitEnabled = speedLimitEnabled
        self.speedLimit = speedLimit
        self.sortIntoCategoryFolders = sortIntoCategoryFolders
        self.rules = rules
        self.extractArchives = extractArchives
        self.trashArchivesAfterExtracting = trashArchivesAfterExtracting
        self.duplicateAction = duplicateAction
        self.queues = queues
        self.watchClipboard = watchClipboard
        self.showInMenuBar = showInMenuBar
        self.notifyWhenFinished = notifyWhenFinished
        self.notifyOnFailure = notifyOnFailure
        self.showDockProgress = showDockProgress
        self.indexInSpotlight = indexInSpotlight
        self.globalShortcuts = globalShortcuts
        self.commands = commands
    }

    /// Tolerates missing keys so older stored settings keep working after upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FluxSettings()
        downloadDirectory = try c.decodeIfPresent(URL.self, forKey: .downloadDirectory) ?? defaults.downloadDirectory
        maxConcurrentDownloads = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? defaults.maxConcurrentDownloads
        connectionsPerDownload = try c.decodeIfPresent(Int.self, forKey: .connectionsPerDownload) ?? defaults.connectionsPerDownload
        resumeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .resumeOnLaunch) ?? defaults.resumeOnLaunch
        defaultMediaFormat = (try? c.decodeIfPresent(MediaFormat.self, forKey: .defaultMediaFormat)) ?? defaults.defaultMediaFormat
        speedLimitEnabled = try c.decodeIfPresent(Bool.self, forKey: .speedLimitEnabled) ?? defaults.speedLimitEnabled
        speedLimit = try c.decodeIfPresent(Int64.self, forKey: .speedLimit) ?? defaults.speedLimit
        sortIntoCategoryFolders = try c.decodeIfPresent(Bool.self, forKey: .sortIntoCategoryFolders) ?? defaults.sortIntoCategoryFolders
        rules = (try? c.decodeIfPresent([DownloadRule].self, forKey: .rules)) ?? defaults.rules
        extractArchives = try c.decodeIfPresent(Bool.self, forKey: .extractArchives) ?? defaults.extractArchives
        trashArchivesAfterExtracting = try c.decodeIfPresent(Bool.self, forKey: .trashArchivesAfterExtracting) ?? defaults.trashArchivesAfterExtracting
        duplicateAction = (try? c.decodeIfPresent(DuplicateAction.self, forKey: .duplicateAction)) ?? defaults.duplicateAction
        queues = (try? c.decodeIfPresent([DownloadQueue].self, forKey: .queues)) ?? defaults.queues
        watchClipboard = try c.decodeIfPresent(Bool.self, forKey: .watchClipboard) ?? defaults.watchClipboard
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? defaults.showInMenuBar
        notifyWhenFinished = try c.decodeIfPresent(Bool.self, forKey: .notifyWhenFinished) ?? defaults.notifyWhenFinished
        notifyOnFailure = try c.decodeIfPresent(Bool.self, forKey: .notifyOnFailure) ?? defaults.notifyOnFailure
        showDockProgress = try c.decodeIfPresent(Bool.self, forKey: .showDockProgress) ?? defaults.showDockProgress
        indexInSpotlight = try c.decodeIfPresent(Bool.self, forKey: .indexInSpotlight) ?? defaults.indexInSpotlight
        globalShortcuts = (try? c.decodeIfPresent([GlobalShortcutAction: KeyCombo].self, forKey: .globalShortcuts))
            ?? defaults.globalShortcuts
        commands = (try? c.decodeIfPresent([AutomationCommand].self, forKey: .commands)) ?? defaults.commands
    }

    /// Clamps values into supported ranges.
    public func normalized() -> FluxSettings {
        var s = self
        s.maxConcurrentDownloads = min(max(s.maxConcurrentDownloads, Self.concurrentRange.lowerBound), Self.concurrentRange.upperBound)
        s.connectionsPerDownload = min(max(s.connectionsPerDownload, 1), 32)
        s.speedLimit = max(s.speedLimit, Self.minimumSpeedLimit)
        var seen = Set<UUID>()
        s.queues = s.queues.filter { seen.insert($0.id).inserted }.map { queue in
            var queue = queue
            queue.name = queue.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if queue.name.isEmpty { queue.name = "Queue" }
            queue.maxConcurrent = queue.maxConcurrent.map { max(1, $0) }
            return queue
        }
        // Only combinations that are safe system-wide, and one action per combination
        // (the first in `allCases` keeps it).
        let order = GlobalShortcutAction.allCases
        s.globalShortcuts = s.globalShortcuts.filter { action, combo in
            combo.isAllowedGlobally && !s.globalShortcuts.contains { other, otherCombo in
                otherCombo == combo && order.firstIndex(of: other)! < order.firstIndex(of: action)!
            }
        }
        return s
    }
}
