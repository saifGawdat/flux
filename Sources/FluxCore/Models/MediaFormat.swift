import Foundation

/// How a download is performed.
public enum DownloadKind: String, Codable, Sendable, CaseIterable {
    /// A direct file link, fetched by Flux's own multi-connection engine.
    case file
    /// A page with media (YouTube, Vimeo, …), extracted by yt-dlp.
    case media
}

/// Output choice for media downloads.
public enum MediaFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case best
    case mp4_1080 = "mp4-1080"
    case mp4_720 = "mp4-720"
    case mp3
    case m4a

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .best: "Best quality"
        case .mp4_1080: "1080p MP4"
        case .mp4_720: "720p MP4"
        case .mp3: "Audio only · MP3"
        case .m4a: "Audio only · M4A"
        }
    }

    public var isAudioOnly: Bool { self == .mp3 || self == .m4a }

    /// Resolution cap for the MP4 presets.
    public var maxHeight: Int? {
        switch self {
        case .mp4_1080: 1080
        case .mp4_720: 720
        default: nil
        }
    }

    /// yt-dlp format selection. Without ffmpeg, separate video and audio streams can't be
    /// merged or converted, so pick formats that already come as one file.
    func ytdlpArguments(hasFFmpeg: Bool) -> [String] {
        switch self {
        case .best:
            return hasFFmpeg ? ["-f", "bv*+ba/b"] : ["-f", "b"]
        case .mp4_1080:
            return Self.mp4(maxHeight: 1080, hasFFmpeg: hasFFmpeg)
        case .mp4_720:
            return Self.mp4(maxHeight: 720, hasFFmpeg: hasFFmpeg)
        case .mp3:
            return hasFFmpeg
                ? ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
                : ["-f", "ba[ext=m4a]/ba/b"]
        case .m4a:
            return hasFFmpeg
                ? ["-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a"]
                : ["-f", "ba[ext=m4a]/ba/b"]
        }
    }

    private static func mp4(maxHeight h: Int, hasFFmpeg: Bool) -> [String] {
        if hasFFmpeg {
            // H.264 first: plays everywhere (QuickTime, iPhone) and sites list exact sizes for it.
            return ["-f", "bv*[height<=\(h)][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=\(h)][ext=mp4]+ba[ext=m4a]/b[height<=\(h)][ext=mp4]/bv*[height<=\(h)]+ba/b[height<=\(h)]/b",
                    "--merge-output-format", "mp4"]
        }
        return ["-f", "b[height<=\(h)][ext=mp4]/b[height<=\(h)]/b"]
    }
}
