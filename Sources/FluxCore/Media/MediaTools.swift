import Foundation

/// Locations of the external tools used for media downloads.
public struct MediaTools: Sendable, Equatable {
    public var ytdlp: URL?
    public var ffmpeg: URL?
    /// Image galleries (Instagram, Reddit, Tumblr, Flickr, …).
    public var galleryDL: URL?

    public init(ytdlp: URL? = nil, ffmpeg: URL? = nil, galleryDL: URL? = nil) {
        self.ytdlp = ytdlp
        self.ffmpeg = ffmpeg
        self.galleryDL = galleryDL
    }

    public static let none = MediaTools()

    /// Flux's own tools folder: `~/Library/Application Support/Flux/bin`.
    public static var managedDirectory: URL {
        FluxDatabase.defaultURL.deletingLastPathComponent().appendingPathComponent("bin", isDirectory: true)
    }

    /// Apps launched from Finder get a minimal PATH, so common install folders are
    /// searched explicitly (Homebrew on Apple Silicon first).
    static func searchDirectories(environment: [String: String]) -> [URL] {
        var paths = [managedDirectory.path, "/opt/homebrew/bin", "/usr/local/bin",
                     NSHomeDirectory() + "/.local/bin", "/usr/bin"]
        paths += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static func discover(environment: [String: String] = ProcessInfo.processInfo.environment) -> MediaTools {
        let dirs = searchDirectories(environment: environment)
        func find(_ name: String) -> URL? {
            dirs.lazy.map { $0.appendingPathComponent(name) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        return MediaTools(ytdlp: find("yt-dlp"), ffmpeg: find("ffmpeg"), galleryDL: find("gallery-dl"))
    }

    /// Environment for child processes: PATH includes the tool folders so yt-dlp finds ffmpeg.
    func processEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        var dirs = [ytdlp, ffmpeg, galleryDL].compactMap { $0?.deletingLastPathComponent().path }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let existing = base["PATH"] { dirs.append(existing) }
        env["PATH"] = dirs.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// Runs `<tool> --version` (ffmpeg uses `-version`) and returns the first line.
    public static func version(of tool: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = tool
            process.arguments = [tool.lastPathComponent == "ffmpeg" ? "-version" : "--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
                continuation.resume(returning: line)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}

/// Decides whether a link should go to the media extractor rather than the file engine.
public enum MediaRouting {
    static let mediaHosts: [String] = [
        "youtube.com", "youtu.be", "youtube-nocookie.com", "vimeo.com", "dailymotion.com", "twitch.tv",
        "tiktok.com", "instagram.com", "facebook.com", "fb.watch", "x.com", "twitter.com",
        "reddit.com", "v.redd.it", "soundcloud.com", "bandcamp.com", "bilibili.com",
        "streamable.com", "rumble.com", "vk.com", "ok.ru", "mixcloud.com", "threads.net",
    ]

    static let directFileExtensions: Set<String> = [
        "zip", "rar", "7z", "gz", "tgz", "xz", "dmg", "pkg", "iso", "exe", "msi", "pdf",
        "mp4", "mkv", "mov", "webm", "mp3", "m4a", "flac", "wav", "jpg", "jpeg", "png", "gif",
        "webp", "avif", "heic", "bmp", "tif", "tiff", "svg",
    ]

    /// The link names a file (by extension) rather than a page.
    public static func isDirectFile(_ url: URL) -> Bool {
        directFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// True for pages on well-known video/audio sites (but not direct file links on them).
    public static func prefersMedia(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let isMediaHost = mediaHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        return isMediaHost && !isDirectFile(url)
    }
}
