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
        speedLimit: Int64 = 1_000_000
    ) {
        self.downloadDirectory = downloadDirectory
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.connectionsPerDownload = connectionsPerDownload
        self.resumeOnLaunch = resumeOnLaunch
        self.defaultMediaFormat = defaultMediaFormat
        self.speedLimitEnabled = speedLimitEnabled
        self.speedLimit = speedLimit
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
    }

    /// Clamps values into supported ranges.
    public func normalized() -> FluxSettings {
        var s = self
        s.maxConcurrentDownloads = min(max(s.maxConcurrentDownloads, Self.concurrentRange.lowerBound), Self.concurrentRange.upperBound)
        s.connectionsPerDownload = min(max(s.connectionsPerDownload, 1), 32)
        s.speedLimit = max(s.speedLimit, Self.minimumSpeedLimit)
        return s
    }
}
