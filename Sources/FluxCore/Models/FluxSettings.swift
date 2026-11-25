import Foundation

/// User preferences, persisted in the `settings` table.
public struct FluxSettings: Codable, Sendable, Equatable {
    public static let connectionChoices = [1, 2, 4, 8, 16, 32]
    public static let concurrentRange = 1...10

    public var downloadDirectory: URL
    public var maxConcurrentDownloads: Int
    public var connectionsPerDownload: Int
    public var resumeOnLaunch: Bool

    public static var defaultDownloadDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }

    public init(
        downloadDirectory: URL = FluxSettings.defaultDownloadDirectory,
        maxConcurrentDownloads: Int = 3,
        connectionsPerDownload: Int = 8,
        resumeOnLaunch: Bool = true
    ) {
        self.downloadDirectory = downloadDirectory
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.connectionsPerDownload = connectionsPerDownload
        self.resumeOnLaunch = resumeOnLaunch
    }

    /// Tolerates missing keys so older stored settings keep working after upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FluxSettings()
        downloadDirectory = try c.decodeIfPresent(URL.self, forKey: .downloadDirectory) ?? defaults.downloadDirectory
        maxConcurrentDownloads = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? defaults.maxConcurrentDownloads
        connectionsPerDownload = try c.decodeIfPresent(Int.self, forKey: .connectionsPerDownload) ?? defaults.connectionsPerDownload
        resumeOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .resumeOnLaunch) ?? defaults.resumeOnLaunch
    }

    /// Clamps values into supported ranges.
    public func normalized() -> FluxSettings {
        var s = self
        s.maxConcurrentDownloads = min(max(s.maxConcurrentDownloads, Self.concurrentRange.lowerBound), Self.concurrentRange.upperBound)
        s.connectionsPerDownload = min(max(s.connectionsPerDownload, 1), 32)
        return s
    }
}
